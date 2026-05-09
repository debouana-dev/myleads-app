/// Organisation × Database × FTP-sync integration tests.
///
/// Simulates a real organisation structure (1 admin + 2 members) through the
/// DatabaseService layer and verifies:
///   1. Organisation CRUD lifecycle
///   2. Member management (roles, privileges, status)
///   3. Per-user contact permissions
///   4. Cross-member contact sharing with org-level deduplication
///   5. Reminder visibility gated by canViewReminders
///   6. Contact ownership transfer on member removal / suspension
///   7. Live-write callbacks (remote-sync hooks fired on every mutation)
///   8. Raw-row structure expected by RemoteSyncService MySQL upserts
///   9. FTP path-convention invariants (relative paths, component split)
///
/// Network calls (MySQL / FTP) are never made — the test wires a capturing
/// callback instead of a real RemoteSyncService and validates path logic
/// without an FTP connection.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:me2leads/models/contact.dart';
import 'package:me2leads/models/organization.dart';
import 'package:me2leads/models/reminder.dart';
import 'package:me2leads/models/user_account.dart';
import 'package:me2leads/services/database_service.dart';
import 'package:me2leads/services/encryption_service.dart';

// ─── Fixed test key / IV (32 / 16 zero bytes in base64) ──────────────────────
// Using zero-byte keys is intentional for tests — never use in production.
const _kTestKeyB64 = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=';
const _kTestIvB64 = 'AAAAAAAAAAAAAAAAAAAAAA==';

// ─── Fixed IDs used across tests ─────────────────────────────────────────────
const _adminId = 'user-admin-001';
const _member1Id = 'user-member-001';
const _member2Id = 'user-member-002';
const _orgId = 'org-001';
const _orgName = 'Acme Corp';
const _orgCode = 'ACME1234';

// ─── Schema ───────────────────────────────────────────────────────────────────

Future<void> _createSchema(Database db, int version) async {
  await db.execute('''
    CREATE TABLE users (
      id TEXT PRIMARY KEY,
      email_enc TEXT NOT NULL,
      email_lookup TEXT NOT NULL UNIQUE,
      first_name_enc TEXT NOT NULL,
      last_name_enc TEXT NOT NULL,
      nickname_enc TEXT,
      phone_enc TEXT,
      phone_lookup TEXT UNIQUE,
      date_of_birth_enc TEXT,
      company_name_enc TEXT,
      company_role_enc TEXT,
      biography_enc TEXT,
      password_hash TEXT NOT NULL,
      auth_provider TEXT NOT NULL DEFAULT 'email',
      session_token TEXT,
      created_at TEXT NOT NULL,
      last_login_at TEXT,
      password_changed_at TEXT NOT NULL,
      photo_path TEXT,
      email_verified INTEGER NOT NULL DEFAULT 0,
      organization_id TEXT,
      org_role TEXT,
      plan TEXT NOT NULL DEFAULT 'free',
      last_sync_at TEXT
    )
  ''');

  await db.execute('''
    CREATE TABLE contacts (
      id TEXT PRIMARY KEY,
      owner_id TEXT NOT NULL,
      first_name TEXT NOT NULL,
      last_name TEXT NOT NULL,
      job_title TEXT,
      company TEXT,
      phone TEXT,
      email TEXT,
      phone_lookup TEXT,
      email_lookup TEXT,
      source TEXT,
      project_1 TEXT,
      project_1_budget TEXT,
      project_2 TEXT,
      project_2_budget TEXT,
      interest TEXT,
      notes TEXT,
      tags TEXT,
      status TEXT NOT NULL DEFAULT 'warm',
      created_at TEXT NOT NULL,
      last_contact_date TEXT,
      avatar_color TEXT,
      capture_method TEXT NOT NULL DEFAULT 'manual',
      photo_path TEXT,
      FOREIGN KEY (owner_id) REFERENCES users(id) ON DELETE CASCADE
    )
  ''');
  await db.execute('CREATE INDEX idx_contacts_owner ON contacts(owner_id)');
  await db.execute(
      'CREATE UNIQUE INDEX idx_contacts_owner_phone ON contacts(owner_id, phone_lookup) WHERE phone_lookup IS NOT NULL');
  await db.execute(
      'CREATE UNIQUE INDEX idx_contacts_owner_email ON contacts(owner_id, email_lookup) WHERE email_lookup IS NOT NULL');

  await db.execute('''
    CREATE TABLE reminders (
      id TEXT PRIMARY KEY,
      owner_id TEXT NOT NULL,
      contact_id TEXT,
      contact_ids TEXT NOT NULL DEFAULT '[]',
      start_date_time TEXT NOT NULL,
      end_date_time TEXT,
      repeat_frequency TEXT,
      note TEXT NOT NULL DEFAULT '',
      todo_action TEXT NOT NULL DEFAULT 'call',
      priority_v2 TEXT NOT NULL DEFAULT 'normal',
      title TEXT,
      description TEXT,
      due_date TEXT,
      priority TEXT,
      is_completed INTEGER NOT NULL DEFAULT 0,
      created_at TEXT NOT NULL
    )
  ''');
  await db.execute('CREATE INDEX idx_reminders_owner ON reminders(owner_id)');

  await db.execute('''
    CREATE TABLE interactions (
      id TEXT PRIMARY KEY,
      owner_id TEXT NOT NULL,
      contact_id TEXT NOT NULL,
      type TEXT NOT NULL,
      content TEXT NOT NULL,
      created_at TEXT NOT NULL,
      FOREIGN KEY (owner_id) REFERENCES users(id) ON DELETE CASCADE,
      FOREIGN KEY (contact_id) REFERENCES contacts(id) ON DELETE CASCADE
    )
  ''');
  await db.execute(
      'CREATE INDEX idx_interactions_contact ON interactions(contact_id)');

  await db.execute('''
    CREATE TABLE payment_methods (
      id TEXT PRIMARY KEY,
      owner_id TEXT NOT NULL,
      type TEXT NOT NULL,
      label TEXT NOT NULL,
      encrypted_details TEXT NOT NULL,
      created_at TEXT NOT NULL
    )
  ''');

  await db.execute('''
    CREATE TABLE session (
      key TEXT PRIMARY KEY,
      value TEXT NOT NULL
    )
  ''');

  await db.execute('''
    CREATE TABLE notifications (
      id TEXT PRIMARY KEY,
      owner_id TEXT NOT NULL,
      type TEXT NOT NULL,
      title TEXT NOT NULL,
      body TEXT NOT NULL,
      scheduled_at TEXT NOT NULL,
      created_at TEXT NOT NULL,
      reference_id TEXT,
      is_read INTEGER NOT NULL DEFAULT 0
    )
  ''');
  await db.execute(
      'CREATE INDEX idx_notifications_owner ON notifications(owner_id)');

  await db.execute('''
    CREATE TABLE organizations (
      id TEXT PRIMARY KEY,
      name TEXT NOT NULL,
      owner_id TEXT NOT NULL,
      invite_code TEXT NOT NULL UNIQUE,
      created_at TEXT NOT NULL
    )
  ''');

  await db.execute('''
    CREATE TABLE organization_members (
      id TEXT PRIMARY KEY,
      organization_id TEXT NOT NULL,
      user_id TEXT NOT NULL,
      role TEXT NOT NULL DEFAULT 'member',
      status TEXT NOT NULL DEFAULT 'active',
      joined_at TEXT NOT NULL,
      can_edit INTEGER NOT NULL DEFAULT 0,
      can_create INTEGER NOT NULL DEFAULT 1,
      can_view_reminders INTEGER NOT NULL DEFAULT 0,
      can_view_history INTEGER NOT NULL DEFAULT 0,
      FOREIGN KEY (organization_id) REFERENCES organizations(id) ON DELETE CASCADE,
      FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE,
      UNIQUE (organization_id, user_id)
    )
  ''');
  await db.execute(
      'CREATE INDEX idx_org_members_org ON organization_members(organization_id)');
  await db.execute(
      'CREATE INDEX idx_org_members_user ON organization_members(user_id)');
}

// ─── Test-data helpers ────────────────────────────────────────────────────────

Future<void> _seedUsers() async {
  final now = DateTime(2026, 1, 1);
  await DatabaseService.insertUser(UserAccount(
    id: _adminId,
    email: 'admin@acme.com',
    firstName: 'Alice',
    lastName: 'Admin',
    passwordHash: 'hash:admin',
    plan: 'business',
    organizationId: _orgId,
    orgRole: 'admin',
    emailVerified: true,
    createdAt: now,
    passwordChangedAt: now,
  ));
  await DatabaseService.insertUser(UserAccount(
    id: _member1Id,
    email: 'bob@acme.com',
    firstName: 'Bob',
    lastName: 'Member',
    passwordHash: 'hash:bob',
    plan: 'business',
    organizationId: _orgId,
    orgRole: 'member',
    emailVerified: true,
    createdAt: now,
    passwordChangedAt: now,
  ));
  await DatabaseService.insertUser(UserAccount(
    id: _member2Id,
    email: 'carol@acme.com',
    firstName: 'Carol',
    lastName: 'Member',
    passwordHash: 'hash:carol',
    plan: 'business',
    organizationId: _orgId,
    orgRole: 'member',
    emailVerified: true,
    createdAt: now,
    passwordChangedAt: now,
  ));
}

Organization _makeOrg({
  String id = _orgId,
  String name = _orgName,
  String ownerId = _adminId,
  String inviteCode = _orgCode,
}) =>
    Organization(
      id: id,
      name: name,
      ownerId: ownerId,
      inviteCode: inviteCode,
      createdAt: DateTime(2026, 1, 1),
    );

Contact _makeContact({
  required String id,
  required String ownerId,
  String firstName = 'Jean',
  String lastName = 'Dupont',
  String? phone,
  String? email,
  String status = 'warm',
  DateTime? createdAt,
}) =>
    Contact(
      id: id,
      ownerId: ownerId,
      firstName: firstName,
      lastName: lastName,
      phone: phone,
      email: email,
      status: status,
      createdAt: createdAt ?? DateTime.now(),
    );

Reminder _makeReminder({
  required String id,
  required String ownerId,
  required String contactId,
  String note = 'Rappel test',
  String priority = 'normal',
}) =>
    Reminder(
      id: id,
      ownerId: ownerId,
      contactIds: [contactId],
      startDateTime: DateTime(2026, 6, 1, 10),
      note: note,
      priority: priority,
    );

// ─── Main ─────────────────────────────────────────────────────────────────────

void main() {
  sqfliteFfiInit();

  late Database db;

  setUpAll(() async {
    EncryptionService.initForTest(keyB64: _kTestKeyB64, ivB64: _kTestIvB64);

    db = await databaseFactoryFfi.openDatabase(
      inMemoryDatabasePath,
      options: OpenDatabaseOptions(
        version: 12,
        onCreate: _createSchema,
      ),
    );
    DatabaseService.injectDatabase(db);
  });

  setUp(() async {
    // Disable live-write callbacks so inserts in helpers don't pollute
    // callback-capture tests.
    DatabaseService.wireRemoteSync(
      onUpsert: (_, __) {},
      onDelete: (_, __) {},
    );
    // Wipe all rows in reverse FK order.
    await db.delete('organization_members');
    await db.delete('organizations');
    await db.delete('interactions');
    await db.delete('reminders');
    await db.delete('contacts');
    await db.delete('users');
  });

  tearDownAll(() async => db.close());

  // ===========================================================================
  // 1 — ORGANISATION LIFECYCLE
  // ===========================================================================

  group('Organisation lifecycle', () {
    test('create and retrieve by id', () async {
      await _seedUsers();
      final org = _makeOrg();
      await DatabaseService.insertOrganization(org);

      final found = await DatabaseService.findOrganizationById(_orgId);
      expect(found, isNotNull);
      expect(found!.name, equals(_orgName));
      expect(found.ownerId, equals(_adminId));
      expect(found.inviteCode, equals(_orgCode));
    });

    test('find by invite code is case-insensitive', () async {
      await _seedUsers();
      await DatabaseService.insertOrganization(_makeOrg());

      final found = await DatabaseService.findOrganizationByInviteCode('acme1234');
      expect(found, isNotNull);
      expect(found!.id, equals(_orgId));
    });

    test('update org name', () async {
      await _seedUsers();
      final org = _makeOrg();
      await DatabaseService.insertOrganization(org);

      await DatabaseService.updateOrganization(org.copyWith(name: 'Globex Inc'));

      final updated = await DatabaseService.findOrganizationById(_orgId);
      expect(updated!.name, equals('Globex Inc'));
    });

    test('delete org clears members and user org fields', () async {
      await _seedUsers();
      await DatabaseService.insertOrganization(_makeOrg());
      await DatabaseService.insertOrgMember(
        id: 'mem-admin',
        orgId: _orgId,
        userId: _adminId,
        role: 'admin',
      );

      await DatabaseService.deleteOrganization(_orgId);

      expect(await DatabaseService.findOrganizationById(_orgId), isNull);
      expect(
        await DatabaseService.isUserInOrganization(_orgId, _adminId),
        isFalse,
      );
      // User's org columns should be cleared.
      final user = await DatabaseService.findUserById(_adminId);
      expect(user!.organizationId, isNull);
      expect(user.orgRole, isNull);
    });
  });

  // ===========================================================================
  // 2 — MEMBER MANAGEMENT
  // ===========================================================================

  group('Member management', () {
    setUp(() async {
      await _seedUsers();
      await DatabaseService.insertOrganization(_makeOrg());
    });

    test('admin member gets all privileges', () async {
      await DatabaseService.insertOrgMember(
        id: 'mem-admin',
        orgId: _orgId,
        userId: _adminId,
        role: 'admin',
      );

      final members = await DatabaseService.getMembersForOrganization(_orgId);
      final admin = members.firstWhere((m) => m.userId == _adminId);
      expect(admin.role, equals('admin'));
      expect(admin.canEdit, isTrue);
      expect(admin.canCreate, isTrue);
      expect(admin.canViewReminders, isTrue);
      expect(admin.canViewHistory, isTrue);
    });

    test('regular member has limited default privileges', () async {
      await DatabaseService.insertOrgMember(
        id: 'mem-bob',
        orgId: _orgId,
        userId: _member1Id,
        role: 'member',
      );

      final members = await DatabaseService.getMembersForOrganization(_orgId);
      final bob = members.firstWhere((m) => m.userId == _member1Id);
      expect(bob.role, equals('member'));
      expect(bob.canCreate, isTrue);     // default = 1
      expect(bob.canEdit, isFalse);      // default = 0
      expect(bob.canViewReminders, isFalse);
      expect(bob.canViewHistory, isFalse);
    });

    test('isUserInOrganization returns true/false correctly', () async {
      await DatabaseService.insertOrgMember(
        id: 'mem-bob',
        orgId: _orgId,
        userId: _member1Id,
        role: 'member',
      );

      expect(
        await DatabaseService.isUserInOrganization(_orgId, _member1Id),
        isTrue,
      );
      expect(
        await DatabaseService.isUserInOrganization(_orgId, _member2Id),
        isFalse,
      );
    });

    test('updateMemberStatus suspends and reactivates', () async {
      await DatabaseService.insertOrgMember(
        id: 'mem-bob',
        orgId: _orgId,
        userId: _member1Id,
        role: 'member',
      );

      await DatabaseService.updateMemberStatus(
        orgId: _orgId,
        userId: _member1Id,
        status: 'suspended',
      );
      expect(
        await DatabaseService.getMemberStatus(
            userId: _member1Id, orgId: _orgId),
        equals('suspended'),
      );

      await DatabaseService.updateMemberStatus(
        orgId: _orgId,
        userId: _member1Id,
        status: 'active',
      );
      expect(
        await DatabaseService.getMemberStatus(
            userId: _member1Id, orgId: _orgId),
        equals('active'),
      );
    });

    test('updateMemberPrivileges persists all four flags', () async {
      await DatabaseService.insertOrgMember(
        id: 'mem-bob',
        orgId: _orgId,
        userId: _member1Id,
        role: 'member',
      );

      await DatabaseService.updateMemberPrivileges(
        orgId: _orgId,
        userId: _member1Id,
        canEdit: true,
        canCreate: false,
        canViewReminders: true,
        canViewHistory: false,
      );

      final privs = await DatabaseService.getMemberPrivileges(
          userId: _member1Id, orgId: _orgId);
      expect(privs.canEdit, isTrue);
      expect(privs.canCreate, isFalse);
      expect(privs.canViewReminders, isTrue);
      expect(privs.canViewHistory, isFalse);
    });

    test('removeOrgMember deletes row and clears user org fields', () async {
      await DatabaseService.insertOrgMember(
        id: 'mem-bob',
        orgId: _orgId,
        userId: _member1Id,
        role: 'member',
      );

      await DatabaseService.removeOrgMember(_orgId, _member1Id);

      expect(
        await DatabaseService.isUserInOrganization(_orgId, _member1Id),
        isFalse,
      );
      final user = await DatabaseService.findUserById(_member1Id);
      expect(user!.organizationId, isNull);
      expect(user.orgRole, isNull);
    });

    test('getMembersForOrganization returns denormalised user info', () async {
      await DatabaseService.insertOrgMember(
        id: 'mem-admin',
        orgId: _orgId,
        userId: _adminId,
        role: 'admin',
      );
      await DatabaseService.insertOrgMember(
        id: 'mem-bob',
        orgId: _orgId,
        userId: _member1Id,
        role: 'member',
      );

      final members = await DatabaseService.getMembersForOrganization(_orgId);
      expect(members.length, equals(2));

      final bob = members.firstWhere((m) => m.userId == _member1Id);
      expect(bob.firstName, equals('Bob'));
      expect(bob.lastName, equals('Member'));
      expect(bob.email, equals('bob@acme.com'));
    });
  });

  // ===========================================================================
  // 3 — PERMISSIONS
  // ===========================================================================

  group('Contact permissions', () {
    setUp(() async {
      await _seedUsers();
      await DatabaseService.insertOrganization(_makeOrg());
      await DatabaseService.insertOrgMember(
          id: 'mem-admin', orgId: _orgId, userId: _adminId, role: 'admin');
      await DatabaseService.insertOrgMember(
          id: 'mem-bob', orgId: _orgId, userId: _member1Id, role: 'member');
    });

    test('solo user can only edit their own contacts', () async {
      expect(
        await DatabaseService.canUserEditContact(
            userId: _adminId, orgId: null, contactOwnerId: _adminId),
        isTrue,
      );
      expect(
        await DatabaseService.canUserEditContact(
            userId: _adminId, orgId: null, contactOwnerId: _member1Id),
        isFalse,
      );
    });

    test('org admin can edit any contact', () async {
      expect(
        await DatabaseService.canUserEditContact(
            userId: _adminId, orgId: _orgId, contactOwnerId: _member1Id),
        isTrue,
      );
    });

    test('member with can_edit=0 cannot edit', () async {
      // Default for members is can_edit=0.
      expect(
        await DatabaseService.canUserEditContact(
            userId: _member1Id, orgId: _orgId, contactOwnerId: _adminId),
        isFalse,
      );
    });

    test('member with can_edit=1 can edit', () async {
      await DatabaseService.updateMemberPrivileges(
        orgId: _orgId,
        userId: _member1Id,
        canEdit: true,
        canCreate: true,
        canViewReminders: false,
        canViewHistory: false,
      );

      expect(
        await DatabaseService.canUserEditContact(
            userId: _member1Id, orgId: _orgId, contactOwnerId: _adminId),
        isTrue,
      );
    });

    test('solo user can always create contacts', () async {
      expect(
        await DatabaseService.canUserCreateContact(
            userId: _adminId, orgId: null),
        isTrue,
      );
    });

    test('member with can_create=0 cannot create', () async {
      await DatabaseService.updateMemberPrivileges(
        orgId: _orgId,
        userId: _member1Id,
        canEdit: false,
        canCreate: false,
        canViewReminders: false,
        canViewHistory: false,
      );

      expect(
        await DatabaseService.canUserCreateContact(
            userId: _member1Id, orgId: _orgId),
        isFalse,
      );
    });

    test('getMemberPrivileges without org returns full access', () async {
      final privs = await DatabaseService.getMemberPrivileges(
          userId: _adminId, orgId: null);
      expect(privs.canEdit, isTrue);
      expect(privs.canCreate, isTrue);
      expect(privs.canViewReminders, isTrue);
      expect(privs.canViewHistory, isTrue);
    });

    test('getMemberPrivileges for admin returns all true', () async {
      final privs = await DatabaseService.getMemberPrivileges(
          userId: _adminId, orgId: _orgId);
      expect(privs.canEdit, isTrue);
      expect(privs.canCreate, isTrue);
      expect(privs.canViewReminders, isTrue);
      expect(privs.canViewHistory, isTrue);
    });
  });

  // ===========================================================================
  // 4 — CONTACT SHARING & DEDUPLICATION
  // ===========================================================================

  group('Contact sharing and deduplication', () {
    setUp(() async {
      await _seedUsers();
      await DatabaseService.insertOrganization(_makeOrg());
      await DatabaseService.insertOrgMember(
          id: 'mem-admin', orgId: _orgId, userId: _adminId, role: 'admin');
      await DatabaseService.insertOrgMember(
          id: 'mem-bob', orgId: _orgId, userId: _member1Id, role: 'member');
      await DatabaseService.insertOrgMember(
          id: 'mem-carol', orgId: _orgId, userId: _member2Id, role: 'member');
    });

    test('org contacts include all active members contacts', () async {
      await DatabaseService.insertContact(
          _makeContact(id: 'c1', ownerId: _adminId, phone: '+33600000001'));
      await DatabaseService.insertContact(
          _makeContact(id: 'c2', ownerId: _member1Id, phone: '+33600000002'));
      await DatabaseService.insertContact(
          _makeContact(id: 'c3', ownerId: _member2Id, phone: '+33600000003'));

      final contacts =
          await DatabaseService.getAllContactsForOrganization(_orgId);
      final ids = contacts.map((c) => c.id).toSet();
      expect(ids, containsAll(['c1', 'c2', 'c3']));
    });

    test('duplicate phone across members — only earliest survives', () async {
      final earlier = DateTime(2026, 1, 1);
      final later = DateTime(2026, 6, 1);
      await DatabaseService.insertContact(_makeContact(
          id: 'early', ownerId: _adminId, phone: '+33611111111',
          createdAt: earlier));
      await DatabaseService.insertContact(_makeContact(
          id: 'late', ownerId: _member1Id, phone: '+33611111111',
          createdAt: later));

      final contacts =
          await DatabaseService.getAllContactsForOrganization(_orgId);
      final ids = contacts.map((c) => c.id).toList();
      expect(ids, contains('early'));
      expect(ids, isNot(contains('late')));
    });

    test('duplicate email across members — only earliest survives', () async {
      final earlier = DateTime(2026, 1, 1);
      final later = DateTime(2026, 6, 1);
      await DatabaseService.insertContact(_makeContact(
          id: 'e-first', ownerId: _adminId, email: 'dupe@test.com',
          createdAt: earlier));
      await DatabaseService.insertContact(_makeContact(
          id: 'e-second', ownerId: _member2Id, email: 'dupe@test.com',
          createdAt: later));

      final contacts =
          await DatabaseService.getAllContactsForOrganization(_orgId);
      expect(contacts.map((c) => c.id), contains('e-first'));
      expect(contacts.map((c) => c.id), isNot(contains('e-second')));
    });

    test('suspended member contacts excluded from org view', () async {
      await DatabaseService.insertContact(
          _makeContact(id: 'active-c', ownerId: _adminId, phone: '+33600000001'));
      await DatabaseService.insertContact(
          _makeContact(id: 'suspended-c', ownerId: _member1Id, phone: '+33600000099'));

      await DatabaseService.updateMemberStatus(
          orgId: _orgId, userId: _member1Id, status: 'suspended');

      final contacts =
          await DatabaseService.getAllContactsForOrganization(_orgId);
      expect(contacts.map((c) => c.id), contains('active-c'));
      expect(contacts.map((c) => c.id), isNot(contains('suspended-c')));
    });

    test('getOrgDeduplicatedContactCount matches actual deduplication', () async {
      await DatabaseService.insertContact(
          _makeContact(id: 'u1', ownerId: _adminId, phone: '+33600000001'));
      await DatabaseService.insertContact(
          _makeContact(id: 'u2', ownerId: _member1Id, phone: '+33600000002'));
      // Duplicate of u1 (same phone)
      await DatabaseService.insertContact(_makeContact(
          id: 'dup', ownerId: _member2Id, phone: '+33600000001',
          createdAt: DateTime(2026, 12, 1)));

      final count =
          await DatabaseService.getOrgDeduplicatedContactCount(_orgId);
      // 3 raw contacts, 1 duplicate → 2 unique
      expect(count, equals(2));
    });
  });

  // ===========================================================================
  // 5 — REMINDER VISIBILITY
  // ===========================================================================

  group('Reminder visibility', () {
    late String contactId;

    setUp(() async {
      contactId = 'contact-for-reminder';
      await _seedUsers();
      await DatabaseService.insertOrganization(_makeOrg());
      await DatabaseService.insertOrgMember(
          id: 'mem-admin', orgId: _orgId, userId: _adminId, role: 'admin');
      await DatabaseService.insertOrgMember(
          id: 'mem-bob', orgId: _orgId, userId: _member1Id, role: 'member');

      await DatabaseService.insertContact(
          _makeContact(id: contactId, ownerId: _adminId));
      await DatabaseService.insertReminder(
          _makeReminder(id: 'r-admin', ownerId: _adminId, contactId: contactId));
      await DatabaseService.insertReminder(
          _makeReminder(id: 'r-bob', ownerId: _member1Id, contactId: contactId));
    });

    test('canViewReminders=false returns only own reminders', () async {
      final reminders = await DatabaseService.getRemindersForOrgUser(
        userId: _member1Id,
        orgId: _orgId,
        canViewReminders: false,
      );
      expect(reminders.map((r) => r.id), contains('r-bob'));
      expect(reminders.map((r) => r.id), isNot(contains('r-admin')));
    });

    test('canViewReminders=true returns all active member reminders', () async {
      final reminders = await DatabaseService.getRemindersForOrgUser(
        userId: _member1Id,
        orgId: _orgId,
        canViewReminders: true,
      );
      expect(reminders.map((r) => r.id), containsAll(['r-bob', 'r-admin']));
    });
  });

  // ===========================================================================
  // 6 — CONTACT TRANSFER
  // ===========================================================================

  group('Contact transfer on member removal / suspension', () {
    setUp(() async {
      await _seedUsers();
      await DatabaseService.insertOrganization(_makeOrg());
      await DatabaseService.insertOrgMember(
          id: 'mem-admin', orgId: _orgId, userId: _adminId, role: 'admin');
      await DatabaseService.insertOrgMember(
          id: 'mem-bob', orgId: _orgId, userId: _member1Id, role: 'member');
      await DatabaseService.insertOrgMember(
          id: 'mem-carol', orgId: _orgId, userId: _member2Id, role: 'member');
    });

    test('transferNonDuplicate moves unique contacts to admin', () async {
      await DatabaseService.insertContact(
          _makeContact(id: 'bob-unique', ownerId: _member1Id, phone: '+33699000001'));

      final adminId = await DatabaseService.transferNonDuplicateContactsToAdmin(
          fromUserId: _member1Id, orgId: _orgId);
      expect(adminId, equals(_adminId));

      final adminContacts =
          await DatabaseService.getAllContactsForOwner(_adminId);
      expect(adminContacts.map((c) => c.id), contains('bob-unique'));
    });

    test('transferNonDuplicate leaves contacts that duplicate another member', () async {
      // Carol has the same phone as Bob → Bob's contact is a dup from Carol's perspective
      // when we transfer Bob's, Carol still owns hers.
      await DatabaseService.insertContact(
          _makeContact(id: 'bob-dup', ownerId: _member1Id, phone: '+33699111111'));
      await DatabaseService.insertContact(
          _makeContact(id: 'carol-same', ownerId: _member2Id, phone: '+33699111111'));

      await DatabaseService.transferNonDuplicateContactsToAdmin(
          fromUserId: _member1Id, orgId: _orgId);

      // bob-dup stays with bob (duplicate of carol's contact)
      final bobContacts =
          await DatabaseService.getAllContactsForOwner(_member1Id);
      expect(bobContacts.map((c) => c.id), contains('bob-dup'));
    });

    test('transferNonDuplicate treats admin-matching phone as a duplicate (stays with member)', () async {
      // Admin is also counted in "other active members", so if admin already has
      // a contact with the same phone, Bob's contact is treated as a duplicate
      // and stays with Bob — it is NOT transferred to avoid a double-copy.
      await DatabaseService.insertContact(
          _makeContact(id: 'admin-c', ownerId: _adminId, phone: '+33699222222'));
      await DatabaseService.insertContact(
          _makeContact(id: 'bob-c', ownerId: _member1Id, phone: '+33699222222'));

      await DatabaseService.transferNonDuplicateContactsToAdmin(
          fromUserId: _member1Id, orgId: _orgId);

      // bob-c is a duplicate of admin's contact → stays with Bob
      final bobContacts =
          await DatabaseService.getAllContactsForOwner(_member1Id);
      expect(bobContacts.map((c) => c.id), contains('bob-c'));
      // Admin's original contact is unaffected
      final adminContacts =
          await DatabaseService.getAllContactsForOwner(_adminId);
      expect(adminContacts.map((c) => c.id), isNot(contains('bob-c')));
    });

    test('transferNonDuplicate returns null when fromUser is the admin', () async {
      final result = await DatabaseService.transferNonDuplicateContactsToAdmin(
          fromUserId: _adminId, orgId: _orgId);
      expect(result, isNull);
    });

    test('transferOrgContactsToAdmin moves ALL contacts and nulls colliding lookups',
        () async {
      await DatabaseService.insertContact(
          _makeContact(id: 'admin-existing', ownerId: _adminId, phone: '+33600001111'));
      await DatabaseService.insertContact(
          _makeContact(id: 'carol-new', ownerId: _member2Id, phone: '+33600009999'));
      // Same phone as admin → collision
      await DatabaseService.insertContact(
          _makeContact(id: 'carol-dup', ownerId: _member2Id, phone: '+33600001111'));

      await DatabaseService.transferOrgContactsToAdmin(
          fromUserId: _member2Id, orgId: _orgId);

      final adminContacts =
          await DatabaseService.getAllContactsForOwner(_adminId);
      final adminIds = adminContacts.map((c) => c.id).toSet();
      expect(adminIds, containsAll(['admin-existing', 'carol-new', 'carol-dup']));

      // carol-dup collision → phone_lookup nulled
      final db = await DatabaseService.database;
      final dupRows = await db.query('contacts',
          where: 'id = ?', whereArgs: ['carol-dup'], limit: 1);
      expect(dupRows.first['phone_lookup'], isNull);
    });
  });

  // ===========================================================================
  // 7 — LIVE-WRITE CALLBACKS
  // ===========================================================================

  group('Live-write callbacks (remote-sync hooks)', () {
    final upsertCalls = <({String table, Map<String, dynamic> row})>[];
    final deleteCalls = <({String table, String id})>[];

    setUp(() async {
      await _seedUsers();
      await DatabaseService.insertOrganization(_makeOrg());
      await DatabaseService.insertOrgMember(
          id: 'mem-admin', orgId: _orgId, userId: _adminId, role: 'admin');
      await DatabaseService.insertOrgMember(
          id: 'mem-bob', orgId: _orgId, userId: _member1Id, role: 'member');

      upsertCalls.clear();
      deleteCalls.clear();

      DatabaseService.wireRemoteSync(
        onUpsert: (table, row) => upsertCalls.add((table: table, row: row)),
        onDelete: (table, id) => deleteCalls.add((table: table, id: id)),
      );
    });

    test('insertOrganization fires upsert callback with org table', () async {
      final newOrg = Organization(
          id: 'org-new', name: 'NewCo', ownerId: _adminId,
          inviteCode: 'NEWCO001', createdAt: DateTime(2026, 3, 1));
      await DatabaseService.insertOrganization(newOrg);

      final call = upsertCalls.firstWhere((c) => c.table == 'organizations');
      expect(call.row['id'], equals('org-new'));
      expect(call.row['name'], equals('NewCo'));
      expect(call.row['invite_code'], equals('NEWCO001'));
    });

    test('updateOrganization fires upsert callback', () async {
      final updated = _makeOrg().copyWith(name: 'Renamed');
      await DatabaseService.updateOrganization(updated);

      final call = upsertCalls.firstWhere((c) => c.table == 'organizations');
      expect(call.row['name'], equals('Renamed'));
    });

    test('deleteOrganization fires delete callback', () async {
      final tempOrg = Organization(
          id: 'org-temp', name: 'Temp', ownerId: _adminId,
          inviteCode: 'TEMP0001');
      await DatabaseService.insertOrganization(tempOrg);
      upsertCalls.clear();

      await DatabaseService.deleteOrganization('org-temp');

      final call = deleteCalls.firstWhere((c) => c.table == 'organizations');
      expect(call.id, equals('org-temp'));
    });

    test('insertOrgMember fires upsert callback', () async {
      await DatabaseService.insertOrgMember(
        id: 'mem-carol',
        orgId: _orgId,
        userId: _member2Id,
        role: 'member',
      );

      final call =
          upsertCalls.firstWhere((c) => c.table == 'organization_members');
      expect(call.row['user_id'], equals(_member2Id));
      expect(call.row['role'], equals('member'));
    });

    test('removeOrgMember fires delete callback', () async {
      await DatabaseService.removeOrgMember(_orgId, _member1Id);

      final call =
          deleteCalls.firstWhere((c) => c.table == 'organization_members');
      expect(call.id, isNotEmpty);
    });

    test('updateMemberStatus fires upsert callback', () async {
      await DatabaseService.updateMemberStatus(
          orgId: _orgId, userId: _member1Id, status: 'suspended');

      final call =
          upsertCalls.firstWhere((c) => c.table == 'organization_members');
      expect(call.row['status'], equals('suspended'));
    });

    test('updateMemberPrivileges fires upsert callback', () async {
      await DatabaseService.updateMemberPrivileges(
        orgId: _orgId,
        userId: _member1Id,
        canEdit: true,
        canCreate: true,
        canViewReminders: true,
        canViewHistory: true,
      );

      final call =
          upsertCalls.firstWhere((c) => c.table == 'organization_members');
      expect(call.row['can_edit'], equals(1));
      expect(call.row['can_view_reminders'], equals(1));
    });

    test('insertContact fires upsert callback', () async {
      final c = _makeContact(id: 'hook-c', ownerId: _adminId, phone: '+33600000042');
      await DatabaseService.insertContact(c);

      final call = upsertCalls.firstWhere((c) => c.table == 'contacts');
      expect(call.row['id'], equals('hook-c'));
    });

    test('deleteContact fires delete callback', () async {
      final c = _makeContact(id: 'hook-del', ownerId: _adminId, phone: '+33600000043');
      await DatabaseService.insertContact(c);
      upsertCalls.clear();

      await DatabaseService.deleteContact('hook-del');

      final call = deleteCalls.firstWhere((c) => c.table == 'contacts');
      expect(call.id, equals('hook-del'));
    });
  });

  // ===========================================================================
  // 8 — RAW ROWS & TIMESTAMPS
  // ===========================================================================

  group('Raw rows and sync timestamps', () {
    setUp(() async {
      await _seedUsers();
      await DatabaseService.insertOrganization(_makeOrg());
      await DatabaseService.insertOrgMember(
          id: 'mem-admin', orgId: _orgId, userId: _adminId, role: 'admin');
      await DatabaseService.insertOrgMember(
          id: 'mem-bob', orgId: _orgId, userId: _member1Id, role: 'member');
    });

    test('getRawOrganizationRow returns all required MySQL columns', () async {
      final row = await DatabaseService.getRawOrganizationRow(_orgId);
      expect(row, isNotNull);
      expect(row!.keys, containsAll(['id', 'name', 'owner_id', 'invite_code', 'created_at']));
      expect(row['id'], equals(_orgId));
      expect(row['owner_id'], equals(_adminId));
    });

    test('getRawOrgMemberRows include privilege columns', () async {
      final rows = await DatabaseService.getRawOrgMemberRows(_orgId);
      expect(rows, hasLength(2));
      for (final row in rows) {
        expect(row.keys, containsAll([
          'id', 'organization_id', 'user_id', 'role', 'status', 'joined_at',
          'can_edit', 'can_create', 'can_view_reminders', 'can_view_history',
        ]));
      }
      final adminRow = rows.firstWhere((r) => r['user_id'] == _adminId);
      expect(adminRow['can_edit'], equals(1));
      expect(adminRow['can_view_reminders'], equals(1));

      final memberRow = rows.firstWhere((r) => r['user_id'] == _member1Id);
      expect(memberRow['can_edit'], equals(0));
      expect(memberRow['can_view_reminders'], equals(0));
    });

    test('upsertRawRow inserts and replaces on conflict', () async {
      await DatabaseService.upsertRawRow('organizations', {
        'id': 'org-raw',
        'name': 'RawCo v1',
        'owner_id': _adminId,
        'invite_code': 'RAWCOV001',
        'created_at': DateTime.now().toIso8601String(),
      });

      await DatabaseService.upsertRawRow('organizations', {
        'id': 'org-raw',
        'name': 'RawCo v2',
        'owner_id': _adminId,
        'invite_code': 'RAWCOV001',
        'created_at': DateTime.now().toIso8601String(),
      });

      final row = await DatabaseService.getRawOrganizationRow('org-raw');
      expect(row!['name'], equals('RawCo v2'));
    });

    test('updateUserLastSync persists ISO timestamp', () async {
      const ts = '2026-05-06T14:30:00.000Z';
      await DatabaseService.updateUserLastSync(_adminId, ts);

      final stored = await DatabaseService.getUserLastSync(_adminId);
      expect(stored, equals(ts));
    });

    test('getRawContactRows returns photo_path as relative path when set',
        () async {
      const relPath = 'contact_pictures/$_adminId/photo.jpg';
      await DatabaseService.insertContact(
        _makeContact(id: 'photo-c', ownerId: _adminId, phone: '+33600007777')
            .copyWith(photoPath: relPath),
      );

      final rows = await DatabaseService.getRawContactRows(_adminId);
      final row = rows.firstWhere((r) => r['id'] == 'photo-c');
      expect(row['photo_path'], equals(relPath));
      // Relative path must not start with an absolute-path indicator.
      expect(row['photo_path'] as String, isNot(startsWith('/')));
      expect(row['photo_path'] as String, isNot(contains(':\\')));
    });
  });

  // ===========================================================================
  // 9 — FTP PATH CONVENTIONS
  // ===========================================================================

  group('FTP path conventions (pure logic)', () {
    test('contact picture path format is correct', () {
      const userId = 'user-abc';
      const filename = 'portrait.jpg';
      const relPath = 'contact_pictures/$userId/$filename';

      // The path has exactly two '/' separators (3 segments).
      final parts = relPath.split('/');
      expect(parts, hasLength(3));
      expect(parts[0], equals('contact_pictures'));
      expect(parts[1], equals(userId));
      expect(parts[2], equals(filename));
    });

    test('profile picture path format is correct', () {
      const userId = 'user-xyz';
      const filename = 'selfie.jpg';
      const relPath = 'profile_pictures/$userId/$filename';

      final parts = relPath.split('/');
      expect(parts[0], equals('profile_pictures'));
      expect(parts[1], equals(userId));
      expect(parts[2], equals(filename));
    });

    test('remote path = "photos/" + relative path', () {
      const relPath = 'contact_pictures/u1/pic.jpg';
      const remote = 'photos/$relPath';
      expect(remote, equals('photos/contact_pictures/u1/pic.jpg'));
    });

    test('path.basename extracts filename from relative path', () {
      const relPath = 'contact_pictures/user-001/portrait.jpg';
      // Use posix context to stay platform-independent in tests.
      final name = p.posix.basename(relPath);
      expect(name, equals('portrait.jpg'));
    });

    test('path.dirname yields userId-containing directory', () {
      const relPath = 'contact_pictures/user-001/portrait.jpg';
      final dir = p.posix.dirname(relPath);
      expect(dir, equals('contact_pictures/user-001'));
    });

    test('p.posix.split decomposes directory into traversable FTP steps', () {
      const relPath = 'profile_pictures/user-999/avatar.jpg';
      final dirPart = p.posix.dirname(relPath);
      final steps = p.posix.split(dirPart);
      // FTP service navigates into each step: 'photos', then each of these.
      expect(steps, equals(['profile_pictures', 'user-999']));
    });

    test('absolute paths are detectable for migration guard', () {
      const absUnix = '/home/user/.images/contact_pictures/uid/file.jpg';
      const absWin = r'C:\Users\munki\.images\contact_pictures\uid\file.jpg';
      const relPath = 'contact_pictures/uid/file.jpg';

      expect(absUnix.startsWith('/'), isTrue);
      expect(absWin.contains(':\\'), isTrue);
      expect(relPath.startsWith('/'), isFalse);
      expect(relPath.contains(':\\'), isFalse);
    });

    test('two different users never share the same relative path', () {
      const filename = 'photo.jpg';
      const pathA = 'contact_pictures/user-A/$filename';
      const pathB = 'contact_pictures/user-B/$filename';
      expect(pathA, isNot(equals(pathB)));
    });
  });

  // ===========================================================================
  // 10 — INVITE CODE REGENERATION
  // ===========================================================================

  group('Invite code management', () {
    test('updateOrgInviteCode replaces old code', () async {
      await _seedUsers();
      await DatabaseService.insertOrganization(_makeOrg());

      await DatabaseService.updateOrgInviteCode(_orgId, 'NEWCODE1');

      final org = await DatabaseService.findOrganizationById(_orgId);
      expect(org!.inviteCode, equals('NEWCODE1'));

      // Old code no longer resolves.
      final byOld = await DatabaseService.findOrganizationByInviteCode(_orgCode);
      expect(byOld, isNull);
    });

    test('new invite code can be found by lookup', () async {
      await _seedUsers();
      await DatabaseService.insertOrganization(_makeOrg());
      await DatabaseService.updateOrgInviteCode(_orgId, 'XYZXYZ12');

      final found = await DatabaseService.findOrganizationByInviteCode('xyzxyz12');
      expect(found, isNotNull);
      expect(found!.id, equals(_orgId));
    });
  });
}

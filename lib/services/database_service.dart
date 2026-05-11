import 'dart:convert';
import 'dart:io' show Platform;
import 'package:crypto/crypto.dart' show sha256;
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../models/app_notification.dart';
import '../models/contact.dart';
import '../models/interaction.dart';
import '../models/organization.dart';
import '../models/reminder.dart';
import '../models/user_account.dart';
import '../core/utils/validators.dart';
import 'encryption_service.dart';
import 'web_db_factory_stub.dart'
    if (dart.library.html) 'web_db_factory_web.dart';

/// Local SQLite database service.
///
/// All sensitive PII (email, names, phone, payment info)
/// are AES-256 encrypted before being persisted. Lookup columns
/// (email_lookup, phone_lookup) are stored as deterministic hashes
/// for uniqueness checks while keeping the plaintext encrypted.
class DatabaseService {
  static Database? _db;
  static const _dbName = 'myleads.db';
  static const _dbVersion = 17;

  // ── Remote sync callbacks ──────────────────────────────────────────────────
  // Wired once at startup by RemoteSyncService.wireDatabase().
  // Using generic Function types avoids a circular import between this file
  // and remote_sync_service.dart.
  static void Function(String table, Map<String, dynamic> row)? _onRemoteUpsert;
  static void Function(String table, String id)? _onRemoteDelete;

  static void wireRemoteSync({
    required void Function(String table, Map<String, dynamic> row) onUpsert,
    required void Function(String table, String id) onDelete,
  }) {
    _onRemoteUpsert = onUpsert;
    _onRemoteDelete = onDelete;
  }

  static Future<Database> get database async {
    _db ??= await _initDb();
    return _db!;
  }

  static Future<Database> _initDb() async {
    if (kIsWeb) {
      final webFactory = getWebDatabaseFactory();
      if (webFactory != null) {
        databaseFactory = webFactory;
      }
      return openDatabase(
        _dbName,
        version: _dbVersion,
        onCreate: _onCreate,
        onUpgrade: _onUpgrade,
      );
    }

    if (Platform.isWindows || Platform.isLinux) {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
    }

    final dir = await getApplicationDocumentsDirectory();
    final path = p.join(dir.path, _dbName);

    return openDatabase(
      path,
      version: _dbVersion,
      onCreate: _onCreate,
      onUpgrade: _onUpgrade,
    );
  }

  static Future<void> _onUpgrade(
      Database db, int oldVersion, int newVersion) async {
    if (oldVersion < 2) {
      // v1 → v2: replace single "project" column with project_1/2 + budgets
      await db.execute('ALTER TABLE contacts ADD COLUMN project_1 TEXT');
      await db.execute('ALTER TABLE contacts ADD COLUMN project_1_budget TEXT');
      await db.execute('ALTER TABLE contacts ADD COLUMN project_2 TEXT');
      await db.execute('ALTER TABLE contacts ADD COLUMN project_2_budget TEXT');
      // Copy old project data into project_1
      await db.execute(
          'UPDATE contacts SET project_1 = project WHERE project IS NOT NULL');
    }
    if (oldVersion < 3) {
      // v2 → v3: add photo_path to users and contacts
      await db.execute('ALTER TABLE users ADD COLUMN photo_path TEXT');
      await db.execute('ALTER TABLE contacts ADD COLUMN photo_path TEXT');
    }
    if (oldVersion < 4) {
      // v3 → v4: expanded user profile + email verification
      await db.execute('ALTER TABLE users ADD COLUMN nickname_enc TEXT');
      await db.execute('ALTER TABLE users ADD COLUMN company_name_enc TEXT');
      await db.execute('ALTER TABLE users ADD COLUMN company_role_enc TEXT');
      await db.execute('ALTER TABLE users ADD COLUMN biography_enc TEXT');
      await db.execute(
          'ALTER TABLE users ADD COLUMN email_verified INTEGER NOT NULL DEFAULT 0');
    }
    if (oldVersion < 5) {
      // v4 → v5: multi-contact reminders with start/end/repeat/action/priority
      try {
        await db.execute(
            "ALTER TABLE reminders ADD COLUMN contact_ids TEXT NOT NULL DEFAULT '[]'");
      } catch (_) {}
      try {
        await db
            .execute('ALTER TABLE reminders ADD COLUMN start_date_time TEXT');
      } catch (_) {}
      try {
        await db.execute('ALTER TABLE reminders ADD COLUMN end_date_time TEXT');
      } catch (_) {}
      try {
        await db
            .execute('ALTER TABLE reminders ADD COLUMN repeat_frequency TEXT');
      } catch (_) {}
      try {
        await db.execute(
            "ALTER TABLE reminders ADD COLUMN note TEXT NOT NULL DEFAULT ''");
      } catch (_) {}
      try {
        await db.execute(
            "ALTER TABLE reminders ADD COLUMN todo_action TEXT NOT NULL DEFAULT 'call'");
      } catch (_) {}
      try {
        await db.execute(
            "ALTER TABLE reminders ADD COLUMN priority_v2 TEXT NOT NULL DEFAULT 'normal'");
      } catch (_) {}
      // Backfill from legacy columns
      try {
        await db.execute(
            "UPDATE reminders SET contact_ids = '[\"' || contact_id || '\"]' WHERE contact_id IS NOT NULL AND (contact_ids = '[]' OR contact_ids IS NULL)");
      } catch (_) {}
      try {
        await db.execute(
            'UPDATE reminders SET start_date_time = due_date WHERE start_date_time IS NULL AND due_date IS NOT NULL');
      } catch (_) {}
      try {
        await db.execute(
            "UPDATE reminders SET note = COALESCE(title, '') WHERE (note = '' OR note IS NULL) AND title IS NOT NULL");
      } catch (_) {}
      try {
        await db.execute(
            "UPDATE reminders SET priority_v2 = 'very_important' WHERE priority = 'urgent'");
      } catch (_) {}
      try {
        await db.execute(
            "UPDATE reminders SET priority_v2 = 'important' WHERE priority = 'soon'");
      } catch (_) {}
      try {
        await db.execute(
            "UPDATE reminders SET priority_v2 = 'normal' WHERE priority = 'later' OR priority IS NULL");
      } catch (_) {}
    }
    if (oldVersion < 6) {
      // v5 → v6: in-app notifications table
      await db.execute('''
        CREATE TABLE IF NOT EXISTS notifications (
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
          'CREATE INDEX IF NOT EXISTS idx_notifications_owner ON notifications(owner_id)');
    }
    if (oldVersion < 7) {
      // v6 → v7: organizations + membership tables; org columns on users
      await db.execute('ALTER TABLE users ADD COLUMN organization_id TEXT');
      await db.execute('ALTER TABLE users ADD COLUMN org_role TEXT');
      await db.execute('''
        CREATE TABLE IF NOT EXISTS organizations (
          id TEXT PRIMARY KEY,
          name TEXT NOT NULL,
          owner_id TEXT NOT NULL,
          invite_code TEXT NOT NULL UNIQUE,
          created_at TEXT NOT NULL
        )
      ''');
      await db.execute('''
        CREATE TABLE IF NOT EXISTS organization_members (
          id TEXT PRIMARY KEY,
          organization_id TEXT NOT NULL,
          user_id TEXT NOT NULL,
          role TEXT NOT NULL DEFAULT 'member',
          status TEXT NOT NULL DEFAULT 'active',
          joined_at TEXT NOT NULL,
          FOREIGN KEY (organization_id) REFERENCES organizations(id) ON DELETE CASCADE,
          FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE,
          UNIQUE (organization_id, user_id)
        )
      ''');
      await db.execute(
          'CREATE INDEX IF NOT EXISTS idx_org_members_org ON organization_members(organization_id)');
      await db.execute(
          'CREATE INDEX IF NOT EXISTS idx_org_members_user ON organization_members(user_id)');
    }
    if (oldVersion < 8) {
      // v7 → v8: per-member access privileges on org contacts
      try {
        await db.execute(
            'ALTER TABLE organization_members ADD COLUMN can_edit INTEGER NOT NULL DEFAULT 0');
      } catch (_) {}
      try {
        await db.execute(
            'ALTER TABLE organization_members ADD COLUMN can_create INTEGER NOT NULL DEFAULT 1');
      } catch (_) {}
      // Ensure admins (role='admin') get can_edit=1 retrospectively
      try {
        await db.execute(
            "UPDATE organization_members SET can_edit = 1, can_create = 1 WHERE role = 'admin'");
      } catch (_) {}
    }
    if (oldVersion < 9) {
      // v8 → v9: subscription plan stored on the user row
      try {
        await db.execute(
            "ALTER TABLE users ADD COLUMN plan TEXT NOT NULL DEFAULT 'free'");
      } catch (_) {}
    }
    if (oldVersion < 10) {
      // v9 → v10: per-member permission to view shared-contact reminders
      try {
        await db.execute(
            'ALTER TABLE organization_members ADD COLUMN can_view_reminders INTEGER NOT NULL DEFAULT 0');
      } catch (_) {}
      // Admins can view all reminders by default
      try {
        await db.execute(
            "UPDATE organization_members SET can_view_reminders = 1 WHERE role = 'admin'");
      } catch (_) {}
    }
    if (oldVersion < 11) {
      // v10 → v11: track when the user last successfully synchronized data
      try {
        await db.execute('ALTER TABLE users ADD COLUMN last_sync_at TEXT');
      } catch (_) {}
    }
    if (oldVersion < 12) {
      // v11 → v12: per-member permission to view shared-contact history authored by others
      try {
        await db.execute(
            'ALTER TABLE organization_members ADD COLUMN can_view_history INTEGER NOT NULL DEFAULT 0');
      } catch (_) {}
      // Admins can view all history by default
      try {
        await db.execute(
            "UPDATE organization_members SET can_view_history = 1 WHERE role = 'admin'");
      } catch (_) {}
    }
    if (oldVersion < 13) {
      // v12 → v13: Stripe payment history table
      await db.execute('''
        CREATE TABLE IF NOT EXISTS payment_history (
          id TEXT PRIMARY KEY,
          user_id TEXT NOT NULL,
          plan TEXT NOT NULL,
          billing_cycle TEXT NOT NULL,
          amount REAL NOT NULL,
          currency TEXT NOT NULL DEFAULT 'EUR',
          status TEXT NOT NULL DEFAULT 'succeeded',
          stripe_payment_intent_id TEXT NOT NULL,
          created_at TEXT NOT NULL
        )
      ''');
      await db.execute(
          'CREATE INDEX IF NOT EXISTS idx_payment_history_user ON payment_history(user_id)');
    }
    if (oldVersion < 15) {
      // v14 → v15: payment method type column on payment history
      try {
        await db.execute(
            "ALTER TABLE payment_history ADD COLUMN payment_method TEXT NOT NULL DEFAULT 'card'");
      } catch (_) {}
    }
    if (oldVersion < 16) {
      // v15 → v16: subscription expiry tracking on users
      try {
        await db.execute('ALTER TABLE users ADD COLUMN plan_expires_at TEXT');
      } catch (_) {}
      try {
        await db.execute(
            'ALTER TABLE users ADD COLUMN subscription_billing_cycle TEXT');
      } catch (_) {}
    }
    if (oldVersion < 17) {
      // v16 → v17: org license count, expiry, and suspension tracking
      try {
        await db.execute(
            'ALTER TABLE organizations ADD COLUMN license_count INTEGER NOT NULL DEFAULT 1');
      } catch (_) {}
      try {
        await db.execute(
            'ALTER TABLE organizations ADD COLUMN org_plan_expires_at TEXT');
      } catch (_) {}
      try {
        await db.execute(
            "ALTER TABLE organizations ADD COLUMN org_status TEXT NOT NULL DEFAULT 'active'");
      } catch (_) {}
      try {
        await db.execute(
            'ALTER TABLE organizations ADD COLUMN org_suspended_at TEXT');
      } catch (_) {}
    }
  }

  static Future<void> _onCreate(Database db, int version) async {
    // ----- USERS -----
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
        last_sync_at TEXT,
        plan_expires_at TEXT,
        subscription_billing_cycle TEXT
      )
    ''');

    // ----- CONTACTS -----
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

    // ----- REMINDERS (v5 schema: multi-contact + scheduling) -----
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

    // ----- INTERACTIONS -----
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

    // ----- PAYMENT METHODS -----
    await db.execute('''
      CREATE TABLE payment_methods (
        id TEXT PRIMARY KEY,
        owner_id TEXT NOT NULL,
        type TEXT NOT NULL,
        label TEXT NOT NULL,
        encrypted_details TEXT NOT NULL,
        created_at TEXT NOT NULL,
        FOREIGN KEY (owner_id) REFERENCES users(id) ON DELETE CASCADE
      )
    ''');

    // ----- SESSION (active session, single row) -----
    await db.execute('''
      CREATE TABLE session (
        key TEXT PRIMARY KEY,
        value TEXT NOT NULL
      )
    ''');

    // ----- NOTIFICATIONS (v6) -----
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

    // ----- ORGANIZATIONS (v7, license columns added v17) -----
    await db.execute('''
      CREATE TABLE organizations (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        owner_id TEXT NOT NULL,
        invite_code TEXT NOT NULL UNIQUE,
        created_at TEXT NOT NULL,
        license_count INTEGER NOT NULL DEFAULT 1,
        org_plan_expires_at TEXT,
        org_status TEXT NOT NULL DEFAULT 'active',
        org_suspended_at TEXT
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

    // ----- PAYMENT HISTORY (v13, payment_method added v15) -----
    await db.execute('''
      CREATE TABLE payment_history (
        id TEXT PRIMARY KEY,
        user_id TEXT NOT NULL,
        plan TEXT NOT NULL,
        billing_cycle TEXT NOT NULL,
        amount REAL NOT NULL,
        currency TEXT NOT NULL DEFAULT 'EUR',
        status TEXT NOT NULL DEFAULT 'succeeded',
        stripe_payment_intent_id TEXT NOT NULL,
        payment_method TEXT NOT NULL DEFAULT 'card',
        created_at TEXT NOT NULL
      )
    ''');
    await db.execute(
        'CREATE INDEX idx_payment_history_user ON payment_history(user_id)');
  }

  // =====================================================================
  // USERS
  // =====================================================================

  static Future<UserAccount?> findUserByEmailLookup(String emailLookup) async {
    final db = await database;
    final rows = await db.query(
      'users',
      where: 'email_lookup = ?',
      whereArgs: [emailLookup],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return _userFromRow(rows.first);
  }

  static Future<bool> isEmailTaken(String email) async {
    final lookup = _hashLookup(Validators.normalizeEmail(email));
    final user = await findUserByEmailLookup(lookup);
    return user != null;
  }

  static Future<bool> isPhoneTaken(String? phone) async {
    if (phone == null || phone.trim().isEmpty) return false;
    final lookup = _hashLookup(Validators.normalizePhone(phone));
    final db = await database;
    final rows = await db.query(
      'users',
      where: 'phone_lookup = ?',
      whereArgs: [lookup],
      limit: 1,
    );
    return rows.isNotEmpty;
  }

  static Future<UserAccount?> findUserById(String id) async {
    final db = await database;
    final rows =
        await db.query('users', where: 'id = ?', whereArgs: [id], limit: 1);
    if (rows.isEmpty) return null;
    return _userFromRow(rows.first);
  }

  static Future<void> insertUser(UserAccount user) async {
    final db = await database;
    final row = _userToRow(user);
    await db.insert('users', row);
    _onRemoteUpsert?.call('users', row);
  }

  static Future<void> updateUser(UserAccount user) async {
    final db = await database;
    final row = _userToRow(user);
    await db.update('users', row, where: 'id = ?', whereArgs: [user.id]);
    _onRemoteUpsert?.call('users', row);
  }

  /// Updates only the session-related columns (session_token, last_login_at)
  /// without touching any AES-encrypted profile fields or firing the remote
  /// sync callback.
  ///
  /// Use this when a user's account has just been imported from the cloud
  /// database onto a new device. The cloud row was encrypted with a different
  /// device's AES key, so passing a [UserAccount] through [updateUser] would
  /// re-encrypt empty/garbled values and push them back to the cloud via the
  /// live-write callback, erasing the correct profile data.
  static Future<void> updateUserSessionToken(
      String userId, String token, DateTime lastLoginAt) async {
    final db = await database;
    await db.update(
      'users',
      {
        'session_token': token,
        'last_login_at': lastLoginAt.toIso8601String(),
      },
      where: 'id = ?',
      whereArgs: [userId],
    );
    // No _onRemoteUpsert call: the cloud already holds correct profile data.
    // startUserSync will push the full raw row via getRawUserRow when needed.
  }

  /// Invalidate all sessions for a user (used when password changes).
  /// Sets a fresh session token; older clients holding the previous token
  /// will fail [validateSessionToken] and be forced to re-login.
  static Future<String> rotateSessionToken(String userId) async {
    final db = await database;
    final newToken = EncryptionService.generateSessionToken();
    await db.update(
      'users',
      {'session_token': newToken},
      where: 'id = ?',
      whereArgs: [userId],
    );
    return newToken;
  }

  static Future<bool> validateSessionToken(String userId, String token) async {
    final user = await findUserById(userId);
    return user != null && user.sessionToken == token;
  }

  static Map<String, dynamic> _userToRow(UserAccount u) => {
        'id': u.id,
        'email_enc': EncryptionService.encryptText(u.email),
        'email_lookup': _hashLookup(Validators.normalizeEmail(u.email)),
        'first_name_enc': EncryptionService.encryptText(u.firstName),
        'last_name_enc': EncryptionService.encryptText(u.lastName),
        'nickname_enc': u.nickname != null
            ? EncryptionService.encryptText(u.nickname!)
            : null,
        'phone_enc':
            u.phone != null ? EncryptionService.encryptText(u.phone!) : null,
        'phone_lookup': u.phone != null && u.phone!.trim().isNotEmpty
            ? _hashLookup(Validators.normalizePhone(u.phone))
            : null,
        // date_of_birth_enc column is kept in schema for v5→v6 migration
        // compatibility but no longer written (doc v7: DoB removed).
        'date_of_birth_enc': null,
        'company_name_enc': u.companyName != null
            ? EncryptionService.encryptText(u.companyName!)
            : null,
        'company_role_enc': u.companyRole != null
            ? EncryptionService.encryptText(u.companyRole!)
            : null,
        'biography_enc': u.biography != null
            ? EncryptionService.encryptText(u.biography!)
            : null,
        'password_hash': u.passwordHash,
        'auth_provider': u.authProvider,
        'session_token': u.sessionToken,
        'created_at': u.createdAt.toIso8601String(),
        'last_login_at': u.lastLoginAt?.toIso8601String(),
        'password_changed_at': u.passwordChangedAt.toIso8601String(),
        'photo_path': u.photoPath,
        'email_verified': u.emailVerified ? 1 : 0,
        'organization_id': u.organizationId,
        'org_role': u.orgRole,
        'plan': u.plan,
        'plan_expires_at': u.planExpiresAt?.toIso8601String(),
        'subscription_billing_cycle': u.subscriptionBillingCycle,
      };

  static UserAccount _userFromRow(Map<String, dynamic> row) {
    return UserAccount(
      id: row['id'] as String,
      email: EncryptionService.decryptText(row['email_enc'] as String?),
      firstName:
          EncryptionService.decryptText(row['first_name_enc'] as String?),
      lastName: EncryptionService.decryptText(row['last_name_enc'] as String?),
      nickname: row['nickname_enc'] != null
          ? EncryptionService.decryptText(row['nickname_enc'] as String?)
          : null,
      phone: row['phone_enc'] != null
          ? EncryptionService.decryptText(row['phone_enc'] as String?)
          : null,
      // dateOfBirth removed per doc v7 — column left untouched for any
      // legacy rows but no longer read into the model.
      companyName: row['company_name_enc'] != null
          ? EncryptionService.decryptText(row['company_name_enc'] as String?)
          : null,
      companyRole: row['company_role_enc'] != null
          ? EncryptionService.decryptText(row['company_role_enc'] as String?)
          : null,
      biography: row['biography_enc'] != null
          ? EncryptionService.decryptText(row['biography_enc'] as String?)
          : null,
      passwordHash: row['password_hash'] as String,
      authProvider: row['auth_provider'] as String? ?? 'email',
      sessionToken: row['session_token'] as String?,
      createdAt: DateTime.parse(row['created_at'] as String),
      lastLoginAt: row['last_login_at'] != null
          ? DateTime.parse(row['last_login_at'] as String)
          : null,
      passwordChangedAt: DateTime.parse(row['password_changed_at'] as String),
      photoPath: row['photo_path'] as String?,
      emailVerified: (row['email_verified'] as int?) == 1,
      organizationId: row['organization_id'] as String?,
      orgRole: row['org_role'] as String?,
      plan: row['plan'] as String? ?? 'free',
      planExpiresAt: row['plan_expires_at'] != null
          ? DateTime.tryParse(row['plan_expires_at'] as String)
          : null,
      subscriptionBillingCycle: row['subscription_billing_cycle'] as String?,
    );
  }

  // =====================================================================
  // SESSION (single active user)
  // =====================================================================

  static Future<void> setSessionValue(String key, String value) async {
    final db = await database;
    await db.insert(
      'session',
      {'key': key, 'value': value},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  static Future<String?> getSessionValue(String key) async {
    final db = await database;
    final rows = await db.query(
      'session',
      where: 'key = ?',
      whereArgs: [key],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return rows.first['value'] as String?;
  }

  static Future<void> clearSession() async {
    final db = await database;
    await db.delete('session');
  }

  // =====================================================================
  // CONTACTS
  // =====================================================================

  static Future<List<Contact>> getAllContactsForOwner(String ownerId) async {
    final db = await database;
    final rows = await db.query(
      'contacts',
      where: 'owner_id = ?',
      whereArgs: [ownerId],
      orderBy: 'created_at DESC',
    );
    return rows.map(_contactFromRow).toList();
  }

  static Future<Contact?> findContactById(String id) async {
    final db = await database;
    final rows =
        await db.query('contacts', where: 'id = ?', whereArgs: [id], limit: 1);
    if (rows.isEmpty) return null;
    return _contactFromRow(rows.first);
  }

  static Future<void> insertContact(Contact contact) async {
    final db = await database;
    final row = _contactToRow(contact);

    await db.insert(
      'contacts',
      row,
      conflictAlgorithm: ConflictAlgorithm.replace,
    );

    _onRemoteUpsert?.call('contacts', row);
  }

  static Future<void> updateContact(Contact contact) async {
    final db = await database;
    final row = _contactToRow(contact);
    await db.update('contacts', row, where: 'id = ?', whereArgs: [contact.id]);
    _onRemoteUpsert?.call('contacts', row);
  }

  static Future<void> deleteContact(String id) async {
    final db = await database;
    await db.delete('contacts', where: 'id = ?', whereArgs: [id]);
    await db.delete('interactions', where: 'contact_id = ?', whereArgs: [id]);
    await db.delete('reminders', where: 'contact_id = ?', whereArgs: [id]);
    _onRemoteDelete?.call('contacts', id);
  }

  /// Check if another contact (excluding [excludeId]) already has the same
  /// phone OR email for this owner.
  static Future<String?> findContactConflict({
    required String ownerId,
    String? phone,
    String? email,
    String? excludeId,
  }) async {
    final db = await database;
    final phoneLookup = (phone != null && phone.trim().isNotEmpty)
        ? _hashLookup(Validators.normalizePhone(phone))
        : null;
    final emailLookup = (email != null && email.trim().isNotEmpty)
        ? _hashLookup(Validators.normalizeEmail(email))
        : null;

    if (phoneLookup != null) {
      final rows = await db.query(
        'contacts',
        where:
            'owner_id = ? AND phone_lookup = ? ${excludeId != null ? 'AND id != ?' : ''}',
        whereArgs: [
          ownerId,
          phoneLookup,
          if (excludeId != null) excludeId,
        ],
        limit: 1,
      );
      if (rows.isNotEmpty) {
        return 'Un contact avec ce numéro de téléphone existe déjà';
      }
    }

    if (emailLookup != null) {
      final rows = await db.query(
        'contacts',
        where:
            'owner_id = ? AND email_lookup = ? ${excludeId != null ? 'AND id != ?' : ''}',
        whereArgs: [
          ownerId,
          emailLookup,
          if (excludeId != null) excludeId,
        ],
        limit: 1,
      );
      if (rows.isNotEmpty) {
        return 'Un contact avec cet email existe déjà';
      }
    }
    return null;
  }

  /// Check duplicate by full identity (firstName + lastName + same phone or email).
  static Future<bool> hasIdenticalContact({
    required String ownerId,
    required String firstName,
    required String lastName,
    String? phone,
    String? email,
    String? excludeId,
  }) async {
    final db = await database;
    final fn = firstName.trim().toLowerCase();
    final ln = lastName.trim().toLowerCase();
    final phoneLookup = (phone != null && phone.trim().isNotEmpty)
        ? _hashLookup(Validators.normalizePhone(phone))
        : null;
    final emailLookup = (email != null && email.trim().isNotEmpty)
        ? _hashLookup(Validators.normalizeEmail(email))
        : null;

    if (phoneLookup == null && emailLookup == null) return false;

    final whereParts = <String>[
      'owner_id = ?',
      'LOWER(first_name) = ?',
      'LOWER(last_name) = ?',
    ];
    final args = <Object?>[ownerId, fn, ln];

    final orParts = <String>[];
    if (phoneLookup != null) {
      orParts.add('phone_lookup = ?');
      args.add(phoneLookup);
    }
    if (emailLookup != null) {
      orParts.add('email_lookup = ?');
      args.add(emailLookup);
    }
    whereParts.add('(${orParts.join(' OR ')})');

    if (excludeId != null) {
      whereParts.add('id != ?');
      args.add(excludeId);
    }

    final rows = await db.query(
      'contacts',
      where: whereParts.join(' AND '),
      whereArgs: args,
      limit: 1,
    );
    return rows.isNotEmpty;
  }

  static Map<String, dynamic> _contactToRow(Contact c) => {
        'id': c.id,
        'owner_id': c.ownerId,
        'first_name': c.firstName,
        'last_name': c.lastName,
        'job_title': c.jobTitle,
        'company': c.company,
        'phone': c.phone,
        'email': c.email,
        'phone_lookup': (c.phone != null && c.phone!.trim().isNotEmpty)
            ? _hashLookup(Validators.normalizePhone(c.phone))
            : null,
        'email_lookup': (c.email != null && c.email!.trim().isNotEmpty)
            ? _hashLookup(Validators.normalizeEmail(c.email))
            : null,
        'source': c.source,
        'project_1': c.project1,
        'project_1_budget': c.project1Budget,
        'project_2': c.project2,
        'project_2_budget': c.project2Budget,
        'interest': c.interest,
        'notes': c.notes,
        'tags': jsonEncode(c.tags),
        'status': c.status,
        'created_at': c.createdAt.toIso8601String(),
        'last_contact_date': c.lastContactDate?.toIso8601String(),
        'avatar_color': c.avatarColor,
        'capture_method': c.captureMethod,
        'photo_path': c.photoPath,
      };

  static Contact _contactFromRow(Map<String, dynamic> row) {
    final phoneEnc = row['phone'] as String?;
    final emailEnc = row['email'] as String?;
    return Contact(
      id: row['id'] as String,
      ownerId: row['owner_id'] as String? ?? '',
      firstName: row['first_name'] as String,
      lastName: row['last_name'] as String,
      jobTitle: row['job_title'] as String?,
      company: row['company'] as String?,
      phone: (phoneEnc != null && phoneEnc.isNotEmpty)
          ? EncryptionService.decryptText(phoneEnc)
          : null,
      email: (emailEnc != null && emailEnc.isNotEmpty)
          ? EncryptionService.decryptText(emailEnc)
          : null,
      source: row['source'] as String?,
      project1: row['project_1'] as String?,
      project1Budget: row['project_1_budget'] as String?,
      project2: row['project_2'] as String?,
      project2Budget: row['project_2_budget'] as String?,
      interest: row['interest'] as String?,
      notes: row['notes'] as String?,
      tags: row['tags'] != null
          ? List<String>.from(jsonDecode(row['tags'] as String) as List)
          : <String>[],
      status: row['status'] as String? ?? 'warm',
      createdAt: DateTime.parse(row['created_at'] as String),
      lastContactDate: row['last_contact_date'] != null
          ? DateTime.parse(row['last_contact_date'] as String)
          : null,
      avatarColor: row['avatar_color'] as String?,
      captureMethod: row['capture_method'] as String? ?? 'manual',
      photoPath: row['photo_path'] as String?,
    );
  }

  // =====================================================================
  // REMINDERS
  // =====================================================================

  static Future<List<Reminder>> getAllRemindersForOwner(String ownerId) async {
    final db = await database;
    final rows = await db.query(
      'reminders',
      where: 'owner_id = ?',
      whereArgs: [ownerId],
      orderBy: 'start_date_time ASC',
    );
    return rows.map(_reminderFromRow).toList();
  }

  // Alias used by some callers
  static Future<List<Reminder>> getRemindersForOwner(String ownerId) =>
      getAllRemindersForOwner(ownerId);

  static Future<void> insertReminder(Reminder reminder) async {
    final db = await database;
    final row = _reminderToRow(reminder);
    await db.insert('reminders', row);
    _onRemoteUpsert?.call('reminders', row);
  }

  static Future<void> updateReminder(Reminder reminder) async {
    final db = await database;
    final row = _reminderToRow(reminder);
    await db
        .update('reminders', row, where: 'id = ?', whereArgs: [reminder.id]);
    _onRemoteUpsert?.call('reminders', row);
  }

  static Future<void> deleteReminder(String id) async {
    final db = await database;
    await db.delete('reminders', where: 'id = ?', whereArgs: [id]);
    _onRemoteDelete?.call('reminders', id);
  }

  static Map<String, dynamic> _reminderToRow(Reminder r) {
    // Legacy priority mirror for backward compat
    String legacyPriority;
    switch (r.priority) {
      case 'very_important':
        legacyPriority = 'urgent';
        break;
      case 'important':
        legacyPriority = 'soon';
        break;
      default:
        legacyPriority = 'later';
    }
    return {
      'id': r.id,
      'owner_id': r.ownerId,
      'contact_id': r.contactIds.isNotEmpty ? r.contactIds.first : null,
      'contact_ids': jsonEncode(r.contactIds),
      'start_date_time': r.startDateTime.toIso8601String(),
      'end_date_time': r.endDateTime?.toIso8601String(),
      'repeat_frequency': r.repeatFrequency,
      'note': r.note,
      'todo_action': r.toDoAction,
      'priority_v2': r.priority,
      'is_completed': r.isCompleted ? 1 : 0,
      'created_at': r.createdAt.toIso8601String(),
      // Legacy mirrors
      'title': r.note,
      'description': null,
      'due_date': r.startDateTime.toIso8601String(),
      'priority': legacyPriority,
    };
  }

  static Reminder _reminderFromRow(Map<String, dynamic> row) {
    List<String> contactIds = const [];
    final rawIds = row['contact_ids'] as String?;
    if (rawIds != null && rawIds.isNotEmpty && rawIds != '[]') {
      try {
        final decoded = jsonDecode(rawIds);
        if (decoded is List) {
          contactIds = decoded.map((e) => e.toString()).toList();
        }
      } catch (_) {}
    }
    if (contactIds.isEmpty) {
      final cid = row['contact_id'] as String?;
      if (cid != null && cid.isNotEmpty) contactIds = [cid];
    }
    if (contactIds.isEmpty) contactIds = ['orphan'];

    DateTime parseDt(dynamic v) {
      if (v == null) return DateTime.now();
      if (v is int) return DateTime.fromMillisecondsSinceEpoch(v);
      if (v is String) {
        try {
          return DateTime.parse(v);
        } catch (_) {
          final asInt = int.tryParse(v);
          if (asInt != null) return DateTime.fromMillisecondsSinceEpoch(asInt);
        }
      }
      return DateTime.now();
    }

    final startRaw = row['start_date_time'] ?? row['due_date'];
    final endRaw = row['end_date_time'];

    final note = (row['note'] as String?)?.isNotEmpty == true
        ? row['note'] as String
        : (row['title'] as String? ?? '');

    String priority = (row['priority_v2'] as String?) ?? '';
    if (priority.isEmpty) {
      // fall back to legacy priority mapping
      final legacy = row['priority'] as String? ?? 'later';
      switch (legacy) {
        case 'urgent':
          priority = 'very_important';
          break;
        case 'soon':
          priority = 'important';
          break;
        default:
          priority = 'normal';
      }
    }

    return Reminder(
      id: row['id'] as String,
      ownerId: row['owner_id'] as String? ?? '',
      contactIds: contactIds,
      startDateTime: parseDt(startRaw),
      endDateTime: endRaw == null ? null : parseDt(endRaw),
      repeatFrequency: row['repeat_frequency'] as String?,
      note: note,
      toDoAction: (row['todo_action'] as String?) ?? 'call',
      priority: priority,
      isCompleted: (row['is_completed'] as int? ?? 0) == 1,
      createdAt: parseDt(row['created_at']),
    );
  }

  // =====================================================================
  // INTERACTIONS
  // =====================================================================

  static Future<List<Interaction>> getInteractionsForContact(
      String contactId) async {
    final db = await database;
    final rows = await db.query(
      'interactions',
      where: 'contact_id = ?',
      whereArgs: [contactId],
      orderBy: 'created_at DESC',
    );
    return rows.map(_interactionFromRow).toList();
  }

  static Future<void> insertInteraction(Interaction interaction) async {
    final db = await database;
    final row = _interactionToRow(interaction);
    await db.insert('interactions', row);
    _onRemoteUpsert?.call('interactions', row);
  }

  static Map<String, dynamic> _interactionToRow(Interaction i) => {
        'id': i.id,
        'owner_id': i.ownerId,
        'contact_id': i.contactId,
        'type': i.type,
        'content': i.content,
        'created_at': i.createdAt.toIso8601String(),
      };

  static Interaction _interactionFromRow(Map<String, dynamic> row) =>
      Interaction(
        id: row['id'] as String,
        ownerId: row['owner_id'] as String? ?? '',
        contactId: row['contact_id'] as String,
        type: row['type'] as String,
        content: row['content'] as String,
        createdAt: DateTime.parse(row['created_at'] as String),
      );

  // =====================================================================
  // PAYMENT METHODS
  // =====================================================================

  static Future<List<PaymentMethod>> getPaymentMethodsForOwner(
      String ownerId) async {
    final db = await database;
    final rows = await db.query(
      'payment_methods',
      where: 'owner_id = ?',
      whereArgs: [ownerId],
    );
    return rows
        .map((r) => PaymentMethod(
              id: r['id'] as String,
              userId: r['owner_id'] as String,
              type: r['type'] as String,
              label: r['label'] as String,
              encryptedDetails: r['encrypted_details'] as String,
              createdAt: DateTime.parse(r['created_at'] as String),
            ))
        .toList();
  }

  static Future<void> insertPaymentMethod(PaymentMethod pm) async {
    final db = await database;
    await db.insert('payment_methods', {
      'id': pm.id,
      'owner_id': pm.userId,
      'type': pm.type,
      'label': pm.label,
      'encrypted_details': pm.encryptedDetails,
      'created_at': pm.createdAt.toIso8601String(),
    });
  }

  static Future<void> deletePaymentMethod(String id) async {
    final db = await database;
    await db.delete('payment_methods', where: 'id = ?', whereArgs: [id]);
  }

  // =====================================================================
  // PAYMENT HISTORY (v13)
  // =====================================================================

  static Future<void> insertPaymentRecord(PaymentRecord record) async {
    final db = await database;
    final row = record.toRow();
    // ConflictAlgorithm.ignore makes this idempotent: main.dart inserts the
    // record on cold-start before the widget tree builds, and
    // SubscriptionPlanScreen may insert it again on resume — same primary key,
    // second insert is silently skipped.
    await db.insert('payment_history', row,
        conflictAlgorithm: ConflictAlgorithm.ignore);
    _onRemoteUpsert?.call('payment_history', row);
  }

  static Future<List<PaymentRecord>> getPaymentHistory(String userId) async {
    final db = await database;
    final rows = await db.query(
      'payment_history',
      where: 'user_id = ?',
      whereArgs: [userId],
      orderBy: 'created_at DESC',
    );
    return rows.map(PaymentRecord.fromRow).toList();
  }

  static Future<List<Map<String, dynamic>>> getRawPaymentHistoryRows(
      String userId) async {
    final db = await database;
    return (await db.query('payment_history',
            where: 'user_id = ?', whereArgs: [userId]))
        .map((r) => Map<String, dynamic>.from(r))
        .toList();
  }

  // =====================================================================
  // NOTIFICATIONS
  // =====================================================================

  static Future<List<AppNotification>> getAllNotificationsForOwner(
      String ownerId) async {
    final db = await database;
    final rows = await db.query(
      'notifications',
      where: 'owner_id = ?',
      whereArgs: [ownerId],
      orderBy: 'scheduled_at DESC',
    );
    return rows.map(AppNotification.fromRow).toList();
  }

  static Future<void> insertNotification(AppNotification n) async {
    final db = await database;
    await db.insert('notifications', n.toRow(),
        conflictAlgorithm: ConflictAlgorithm.ignore);
  }

  static Future<void> markNotificationRead(String id) async {
    final db = await database;
    await db.update('notifications', {'is_read': 1},
        where: 'id = ?', whereArgs: [id]);
  }

  static Future<void> deleteNotification(String id) async {
    final db = await database;
    await db.delete('notifications', where: 'id = ?', whereArgs: [id]);
  }

  static Future<bool> notificationExists(String id) async {
    final db = await database;
    final rows = await db.query('notifications',
        columns: ['id'], where: 'id = ?', whereArgs: [id], limit: 1);
    return rows.isNotEmpty;
  }

  // =====================================================================
  // Account deletion
  // =====================================================================

  /// Permanently erases every row owned by [userId] (contacts, their
  /// interactions, reminders, payment methods) and then the user row
  /// itself. Runs inside a single transaction so an interruption leaves
  /// the DB in a consistent state.
  static Future<void> deleteUserAndAllData(String userId) async {
    final db = await database;
    await db.transaction((txn) async {
      await txn
          .delete('interactions', where: 'owner_id = ?', whereArgs: [userId]);
      await txn.delete('contacts', where: 'owner_id = ?', whereArgs: [userId]);
      await txn.delete('reminders', where: 'owner_id = ?', whereArgs: [userId]);
      await txn.delete('payment_methods',
          where: 'owner_id = ?', whereArgs: [userId]);
      await txn
          .delete('notifications', where: 'owner_id = ?', whereArgs: [userId]);
      await txn.delete('organization_members',
          where: 'user_id = ?', whereArgs: [userId]);
      await txn
          .delete('payment_history', where: 'user_id = ?', whereArgs: [userId]);
      await txn.delete('users', where: 'id = ?', whereArgs: [userId]);
    });
  }

  // =====================================================================
  // ORGANIZATIONS
  // =====================================================================

  static Future<Organization?> findOrganizationById(String id) async {
    final db = await database;
    final rows = await db.query('organizations',
        where: 'id = ?', whereArgs: [id], limit: 1);
    if (rows.isEmpty) return null;
    return _orgFromRow(rows.first);
  }

  static Future<Organization?> findOrganizationByInviteCode(String code) async {
    final db = await database;
    final rows = await db.query(
      'organizations',
      where: 'invite_code = ?',
      whereArgs: [code.trim().toUpperCase()],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return _orgFromRow(rows.first);
  }

  static Future<void> insertOrganization(Organization org) async {
    final db = await database;
    final row = _orgToRow(org);
    await db.insert('organizations', row);
    _onRemoteUpsert?.call('organizations', row);
  }

  static Future<void> updateOrganization(Organization org) async {
    final db = await database;
    final row = _orgToRow(org);
    await db.update('organizations', row, where: 'id = ?', whereArgs: [org.id]);
    _onRemoteUpsert?.call('organizations', row);
  }

  static Future<void> deleteOrganization(String orgId) async {
    final db = await database;
    await db.transaction((txn) async {
      // Clear org membership from users
      await txn.update(
        'users',
        {'organization_id': null, 'org_role': null},
        where: 'organization_id = ?',
        whereArgs: [orgId],
      );
      await txn.delete('organization_members',
          where: 'organization_id = ?', whereArgs: [orgId]);
      await txn.delete('organizations', where: 'id = ?', whereArgs: [orgId]);
    });
    _onRemoteDelete?.call('organizations', orgId);
  }

  static Map<String, dynamic> _orgToRow(Organization o) => {
        'id': o.id,
        'name': o.name,
        'owner_id': o.ownerId,
        'invite_code': o.inviteCode,
        'created_at': o.createdAt.toIso8601String(),
        'license_count': o.licenseCount,
        'org_plan_expires_at': o.orgPlanExpiresAt?.toIso8601String(),
        'org_status': o.orgStatus,
        'org_suspended_at': o.orgSuspendedAt?.toIso8601String(),
      };

  static Organization _orgFromRow(Map<String, dynamic> row) => Organization(
        id: row['id'] as String,
        name: row['name'] as String,
        ownerId: row['owner_id'] as String,
        inviteCode: row['invite_code'] as String,
        createdAt: DateTime.parse(row['created_at'] as String),
        licenseCount: (row['license_count'] as int?) ?? 1,
        orgPlanExpiresAt: row['org_plan_expires_at'] != null
            ? DateTime.tryParse(row['org_plan_expires_at'] as String)
            : null,
        orgStatus: (row['org_status'] as String?) ?? 'active',
        orgSuspendedAt: row['org_suspended_at'] != null
            ? DateTime.tryParse(row['org_suspended_at'] as String)
            : null,
      );

  /// Suspend or reactivate an organization without touching the full row.
  static Future<void> updateOrgStatus(
    String orgId,
    String status, {
    DateTime? suspendedAt,
  }) async {
    final db = await database;
    await db.update(
      'organizations',
      {
        'org_status': status,
        'org_suspended_at': suspendedAt?.toIso8601String(),
      },
      where: 'id = ?',
      whereArgs: [orgId],
    );
    final org = await findOrganizationById(orgId);
    if (org != null) _onRemoteUpsert?.call('organizations', _orgToRow(org));
  }

  /// Update license count and optionally expiry after a successful payment.
  static Future<void> updateOrgLicenses(
    String orgId,
    int licenseCount, {
    DateTime? expiresAt,
  }) async {
    final db = await database;
    final values = <String, Object?>{
      'license_count': licenseCount,
    };
    if (expiresAt != null) {
      values.addAll({
        'org_plan_expires_at': expiresAt.toIso8601String(),
        'org_status': 'active',
        'org_suspended_at': null,
      });
    }

    await db.update(
      'organizations',
      values,
      where: 'id = ?',
      whereArgs: [orgId],
    );
    final org = await findOrganizationById(orgId);
    if (org != null) _onRemoteUpsert?.call('organizations', _orgToRow(org));
  }

  // =====================================================================
  // ORGANIZATION MEMBERS
  // =====================================================================

  /// Load all members of [orgId] with their denormalized user info.
  static Future<List<OrgMember>> getMembersForOrganization(String orgId) async {
    final db = await database;
    final memberRows = await db.query(
      'organization_members',
      where: 'organization_id = ?',
      whereArgs: [orgId],
      orderBy: 'joined_at ASC',
    );

    final members = <OrgMember>[];
    for (final row in memberRows) {
      final userId = row['user_id'] as String;
      final user = await findUserById(userId);
      if (user == null) continue;

      final contactRows = await db.query(
        'contacts',
        columns: ['COUNT(*) as cnt'],
        where: 'owner_id = ?',
        whereArgs: [userId],
      );
      final contactCount = (contactRows.first['cnt'] as int?) ?? 0;

      final role = row['role'] as String? ?? 'member';
      final isAdmin = role == 'admin';
      members.add(OrgMember(
        id: row['id'] as String,
        organizationId: orgId,
        userId: userId,
        role: role,
        status: row['status'] as String? ?? 'active',
        joinedAt: DateTime.parse(row['joined_at'] as String),
        firstName: user.firstName,
        lastName: user.lastName,
        email: user.email,
        photoPath: user.photoPath,
        contactCount: contactCount,
        canEdit: isAdmin || (row['can_edit'] as int? ?? 0) == 1,
        canCreate: isAdmin || (row['can_create'] as int? ?? 1) == 1,
        canViewReminders:
            isAdmin || (row['can_view_reminders'] as int? ?? 0) == 1,
        canViewHistory: isAdmin || (row['can_view_history'] as int? ?? 0) == 1,
      ));
    }
    return members;
  }

  static Future<void> insertOrgMember({
    required String id,
    required String orgId,
    required String userId,
    required String role,
  }) async {
    final db = await database;
    final isAdmin = role == 'admin';
    final row = {
      'id': id,
      'organization_id': orgId,
      'user_id': userId,
      'role': role,
      'status': 'active',
      'joined_at': DateTime.now().toIso8601String(),
      'can_edit': isAdmin ? 1 : 0,
      'can_create': 1,
      'can_view_reminders': isAdmin ? 1 : 0,
      'can_view_history': isAdmin ? 1 : 0,
    };
    await db.insert('organization_members', row,
        conflictAlgorithm: ConflictAlgorithm.ignore);
    _onRemoteUpsert?.call('organization_members', row);
  }

  static Future<void> removeOrgMember(String orgId, String userId) async {
    final db = await database;
    // Capture member id before deletion so the remote delete targets the right row.
    final memberRows = await db.query(
      'organization_members',
      columns: ['id'],
      where: 'organization_id = ? AND user_id = ?',
      whereArgs: [orgId, userId],
      limit: 1,
    );
    await db.transaction((txn) async {
      await txn.delete(
        'organization_members',
        where: 'organization_id = ? AND user_id = ?',
        whereArgs: [orgId, userId],
      );
      await txn.update(
        'users',
        {'organization_id': null, 'org_role': null},
        where: 'id = ?',
        whereArgs: [userId],
      );
    });
    if (memberRows.isNotEmpty) {
      _onRemoteDelete?.call(
          'organization_members', memberRows.first['id'] as String);
    }
  }

  static Future<bool> isUserInOrganization(String orgId, String userId) async {
    final db = await database;
    final rows = await db.query(
      'organization_members',
      where: 'organization_id = ? AND user_id = ?',
      whereArgs: [orgId, userId],
      limit: 1,
    );
    return rows.isNotEmpty;
  }

  static Future<bool> isUserActiveInOrganization(String userId) async {
    final db = await database;
    final rows = await db.query(
      'organization_members',
      where: 'user_id = ? AND status = ?',
      whereArgs: [userId, 'active'],
      limit: 1,
    );
    return rows.isNotEmpty;
  }

  /// Returns true when the given user belongs to any organization,
  /// regardless of their membership status.
  static Future<bool> isUserAssignedToOrganization(String userId) async {
    final db = await database;
    final rows = await db.query(
      'organization_members',
      where: 'user_id = ?',
      whereArgs: [userId],
      limit: 1,
    );
    return rows.isNotEmpty;
  }

  static Future<bool> isOrganizationActive(String orgId) async {
    final org = await findOrganizationById(orgId);
    if (org == null) return false;
    return !org.isSuspended && !org.isExpired;
  }

  /// Update the edit/create/view-reminders/view-history privileges for a single member.
  static Future<void> updateMemberPrivileges({
    required String orgId,
    required String userId,
    required bool canEdit,
    required bool canCreate,
    required bool canViewReminders,
    required bool canViewHistory,
  }) async {
    final db = await database;
    await db.update(
      'organization_members',
      {
        'can_edit': canEdit ? 1 : 0,
        'can_create': canCreate ? 1 : 0,
        'can_view_reminders': canViewReminders ? 1 : 0,
        'can_view_history': canViewHistory ? 1 : 0,
      },
      where: 'organization_id = ? AND user_id = ?',
      whereArgs: [orgId, userId],
    );
    final rows = await db.query(
      'organization_members',
      where: 'organization_id = ? AND user_id = ?',
      whereArgs: [orgId, userId],
      limit: 1,
    );
    if (rows.isNotEmpty) {
      _onRemoteUpsert?.call(
          'organization_members', Map<String, dynamic>.from(rows.first));
    }
  }

  /// Load all contacts owned by any active member of [orgId], with
  /// org-level deduplication: when two members hold a contact with the same
  /// [phone_lookup] or [email_lookup], only the earliest-created copy is
  /// returned. The later duplicates are silently hidden (not deleted).
  static Future<List<Contact>> getAllContactsForOrganization(
      String orgId) async {
    final db = await database;
    final memberRows = await db.query(
      'organization_members',
      columns: ['user_id'],
      where: "organization_id = ? AND status = 'active'",
      whereArgs: [orgId],
    );
    if (memberRows.isEmpty) return [];
    final ids = memberRows.map((r) => r['user_id'] as String).toList();
    final placeholders = ids.map((_) => '?').join(', ');
    // Sort ascending so the oldest contact wins the deduplication pass.
    final rows = await db.rawQuery(
      'SELECT * FROM contacts WHERE owner_id IN ($placeholders) ORDER BY created_at ASC',
      ids,
    );
    final seenPhone = <String>{};
    final seenEmail = <String>{};
    final result = <Contact>[];
    for (final row in rows) {
      final phoneLookup = row['phone_lookup'] as String?;
      final emailLookup = row['email_lookup'] as String?;
      final isDuplicate =
          (phoneLookup != null && !seenPhone.add(phoneLookup)) ||
              (emailLookup != null && !seenEmail.add(emailLookup));
      if (!isDuplicate) result.add(_contactFromRow(row));
    }
    return result;
  }

  /// Returns the [status] string ('active' | 'suspended') for [userId] in
  /// [orgId], or null when no membership record is found.
  static Future<String?> getMemberStatus({
    required String userId,
    required String orgId,
  }) async {
    final db = await database;
    final rows = await db.query(
      'organization_members',
      columns: ['status'],
      where: 'organization_id = ? AND user_id = ?',
      whereArgs: [orgId, userId],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return rows.first['status'] as String?;
  }

  /// Returns the number of unique contacts visible in the org shared view —
  /// i.e. the same deduplicated count that [getAllContactsForOrganization]
  /// would return, but without loading full contact objects.
  static Future<int> getOrgDeduplicatedContactCount(String orgId) async {
    final db = await database;
    final memberRows = await db.query(
      'organization_members',
      columns: ['user_id'],
      where: "organization_id = ? AND status = 'active'",
      whereArgs: [orgId],
    );
    if (memberRows.isEmpty) return 0;
    final ids = memberRows.map((r) => r['user_id'] as String).toList();
    final placeholders = ids.map((_) => '?').join(', ');
    final rows = await db.rawQuery(
      'SELECT phone_lookup, email_lookup FROM contacts '
      'WHERE owner_id IN ($placeholders) ORDER BY created_at ASC',
      ids,
    );
    final seenPhone = <String>{};
    final seenEmail = <String>{};
    var count = 0;
    for (final row in rows) {
      final phoneLookup = row['phone_lookup'] as String?;
      final emailLookup = row['email_lookup'] as String?;
      final isDuplicate =
          (phoneLookup != null && !seenPhone.add(phoneLookup)) ||
              (emailLookup != null && !seenEmail.add(emailLookup));
      if (!isDuplicate) count++;
    }
    return count;
  }

  /// Transfer only the contacts of [fromUserId] that are **not** duplicates
  /// of any contact already owned by another active member of [orgId].
  ///
  /// A contact is considered a duplicate when its [phone_lookup] or
  /// [email_lookup] matches the same field in any other active member's
  /// contact. Duplicate contacts are left untouched so the member retains
  /// them in their personal record (visible again once suspended/removed).
  ///
  /// Returns the admin's user id on success, or null when the org / admin
  /// cannot be found, or when [fromUserId] is the admin themselves.
  static Future<String?> transferNonDuplicateContactsToAdmin({
    required String fromUserId,
    required String orgId,
  }) async {
    final db = await database;

    final orgRows = await db.query(
      'organizations',
      columns: ['owner_id'],
      where: 'id = ?',
      whereArgs: [orgId],
      limit: 1,
    );
    if (orgRows.isEmpty) return null;
    final adminId = orgRows.first['owner_id'] as String;
    if (adminId == fromUserId) return null;

    // Collect lookup hashes owned by other active members (not the target member).
    final otherMemberRows = await db.query(
      'organization_members',
      columns: ['user_id'],
      where: "organization_id = ? AND status = 'active' AND user_id != ?",
      whereArgs: [orgId, fromUserId],
    );
    final otherIds =
        otherMemberRows.map((r) => r['user_id'] as String).toList();

    final otherPhoneLookups = <String>{};
    final otherEmailLookups = <String>{};
    if (otherIds.isNotEmpty) {
      final placeholders = otherIds.map((_) => '?').join(', ');
      final otherContacts = await db.rawQuery(
        'SELECT phone_lookup, email_lookup FROM contacts '
        'WHERE owner_id IN ($placeholders)',
        otherIds,
      );
      for (final r in otherContacts) {
        final p = r['phone_lookup'] as String?;
        final e = r['email_lookup'] as String?;
        if (p != null) otherPhoneLookups.add(p);
        if (e != null) otherEmailLookups.add(e);
      }
    }

    // Fetch target member's contacts.
    final memberContacts = await db.query(
      'contacts',
      where: 'owner_id = ?',
      whereArgs: [fromUserId],
    );

    final transferredIds = <String>[];
    await db.transaction((txn) async {
      for (final row in memberContacts) {
        final contactId = row['id'] as String;
        final phoneLookup = row['phone_lookup'] as String?;
        final emailLookup = row['email_lookup'] as String?;

        // Skip duplicate contacts — they stay with the member.
        final isDuplicate = (phoneLookup != null &&
                otherPhoneLookups.contains(phoneLookup)) ||
            (emailLookup != null && otherEmailLookups.contains(emailLookup));
        if (isDuplicate) continue;

        final updates = <String, Object?>{'owner_id': adminId};

        // Null out lookup fields that would collide with admin's existing contacts.
        if (phoneLookup != null) {
          final conflict = await txn.query(
            'contacts',
            columns: ['id'],
            where: 'owner_id = ? AND phone_lookup = ?',
            whereArgs: [adminId, phoneLookup],
            limit: 1,
          );
          if (conflict.isNotEmpty) updates['phone_lookup'] = null;
        }
        if (emailLookup != null) {
          final conflict = await txn.query(
            'contacts',
            columns: ['id'],
            where: 'owner_id = ? AND email_lookup = ?',
            whereArgs: [adminId, emailLookup],
            limit: 1,
          );
          if (conflict.isNotEmpty) updates['email_lookup'] = null;
        }

        await txn.update('contacts', updates,
            where: 'id = ?', whereArgs: [contactId]);
        transferredIds.add(contactId);
      }
    });

    if (_onRemoteUpsert != null) {
      for (final id in transferredIds) {
        final rows = await db.query('contacts',
            where: 'id = ?', whereArgs: [id], limit: 1);
        if (rows.isNotEmpty) {
          _onRemoteUpsert!('contacts', Map<String, dynamic>.from(rows.first));
        }
      }
    }

    return adminId;
  }

  /// Returns true when [userId] is allowed to edit/delete [contactOwnerId]'s
  /// contact. Solo users can only touch their own contacts. Org admins always
  /// can. Org members need can_edit=1 — even for contacts they own themselves,
  /// since the admin may revoke edit rights for the whole shared workspace.
  static Future<bool> canUserEditContact({
    required String userId,
    required String? orgId,
    required String contactOwnerId,
  }) async {
    if (orgId == null) {
      // Solo account — can only edit their own contacts.
      return userId == contactOwnerId;
    }
    final db = await database;
    final rows = await db.query(
      'organization_members',
      columns: ['role', 'can_edit'],
      where: 'organization_id = ? AND user_id = ?',
      whereArgs: [orgId, userId],
      limit: 1,
    );
    if (rows.isEmpty) return false;
    final role = rows.first['role'] as String? ?? 'member';
    if (role == 'admin') return true; // admins are never restricted
    return (rows.first['can_edit'] as int? ?? 0) == 1;
  }

  /// Returns true when [userId] is allowed to create a new contact.
  /// Solo users (no org) can always create. Org members need can_create=1.
  static Future<bool> canUserCreateContact({
    required String userId,
    required String? orgId,
  }) async {
    if (orgId == null) return true;
    final db = await database;
    final rows = await db.query(
      'organization_members',
      columns: ['role', 'can_create'],
      where: 'organization_id = ? AND user_id = ?',
      whereArgs: [orgId, userId],
      limit: 1,
    );
    if (rows.isEmpty) return true; // not found → treat as solo
    final role = rows.first['role'] as String? ?? 'member';
    if (role == 'admin') return true;
    return (rows.first['can_create'] as int? ?? 1) == 1;
  }

  /// Convenience: fetch all privilege flags for the current user in their org.
  /// Returns defaults (full access) when not in an org.
  static Future<
      ({
        bool canEdit,
        bool canCreate,
        bool canViewReminders,
        bool canViewHistory
      })> getMemberPrivileges({
    required String userId,
    required String? orgId,
  }) async {
    if (orgId == null) {
      return (
        canEdit: true,
        canCreate: true,
        canViewReminders: true,
        canViewHistory: true
      );
    }
    final db = await database;
    final rows = await db.query(
      'organization_members',
      columns: [
        'role',
        'can_edit',
        'can_create',
        'can_view_reminders',
        'can_view_history'
      ],
      where: 'organization_id = ? AND user_id = ?',
      whereArgs: [orgId, userId],
      limit: 1,
    );
    if (rows.isEmpty) {
      return (
        canEdit: true,
        canCreate: true,
        canViewReminders: true,
        canViewHistory: true
      );
    }
    final isAdmin = (rows.first['role'] as String?) == 'admin';
    final canEdit = isAdmin || (rows.first['can_edit'] as int? ?? 0) == 1;
    final canCreate = isAdmin || (rows.first['can_create'] as int? ?? 1) == 1;
    final canViewReminders =
        isAdmin || (rows.first['can_view_reminders'] as int? ?? 0) == 1;
    final canViewHistory =
        isAdmin || (rows.first['can_view_history'] as int? ?? 0) == 1;
    return (
      canEdit: canEdit,
      canCreate: canCreate,
      canViewReminders: canViewReminders,
      canViewHistory: canViewHistory
    );
  }

  /// Load reminders visible to [userId] within [orgId].
  /// With [canViewReminders]=true the user sees reminders owned by any active
  /// org member; otherwise only their own reminders are returned.
  static Future<List<Reminder>> getRemindersForOrgUser({
    required String userId,
    required String orgId,
    required bool canViewReminders,
  }) async {
    if (!canViewReminders) return getAllRemindersForOwner(userId);
    final db = await database;
    final memberRows = await db.query(
      'organization_members',
      columns: ['user_id'],
      where: "organization_id = ? AND status = 'active'",
      whereArgs: [orgId],
    );
    if (memberRows.isEmpty) return getAllRemindersForOwner(userId);
    final ids = memberRows.map((r) => r['user_id'] as String).toList();
    final placeholders = ids.map((_) => '?').join(', ');
    final rows = await db.rawQuery(
      'SELECT * FROM reminders WHERE owner_id IN ($placeholders) '
      'ORDER BY start_date_time ASC',
      ids,
    );
    return rows.map(_reminderFromRow).toList();
  }

  /// Set a member's status to 'active' or 'suspended'.
  static Future<void> updateMemberStatus({
    required String orgId,
    required String userId,
    required String status,
  }) async {
    final db = await database;
    await db.update(
      'organization_members',
      {'status': status},
      where: 'organization_id = ? AND user_id = ?',
      whereArgs: [orgId, userId],
    );
    final rows = await db.query(
      'organization_members',
      where: 'organization_id = ? AND user_id = ?',
      whereArgs: [orgId, userId],
      limit: 1,
    );
    if (rows.isNotEmpty) {
      _onRemoteUpsert?.call(
          'organization_members', Map<String, dynamic>.from(rows.first));
    }
  }

  /// Transfer all contacts owned by [fromUserId] to the organization's admin.
  ///
  /// When a member is suspended, removed, or deletes their account, their
  /// org contacts must not disappear. This method reassigns [owner_id] to the
  /// admin so the contacts remain visible and editable in the org workspace.
  ///
  /// If a transferred contact's [phone_lookup] or [email_lookup] would
  /// collide with an existing admin contact (violating the per-owner unique
  /// index), the lookup field is cleared — the encrypted data is preserved and
  /// the contact is still transferred; only the deduplication hash is lost.
  ///
  /// Returns the admin's user id on success, or null when the org / admin
  /// cannot be found, or when [fromUserId] is the admin themselves.
  static Future<String?> transferOrgContactsToAdmin({
    required String fromUserId,
    required String orgId,
  }) async {
    final db = await database;

    final orgRows = await db.query(
      'organizations',
      columns: ['owner_id'],
      where: 'id = ?',
      whereArgs: [orgId],
      limit: 1,
    );
    if (orgRows.isEmpty) return null;
    final adminId = orgRows.first['owner_id'] as String;
    if (adminId == fromUserId) return null;

    final memberContacts = await db.query(
      'contacts',
      where: 'owner_id = ?',
      whereArgs: [fromUserId],
    );
    if (memberContacts.isEmpty) return adminId;

    final transferredIds = <String>[];
    await db.transaction((txn) async {
      for (final row in memberContacts) {
        final contactId = row['id'] as String;
        final phoneLookup = row['phone_lookup'] as String?;
        final emailLookup = row['email_lookup'] as String?;

        final updates = <String, Object?>{'owner_id': adminId};

        // Null out lookup fields that would collide with admin's existing contacts.
        if (phoneLookup != null) {
          final conflict = await txn.query(
            'contacts',
            columns: ['id'],
            where: 'owner_id = ? AND phone_lookup = ?',
            whereArgs: [adminId, phoneLookup],
            limit: 1,
          );
          if (conflict.isNotEmpty) updates['phone_lookup'] = null;
        }
        if (emailLookup != null) {
          final conflict = await txn.query(
            'contacts',
            columns: ['id'],
            where: 'owner_id = ? AND email_lookup = ?',
            whereArgs: [adminId, emailLookup],
            limit: 1,
          );
          if (conflict.isNotEmpty) updates['email_lookup'] = null;
        }

        await txn.update('contacts', updates,
            where: 'id = ?', whereArgs: [contactId]);
        transferredIds.add(contactId);
      }
    });

    // Best-effort remote sync for each transferred contact.
    if (_onRemoteUpsert != null) {
      for (final id in transferredIds) {
        final rows = await db.query('contacts',
            where: 'id = ?', whereArgs: [id], limit: 1);
        if (rows.isNotEmpty) {
          _onRemoteUpsert!('contacts', Map<String, dynamic>.from(rows.first));
        }
      }
    }

    return adminId;
  }

  /// Replace the organization's invite code.
  static Future<void> updateOrgInviteCode(String orgId, String newCode) async {
    final db = await database;
    await db.update(
      'organizations',
      {'invite_code': newCode},
      where: 'id = ?',
      whereArgs: [orgId],
    );
    final rows = await db.query('organizations',
        where: 'id = ?', whereArgs: [orgId], limit: 1);
    if (rows.isNotEmpty) {
      _onRemoteUpsert?.call(
          'organizations', Map<String, dynamic>.from(rows.first));
    }
  }

  // =====================================================================
  // RAW ROW ACCESS — used exclusively by RemoteSyncService.
  // These methods bypass model encoding so encrypted blobs and JSON
  // strings are transferred to/from MySQL without modification.
  // =====================================================================

  static Future<Map<String, dynamic>?> getRawUserRow(String userId) async {
    final db = await database;
    final rows =
        await db.query('users', where: 'id = ?', whereArgs: [userId], limit: 1);
    return rows.isEmpty ? null : Map<String, dynamic>.from(rows.first);
  }

  static Future<List<Map<String, dynamic>>> getRawContactRows(
      String ownerId) async {
    final db = await database;
    return (await db
            .query('contacts', where: 'owner_id = ?', whereArgs: [ownerId]))
        .map((r) => Map<String, dynamic>.from(r))
        .toList();
  }

  static Future<List<Map<String, dynamic>>> getRawReminderRows(
      String ownerId) async {
    final db = await database;
    return (await db
            .query('reminders', where: 'owner_id = ?', whereArgs: [ownerId]))
        .map((r) => Map<String, dynamic>.from(r))
        .toList();
  }

  static Future<List<Map<String, dynamic>>> getRawInteractionRows(
      String ownerId) async {
    final db = await database;
    return (await db
            .query('interactions', where: 'owner_id = ?', whereArgs: [ownerId]))
        .map((r) => Map<String, dynamic>.from(r))
        .toList();
  }

  static Future<Map<String, dynamic>?> getRawOrganizationRow(
      String orgId) async {
    final db = await database;
    final rows = await db.query('organizations',
        where: 'id = ?', whereArgs: [orgId], limit: 1);
    return rows.isEmpty ? null : Map<String, dynamic>.from(rows.first);
  }

  static Future<List<Map<String, dynamic>>> getRawOrgMemberRows(
      String orgId) async {
    final db = await database;
    return (await db.query('organization_members',
            where: 'organization_id = ?', whereArgs: [orgId]))
        .map((r) => Map<String, dynamic>.from(r))
        .toList();
  }

  static Future<void> upsertRawRow(
      String table, Map<String, dynamic> row) async {
    final db = await database;
    await db.insert(table, row, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  /// Updates only the photo_path column for a user row.
  /// Used during sync migration from absolute to relative paths.
  static Future<void> updateUserPhotoPath(String userId, String? path) async {
    final db = await database;
    await db.update(
      'users',
      {'photo_path': path},
      where: 'id = ?',
      whereArgs: [userId],
    );
  }

  /// Updates only the photo_path column for a contact row.
  /// Used during sync migration from absolute to relative paths.
  static Future<void> updateContactPhotoPath(
      String contactId, String? path) async {
    final db = await database;
    await db.update(
      'contacts',
      {'photo_path': path},
      where: 'id = ?',
      whereArgs: [contactId],
    );
  }

  /// Persists the timestamp of the most recent successful sync for [userId].
  static Future<void> updateUserLastSync(
      String userId, String isoTimestamp) async {
    final db = await database;
    await db.update(
      'users',
      {'last_sync_at': isoTimestamp},
      where: 'id = ?',
      whereArgs: [userId],
    );
  }

  /// Returns the ISO-8601 timestamp of the most recent successful sync for
  /// [userId], or null if the user has never synced from this device.
  static Future<String?> getUserLastSync(String userId) async {
    final db = await database;
    final rows = await db.query(
      'users',
      columns: ['last_sync_at'],
      where: 'id = ?',
      whereArgs: [userId],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return rows.first['last_sync_at'] as String?;
  }

  // =====================================================================
  // Helpers
  // =====================================================================

  /// Deterministic SHA-256 hash used for unique-lookup columns.
  /// We can't store plaintext for uniqueness checks, so we hash with a
  /// fixed app salt. Combined with normalization this gives stable lookups
  /// without leaking the original value.
  static String _hashLookup(String normalized) {
    if (normalized.isEmpty) return '';
    final bytes = utf8.encode('myleads_lookup_salt_v1::$normalized');
    final digest = sha256.convert(bytes);
    return digest.toString();
  }

  /// Public helper to get the deterministic lookup hash for an email.
  static String lookupHashForEmail(String email) =>
      _hashLookup(Validators.normalizeEmail(email));

  /// Public helper to get the deterministic lookup hash for a phone.
  static String lookupHashForPhone(String phone) =>
      _hashLookup(Validators.normalizePhone(phone));

  @visibleForTesting
  static void injectDatabase(Database db) => _db = db;
}

import 'dart:async';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:postgres/postgres.dart';
import 'package:path/path.dart' as p;

import '../config/app_config.dart';
import 'database_service.dart';
import 'ftp_photo_service.dart';
import 'photo_storage_service.dart';
import 'storage_service.dart';

/// Result of a push or pull sync operation.
class SyncResult {
  final bool success;

  /// Machine-readable error key: 'no_connection' | 'auth_failed' | 'unknown'
  final String? errorCode;
  final int contactCount;
  final int reminderCount;
  final int interactionCount;

  const SyncResult({
    required this.success,
    this.errorCode,
    this.contactCount = 0,
    this.reminderCount = 0,
    this.interactionCount = 0,
  });

  factory SyncResult.err(String code) =>
      SyncResult(success: false, errorCode: code);
}

/// Synchronises the local SQLite database with the remote PostgreSQL server.
///
/// Push copies every local row for the active user to PostgreSQL using
/// INSERT … ON CONFLICT (id) DO UPDATE (upsert).
/// Pull fetches every remote row for the active user and replaces the
/// matching local rows (INSERT OR REPLACE in SQLite).
///
/// Encrypted blobs (_enc columns) and JSON strings are transported
/// as opaque TEXT values; no decryption or re-encoding is performed.
class RemoteSyncService {
  RemoteSyncService._();

  // Set to true after the first successful _ensureSchema so live-write
  // background tasks don't run all 6 CREATE TABLE statements on every call.
  static bool _schemaReady = false;

  // Mirrors SQLite's _dbVersion. Bump this whenever _ensureSchema gains new
  // DDL/migrations so the schema_migrations fast-path re-runs for existing DBs.
  static const int _currentSchemaVersion = 29;

  /// Returns true when the current user's effective plan allows full data-table sync
  /// (premium or business). The `users` table is always synced regardless.
  static Future<bool> _hasSyncPlan() async {
    final plan = await StorageService.getEffectivePlan();
    return plan == 'premium' || plan == 'business';
  }

  // ── Automatic user-row sync ──────────────────────────────────────────────────

  static StreamSubscription<List<ConnectivityResult>>? _connectivitySub;
  static Timer? _syncDebounce;

  /// Starts a connectivity listener that automatically pushes the logged-in
  /// user's profile row to the remote database whenever the device gains
  /// internet access (for all subscription plans).
  ///
  /// Call once at startup, immediately after [wireDatabase].
  static void startUserSync() {
    if (kIsWeb) return;
    _connectivitySub?.cancel();
    _connectivitySub = Connectivity().onConnectivityChanged.listen((results) {
      if (results.contains(ConnectivityResult.none)) return;
      // Debounce: connectivity streams can burst on interface changes.
      _syncDebounce?.cancel();
      _syncDebounce = Timer(const Duration(seconds: 3), () {
        final userId = StorageService.currentUserId;
        if (userId.isEmpty) return;
        _syncUserRow(userId);
      });
    });
    // Attempt an immediate sync in case the device is already online at launch.
    final userId = StorageService.currentUserId;
    if (userId.isNotEmpty) _syncUserRow(userId);
  }

  /// Pushes only the [userId] row to the remote database in the background.
  /// Used by [startUserSync] and is not plan-gated — user profile data is
  /// always kept in sync for all plans.
  ///
  /// Also uploads the user's profile photo to FTP when a local file exists,
  /// so the profile image stays in sync across devices for all subscription plans.
  static void _syncUserRow(String userId) {
    fireAndForget((conn) async {
      final row = await DatabaseService.getRawUserRow(userId);
      if (row == null) return;
      await upsertUser(conn, row);
      // Photo upload is restricted to premium/business — Free plan syncs the
      // user row only (no FTP traffic).
      if (await _hasSyncPlan()) {
        final photoPath = row['photo_path'] as String?;
        if (photoPath != null &&
            photoPath.isNotEmpty &&
            !_isAbsolutePath(photoPath)) {
          await FtpPhotoService.uploadPhoto(photoPath);
        }
      }
    });
  }

  /// Returns the ISO-8601 timestamp of the most recent successful sync for
  /// [userId], or null if the user has never synced from this device.
  static Future<String?> lastSyncForUser(String userId) =>
      DatabaseService.getUserLastSync(userId);

  // ── Connection ──────────────────────────────────────────────────────────────

  static const _kConnectTimeout = Duration(seconds: 10);

  static Future<Connection?> _connect() async {
    if (kIsWeb) return null;
    try {
      // ignore: prefer_const_constructors — host/port/credentials are runtime values
      final conn = await Connection.open(
        Endpoint(
          host: AppConfig.pgHost,
          port: AppConfig.pgPort,
          database: AppConfig.pgDatabase,
          username: AppConfig.pgUsername,
          password: AppConfig.pgPassword,
        ),
        settings: const ConnectionSettings(
          // SslMode.require: encrypts the connection but does not verify the
          // server certificate. Use SslMode.disable if the server has no SSL.
          sslMode: SslMode.require,
          connectTimeout: _kConnectTimeout,
        ),
      );
      return conn;
    } on TimeoutException catch (e) {
      debugPrint('RemoteSyncService connect timeout: $e');
      return null;
    } on HandshakeException catch (e) {
      // SSL/TLS rejected — try SslMode.disable if the server has no SSL cert.
      debugPrint('RemoteSyncService SSL handshake failed: $e');
      return null;
    } on SocketException catch (e) {
      // Port unreachable or server not listening.
      debugPrint('RemoteSyncService socket error: $e');
      return null;
    } catch (e, st) {
      debugPrint('RemoteSyncService connect error [${e.runtimeType}]: $e\n$st');
      return null;
    }
  }

  /// Verifies that credentials are valid and the server is reachable.
  /// Returns null on success, or an error code string on failure.
  static Future<String?> testConnection() async {
    if (kIsWeb) return 'unsupported_platform';
    final connectivity = await Connectivity().checkConnectivity();
    if (connectivity.contains(ConnectivityResult.none)) return 'no_connection';
    final conn = await _connect();
    if (conn == null) return 'auth_failed';
    try {
      await conn.execute('SELECT 1');
      return null;
    } catch (_) {
      return 'auth_failed';
    } finally {
      await conn.close();
    }
  }

  // ── Schema bootstrap ─────────────────────────────────────────────────────────

  static Future<void> _ensureSchema(Connection conn) async {
    // Version-tracking table — created first so the SELECT below always works.
    await conn.execute('''
      CREATE TABLE IF NOT EXISTS "schema_migrations" (
        "version"    SMALLINT    PRIMARY KEY,
        "applied_at" VARCHAR(50) NOT NULL
      )
    ''');

    // Fast-path: if this version has already been applied, skip all DDL/migrations.
    final versionRes = await conn.execute(
      'SELECT 1 FROM "schema_migrations" WHERE "version" = $_currentSchemaVersion LIMIT 1',
    );
    if (versionRes.isNotEmpty) return;

    await conn.execute('''
      CREATE TABLE IF NOT EXISTS "users" (
        "id"                  VARCHAR(36)  NOT NULL,
        "email_enc"           TEXT         NOT NULL,
        "email_lookup"        CHAR(64)     NOT NULL,
        "first_name_enc"      TEXT         NOT NULL,
        "last_name_enc"       TEXT         NOT NULL,
        "nickname_enc"        TEXT,
        "phone_enc"           TEXT,
        "phone_lookup"        CHAR(64),
        "date_of_birth_enc"   TEXT,
        "company_name_enc"    TEXT,
        "company_role_enc"    TEXT,
        "biography_enc"       TEXT,
        "password_hash"       VARCHAR(255) NOT NULL,
        "auth_provider"       VARCHAR(50)  NOT NULL DEFAULT 'email',
        "session_token"       VARCHAR(255),
        "created_at"          VARCHAR(50)  NOT NULL,
        "last_login_at"       VARCHAR(50),
        "password_changed_at" VARCHAR(50)  NOT NULL,
        "photo_path"          TEXT,
        "email_verified"      SMALLINT     NOT NULL DEFAULT 0,
        "organization_id"     VARCHAR(36),
        "org_role"            VARCHAR(20),
        "plan"                        VARCHAR(20)  NOT NULL DEFAULT 'free',
        "last_sync_at"                VARCHAR(50),
        "plan_expires_at"             VARCHAR(50),
        "subscription_billing_cycle"  VARCHAR(10),
        "apple_user_identifier"       VARCHAR(255),
        PRIMARY KEY ("id"),
        UNIQUE ("email_lookup")
      )
    ''');

    await conn.execute('''
      CREATE TABLE IF NOT EXISTS "contacts" (
        "id"                VARCHAR(36)  NOT NULL,
        "owner_id"          VARCHAR(36)  NOT NULL,
        "first_name"        VARCHAR(255) NOT NULL,
        "last_name"         VARCHAR(255) NOT NULL,
        "job_title"         VARCHAR(255),
        "company"           VARCHAR(255),
        "phone"             VARCHAR(100),
        "email"             VARCHAR(320),
        "phone_lookup"      CHAR(64),
        "email_lookup"      CHAR(64),
        "source"            VARCHAR(100),
        "project_1"         VARCHAR(255),
        "project_1_budget"  VARCHAR(100),
        "project_2"         VARCHAR(255),
        "project_2_budget"  VARCHAR(100),
        "interest"          TEXT,
        "notes"             TEXT,
        "tags"              TEXT,
        "status"            VARCHAR(20)  NOT NULL DEFAULT 'warm',
        "created_at"        VARCHAR(50)  NOT NULL,
        "last_contact_date" VARCHAR(50),
        "avatar_color"      VARCHAR(20),
        "capture_method"    VARCHAR(20)  NOT NULL DEFAULT 'manual',
        "photo_path"        TEXT,
        PRIMARY KEY ("id")
      )
    ''');
    await conn.execute(
      'CREATE INDEX IF NOT EXISTS "idx_contacts_owner" ON "contacts" ("owner_id")',
    );

    await conn.execute('''
      CREATE TABLE IF NOT EXISTS "reminders" (
        "id"               VARCHAR(36) NOT NULL,
        "owner_id"         VARCHAR(36) NOT NULL,
        "contact_id"       VARCHAR(36),
        "contact_ids"      TEXT        NOT NULL,
        "start_date_time"  VARCHAR(50) NOT NULL,
        "end_date_time"    VARCHAR(50),
        "repeat_frequency" VARCHAR(20),
        "note"             TEXT        NOT NULL,
        "todo_action"      VARCHAR(20) NOT NULL DEFAULT 'call',
        "priority_v2"      VARCHAR(30) NOT NULL DEFAULT 'normal',
        "title"            VARCHAR(255),
        "description"      TEXT,
        "due_date"         VARCHAR(50),
        "priority"         VARCHAR(20),
        "is_completed"     SMALLINT    NOT NULL DEFAULT 0,
        "created_at"       VARCHAR(50) NOT NULL,
        PRIMARY KEY ("id")
      )
    ''');
    await conn.execute(
      'CREATE INDEX IF NOT EXISTS "idx_reminders_owner" ON "reminders" ("owner_id")',
    );

    await conn.execute('''
      CREATE TABLE IF NOT EXISTS "interactions" (
        "id"         VARCHAR(36) NOT NULL,
        "owner_id"   VARCHAR(36) NOT NULL,
        "contact_id" VARCHAR(36) NOT NULL,
        "type"       VARCHAR(20) NOT NULL,
        "content"    TEXT        NOT NULL,
        "created_at" VARCHAR(50) NOT NULL,
        PRIMARY KEY ("id")
      )
    ''');
    await conn.execute(
      'CREATE INDEX IF NOT EXISTS "idx_interactions_contact" ON "interactions" ("contact_id")',
    );

    await conn.execute('''
      CREATE TABLE IF NOT EXISTS "organizations" (
        "id"          VARCHAR(36)  NOT NULL,
        "name"        VARCHAR(255) NOT NULL,
        "owner_id"    VARCHAR(36)  NOT NULL,
        "invite_code" CHAR(8)      NOT NULL,
        "created_at"  VARCHAR(50)  NOT NULL,
        PRIMARY KEY ("id"),
        UNIQUE ("invite_code")
      )
    ''');

    await conn.execute('''
      CREATE TABLE IF NOT EXISTS "organization_members" (
        "id"                 VARCHAR(36) NOT NULL,
        "organization_id"    VARCHAR(36) NOT NULL,
        "user_id"            VARCHAR(36) NOT NULL,
        "role"               VARCHAR(20) NOT NULL DEFAULT 'member', -- 'owner' | 'admin' | 'member'
        "status"             VARCHAR(20) NOT NULL DEFAULT 'active',
        "joined_at"          VARCHAR(50) NOT NULL,
        "first_name"         VARCHAR(255) NOT NULL,
        "last_name"          VARCHAR(255) NOT NULL,
        "email"              VARCHAR(255),
        "phone"              VARCHAR(100),
        "nickname"           VARCHAR(255),
        "company"            VARCHAR(255),
        "biography"          TEXT,
        "photo_path"         TEXT,
        "can_edit"               SMALLINT    NOT NULL DEFAULT 0,
        "can_create"             SMALLINT    NOT NULL DEFAULT 1,
        "can_view_reminders"     SMALLINT    NOT NULL DEFAULT 0,
        "can_view_history"       SMALLINT    NOT NULL DEFAULT 0,
        "can_export_contacts"    SMALLINT    NOT NULL DEFAULT 0,
        "can_view_others_tasks"  SMALLINT    NOT NULL DEFAULT 0,
        PRIMARY KEY ("id"),
        UNIQUE ("organization_id", "user_id")
      )
    ''');
    await conn.execute(
      'CREATE INDEX IF NOT EXISTS "idx_org_members_org" ON "organization_members" ("organization_id")',
    );
    await conn.execute(
      'CREATE INDEX IF NOT EXISTS "idx_org_members_user" ON "organization_members" ("user_id")',
    );

    // Upgrade existing cloud databases bootstrapped before v11.
    await conn.execute(
      'ALTER TABLE "users" ADD COLUMN IF NOT EXISTS "last_sync_at" VARCHAR(50) DEFAULT NULL',
    );

    // Upgrade existing cloud databases bootstrapped before v12.
    await conn.execute(
      'ALTER TABLE "organization_members" ADD COLUMN IF NOT EXISTS "can_view_history" SMALLINT NOT NULL DEFAULT 0',
    );
    await conn.execute(
      'UPDATE "organization_members" SET "can_view_history" = 1 WHERE "role" = \'admin\' AND "can_view_history" = 0',
    );

    // v20: per-member permission to export shared org contacts.
    await conn.execute(
      'ALTER TABLE "organization_members" ADD COLUMN IF NOT EXISTS "can_export_contacts" SMALLINT NOT NULL DEFAULT 0',
    );
    await conn.execute(
      'UPDATE "organization_members" SET "can_export_contacts" = 1 WHERE "role" = \'admin\' AND "can_export_contacts" = 0',
    );

    // v28: per-member permission to view tasks assigned to other members.
    await conn.execute(
      'ALTER TABLE "organization_members" ADD COLUMN IF NOT EXISTS "can_view_others_tasks" SMALLINT NOT NULL DEFAULT 0',
    );
    await conn.execute(
      'UPDATE "organization_members" SET "can_view_others_tasks" = 1 WHERE "role" IN (\'admin\', \'owner\') AND "can_view_others_tasks" = 0',
    );

    // v24: denormalized member phone, encrypted with org key.
    await conn.execute(
      'ALTER TABLE "organization_members" ADD COLUMN IF NOT EXISTS "phone" VARCHAR(100)',
    );

    // v18: denormalized member profile fields on org membership rows.
    await conn.execute(
      'ALTER TABLE "organization_members" ADD COLUMN IF NOT EXISTS "first_name" VARCHAR(255) NOT NULL DEFAULT \'\'',
    );
    await conn.execute(
      'ALTER TABLE "organization_members" ADD COLUMN IF NOT EXISTS "last_name" VARCHAR(255) NOT NULL DEFAULT \'\'',
    );
    await conn.execute(
      'ALTER TABLE "organization_members" ADD COLUMN IF NOT EXISTS "email" VARCHAR(255)',
    );
    await conn.execute(
      'ALTER TABLE "organization_members" ADD COLUMN IF NOT EXISTS "nickname" VARCHAR(255)',
    );
    await conn.execute(
      'ALTER TABLE "organization_members" ADD COLUMN IF NOT EXISTS "company" VARCHAR(255)',
    );
    await conn.execute(
      'ALTER TABLE "organization_members" ADD COLUMN IF NOT EXISTS "biography" TEXT',
    );
    await conn.execute(
      'ALTER TABLE "organization_members" ADD COLUMN IF NOT EXISTS "photo_path" TEXT',
    );

    // v13: Stripe payment history table.
    await conn.execute('''
      CREATE TABLE IF NOT EXISTS "payment_history" (
        "id"                        VARCHAR(36)   NOT NULL,
        "transaction_id"            VARCHAR(10)   NOT NULL DEFAULT '',
        "user_id"                   VARCHAR(36)   NOT NULL,
        "plan"                      VARCHAR(20)   NOT NULL,
        "billing_cycle"             VARCHAR(10)   NOT NULL,
        "amount"                    NUMERIC(8,2)  NOT NULL,
        "currency"                  CHAR(3)       NOT NULL DEFAULT 'EUR',
        "status"                    VARCHAR(20)   NOT NULL DEFAULT 'succeeded',
        "stripe_payment_intent_id"  VARCHAR(255)  NOT NULL,
        "payment_method"            VARCHAR(50)   NOT NULL DEFAULT 'card',
        "created_at"                VARCHAR(50)   NOT NULL,
        PRIMARY KEY ("id")
      )
    ''');
    await conn.execute(
      'CREATE INDEX IF NOT EXISTS "idx_payment_history_user" ON "payment_history" ("user_id")',
    );
    // v15: add payment_method column to existing payment_history tables.
    try {
      await conn.execute(
        "ALTER TABLE \"payment_history\" ADD COLUMN IF NOT EXISTS \"payment_method\" VARCHAR(50) NOT NULL DEFAULT 'card'",
      );
    } catch (_) {}
    // v19: human-readable transaction ID on payment records.
    try {
      await conn.execute(
        "ALTER TABLE \"payment_history\" ADD COLUMN IF NOT EXISTS \"transaction_id\" VARCHAR(10) NOT NULL DEFAULT ''",
      );
    } catch (_) {}
    // v22: account type — individual vs organization payment.
    try {
      await conn.execute(
        "ALTER TABLE \"payment_history\" ADD COLUMN IF NOT EXISTS \"account_type\" VARCHAR(20) NOT NULL DEFAULT 'individual'",
      );
    } catch (_) {}

    // v16: subscription expiry tracking on users.
    await conn.execute(
      'ALTER TABLE "users" ADD COLUMN IF NOT EXISTS "plan_expires_at" VARCHAR(50) DEFAULT NULL',
    );
    await conn.execute(
      'ALTER TABLE "users" ADD COLUMN IF NOT EXISTS "subscription_billing_cycle" VARCHAR(10) DEFAULT NULL',
    );

    // v17: org license count, expiry, and suspension tracking.
    await conn.execute(
      'ALTER TABLE "organizations" ADD COLUMN IF NOT EXISTS "license_count" INTEGER NOT NULL DEFAULT 1',
    );
    await conn.execute(
      'ALTER TABLE "organizations" ADD COLUMN IF NOT EXISTS "org_plan_expires_at" VARCHAR(50) DEFAULT NULL',
    );
    await conn.execute(
      "ALTER TABLE \"organizations\" ADD COLUMN IF NOT EXISTS \"org_status\" VARCHAR(20) NOT NULL DEFAULT 'active'",
    );
    await conn.execute(
      'ALTER TABLE "organizations" ADD COLUMN IF NOT EXISTS "org_suspended_at" VARCHAR(50) DEFAULT NULL',
    );

    // v23: Apple Sign-In unique identifier support.
    await conn.execute(
      'ALTER TABLE "users" ADD COLUMN IF NOT EXISTS "apple_user_identifier" VARCHAR(255) DEFAULT NULL',
    );

    // v25: introduce 'owner' role — promote org creator's member row from
    // 'admin' to 'owner' and sync users.org_role to match.
    await conn.execute(
      '''UPDATE "organization_members"
         SET "role" = 'owner'
         WHERE "role" = 'admin'
           AND "user_id" IN (
             SELECT "owner_id" FROM "organizations"
             WHERE "organizations"."id" = "organization_members"."organization_id"
           )''',
    );
    await conn.execute(
      '''UPDATE "users"
         SET "org_role" = 'owner'
         WHERE "organization_id" IS NOT NULL
           AND "org_role" = 'admin'
           AND "id" IN (
             SELECT "owner_id" FROM "organizations"
             WHERE "organizations"."id" = "users"."organization_id"
           )''',
    );

    // v26: tasks table (org-first, nullable organization_id for future personal tasks).
    await conn.execute('''
      CREATE TABLE IF NOT EXISTS "tasks" (
        "id"                  VARCHAR(36) NOT NULL,
        "organization_id"     VARCHAR(36),
        "created_by_user_id"  VARCHAR(36) NOT NULL,
        "assigned_to_user_id" VARCHAR(36) NOT NULL,
        "start_date_time"     VARCHAR(50) NOT NULL,
        "end_date_time"       VARCHAR(50),
        "repeat_frequency"    VARCHAR(20),
        "note"                TEXT        NOT NULL DEFAULT '',
        "todo_action"         VARCHAR(20) NOT NULL DEFAULT 'call',
        "priority"            VARCHAR(30) NOT NULL DEFAULT 'normal',
        "is_completed"        SMALLINT    NOT NULL DEFAULT 0,
        "completed_by_user_id" VARCHAR(36),
        "created_at"          VARCHAR(50) NOT NULL,
        PRIMARY KEY ("id")
      )
    ''');
    await conn.execute(
      'CREATE INDEX IF NOT EXISTS "idx_tasks_org" ON "tasks" ("organization_id")',
    );
    await conn.execute(
      'CREATE INDEX IF NOT EXISTS "idx_tasks_assigned" ON "tasks" ("assigned_to_user_id")',
    );
    await conn.execute(
      'CREATE INDEX IF NOT EXISTS "idx_tasks_creator" ON "tasks" ("created_by_user_id")',
    );

    // v27: task_assignees — multi-member task assignment join table.
    await conn.execute('''
      CREATE TABLE IF NOT EXISTS "task_assignees" (
        "task_id"     VARCHAR(36) NOT NULL,
        "user_id"     VARCHAR(36) NOT NULL,
        "assigned_at" VARCHAR(50) NOT NULL,
        PRIMARY KEY ("task_id", "user_id")
      )
    ''');
    await conn.execute(
      'CREATE INDEX IF NOT EXISTS "idx_task_assignees_task" ON "task_assignees" ("task_id")',
    );
    await conn.execute(
      'CREATE INDEX IF NOT EXISTS "idx_task_assignees_user" ON "task_assignees" ("user_id")',
    );
    // Seed from legacy column on existing cloud databases.
    await conn.execute('''
      INSERT INTO "task_assignees" ("task_id", "user_id", "assigned_at")
      SELECT "id", "assigned_to_user_id", "created_at"
      FROM "tasks"
      WHERE "assigned_to_user_id" IS NOT NULL AND "assigned_to_user_id" != ''
      ON CONFLICT ("task_id", "user_id") DO NOTHING
    ''');

    // v29: dedicated access-control table extracted from organization_members.
    // The can_* columns in organization_members are kept for backward compat
    // but are no longer the authority — org_member_permissions is.
    await conn.execute('''
      CREATE TABLE IF NOT EXISTS "org_member_permissions" (
        "id"                    VARCHAR(36)  NOT NULL,
        "organization_id"       VARCHAR(36)  NOT NULL,
        "user_id"               VARCHAR(36)  NOT NULL,
        "can_edit"              SMALLINT     NOT NULL DEFAULT 0,
        "can_create"            SMALLINT     NOT NULL DEFAULT 1,
        "can_view_reminders"    SMALLINT     NOT NULL DEFAULT 0,
        "can_view_history"      SMALLINT     NOT NULL DEFAULT 0,
        "can_export_contacts"   SMALLINT     NOT NULL DEFAULT 0,
        "can_view_others_tasks" SMALLINT     NOT NULL DEFAULT 0,
        "updated_at"            VARCHAR(50)  NOT NULL DEFAULT '',
        PRIMARY KEY ("id"),
        UNIQUE ("organization_id", "user_id")
      )
    ''');
    await conn.execute(
      'CREATE INDEX IF NOT EXISTS "idx_omp_org" ON "org_member_permissions" ("organization_id")',
    );
    await conn.execute(
      'CREATE INDEX IF NOT EXISTS "idx_omp_user" ON "org_member_permissions" ("user_id")',
    );

    // Migrate existing privilege data from organization_members (idempotent).
    // Runs before RLS is enabled so the table owner can write freely.
    await conn.execute('''
      INSERT INTO "org_member_permissions"
        ("id", "organization_id", "user_id",
         "can_edit", "can_create", "can_view_reminders",
         "can_view_history", "can_export_contacts", "can_view_others_tasks",
         "updated_at")
      SELECT "id", "organization_id", "user_id",
             "can_edit", "can_create", "can_view_reminders",
             "can_view_history", "can_export_contacts", "can_view_others_tasks",
             NOW()
      FROM "organization_members"
      ON CONFLICT ("id") DO NOTHING
    ''');

    // Enable RLS: restricts SELECT so regular members can only read their own row.
    // FORCE is intentionally omitted — the app's DB user owns the table and can
    // bypass RLS for schema operations. App-level code is the primary access guard;
    // RLS adds a defence-in-depth layer for future non-owner connection roles.
    await conn.execute(
      'ALTER TABLE "org_member_permissions" ENABLE ROW LEVEL SECURITY',
    );
    await conn.execute(
      'DROP POLICY IF EXISTS "omp_select" ON "org_member_permissions"',
    );
    // Policy: admin/owner sees all rows for their org; member sees only own row.
    // The app sets SET LOCAL app.current_user_id = ? inside a transaction before
    // every SELECT on this table so current_setting() resolves correctly.
    await conn.execute('''
      CREATE POLICY "omp_select" ON "org_member_permissions"
        FOR SELECT
        USING (
          "org_member_permissions"."user_id"
              = current_setting('app.current_user_id', true)
          OR EXISTS (
            SELECT 1 FROM "organization_members" om
            WHERE om."organization_id" = "org_member_permissions"."organization_id"
              AND om."user_id" = current_setting('app.current_user_id', true)
              AND om."role" IN ('admin', 'owner')
              AND om."status" = 'active'
          )
        )
    ''');

    // Stamp the applied version so future calls fast-path past all DDL above.
    await conn.execute(
      Sql.named('''
        INSERT INTO "schema_migrations" ("version", "applied_at")
        VALUES (@v, @at)
        ON CONFLICT ("version") DO UPDATE SET "applied_at" = EXCLUDED."applied_at"
      '''),
      parameters: {
        'v': _currentSchemaVersion,
        'at': DateTime.now().toUtc().toIso8601String(),
      },
    );
  }

  // ── Cloud user helpers ───────────────────────────────────────────────────────

  /// Returns true when a user with [emailLookup] already exists in the remote
  /// database, false when not found or when the server is unreachable.
  static Future<bool> isEmailTakenInCloud(String emailLookup) async {
    if (kIsWeb) return false;
    final connectivity = await Connectivity().checkConnectivity();
    if (connectivity.contains(ConnectivityResult.none)) return false;
    final conn = await _connect();
    if (conn == null) return false;
    try {
      if (!_schemaReady) {
        await _ensureSchema(conn);
        _schemaReady = true;
      }
      final result = await conn.execute(
        Sql.named(
            'SELECT COUNT(*) AS cnt FROM "users" WHERE "email_lookup" = @lookup'),
        parameters: {'lookup': emailLookup},
      );
      if (result.isEmpty) return false;
      final cnt =
          int.tryParse(result.first.toColumnMap()['cnt']?.toString() ?? '0') ??
              0;
      return cnt > 0;
    } catch (e) {
      debugPrint('RemoteSyncService isEmailTakenInCloud error: $e');
      return false;
    } finally {
      await conn.close();
    }
  }

  /// Pushes [userRow] to the remote PostgreSQL database and waits for confirmation.
  ///
  /// Returns `null` on success, or an error message on failure. Unlike the
  /// live-write background callback, this method is awaitable so callers can
  /// gate further actions on a guaranteed cloud registration.
  static Future<String?> registerUserInCloud(
      Map<String, dynamic> userRow) async {
    if (kIsWeb) return null;
    final conn = await _connect();
    if (conn == null) return 'Connexion au serveur impossible';
    try {
      if (!_schemaReady) {
        await _ensureSchema(conn);
        _schemaReady = true;
      }
      await upsertUser(conn, userRow);
      return null;
    } catch (e) {
      debugPrint('RemoteSyncService registerUserInCloud error: $e');
      return "Erreur lors de l'enregistrement sur le serveur";
    } finally {
      await conn.close();
    }
  }

  /// Deletes all records belonging to [userId] from the remote PostgreSQL database.
  ///
  /// Set [includeContacts] to false when the user's contacts have already been
  /// transferred to an org admin (via live-write callbacks) so they are not
  /// accidentally removed from the cloud.
  ///
  /// Returns `null` on success, or an error message on failure.
  static Future<String?> deleteUserFromCloud(
    String userId, {
    bool includeContacts = true,
  }) async {
    if (kIsWeb) return null;
    final conn = await _connect();
    if (conn == null) return 'Connexion au serveur impossible';
    try {
      if (!_schemaReady) {
        await _ensureSchema(conn);
        _schemaReady = true;
      }
      await conn.execute(
        Sql.named('DELETE FROM "interactions" WHERE "owner_id" = @id'),
        parameters: {'id': userId},
      );
      await conn.execute(
        Sql.named('DELETE FROM "reminders" WHERE "owner_id" = @id'),
        parameters: {'id': userId},
      );
      if (includeContacts) {
        await conn.execute(
          Sql.named('DELETE FROM "contacts" WHERE "owner_id" = @id'),
          parameters: {'id': userId},
        );
      }
      await conn.execute(
        Sql.named('DELETE FROM "organization_members" WHERE "user_id" = @id'),
        parameters: {'id': userId},
      );
      await conn.execute(
        Sql.named('DELETE FROM "users" WHERE "id" = @id'),
        parameters: {'id': userId},
      );
      return null;
    } catch (e) {
      debugPrint('RemoteSyncService deleteUserFromCloud error: $e');
      return 'Erreur lors de la suppression sur le serveur';
    } finally {
      await conn.close();
    }
  }

  // ── Cloud user import ────────────────────────────────────────────────────────

  /// Looks up a user in the remote PostgreSQL database by their [emailLookup] hash
  /// and, if found, upserts the row into the local SQLite database so the
  /// normal auth flow can proceed on this device.
  ///
  /// Returns `true` when the record was found and imported successfully.
  /// Returns `false` when the cloud confirms no matching record exists.
  /// Returns `null` when there is no network, the server is unreachable,
  /// or an unexpected error prevents the lookup from completing.
  static Future<bool?> importUserByEmailLookup(String emailLookup) async {
    if (kIsWeb) {
      return null;
    }
    final connectivity = await Connectivity().checkConnectivity();
    if (connectivity.contains(ConnectivityResult.none)) {
      return null;
    }
    debugPrint(
        'RemoteSyncService.importUserByEmailLookup: checking remote user for lookup $emailLookup');
    final conn = await _connect();
    if (conn == null) return null;
    try {
      if (!_schemaReady) {
        await _ensureSchema(conn);
        _schemaReady = true;
      }
      final result = await conn.execute(
        Sql.named('SELECT * FROM "users" WHERE "email_lookup" = @lookup'),
        parameters: {'lookup': emailLookup},
      );
      if (result.isEmpty) {
        debugPrint(
            'RemoteSyncService.importUserByEmailLookup: no remote user found for lookup $emailLookup');
        return false;
      }
      debugPrint(
          'RemoteSyncService.importUserByEmailLookup: remote user found for lookup $emailLookup, upserting local row');
      final row = _normaliseBools(result.first.toColumnMap(), _userBoolCols);
      await DatabaseService.upsertRawRow('users', row);
      return true;
    } catch (e) {
      debugPrint('RemoteSyncService importUserByEmailLookup error: $e');
      return null;
    } finally {
      await conn.close();
    }
  }

  /// Fetches the remote [users] row matching [emailLookup] without persisting
  /// it to the local database. The caller verifies credentials (or a recovery
  /// code) first, then decides whether to save the row.
  ///
  /// Returns the normalised row map when found.
  /// Returns an empty map `{}` when the cloud confirms no matching record.
  /// Returns `null` when the server is unreachable or an error occurs.
  static Future<Map<String, dynamic>?> fetchUserFromCloud(
      String emailLookup) async {
    if (kIsWeb) return null;
    final connectivity = await Connectivity().checkConnectivity();
    if (connectivity.contains(ConnectivityResult.none)) return null;
    final conn = await _connect();
    if (conn == null) return null;
    try {
      if (!_schemaReady) {
        await _ensureSchema(conn);
        _schemaReady = true;
      }
      final result = await conn.execute(
        Sql.named('SELECT * FROM "users" WHERE "email_lookup" = @lookup'),
        parameters: {'lookup': emailLookup},
      );
      if (result.isEmpty) return {};
      return _normaliseBools(result.first.toColumnMap(), _userBoolCols);
    } catch (e) {
      debugPrint('RemoteSyncService.fetchUserFromCloud error: $e');
      return null;
    } finally {
      await conn.close();
    }
  }

  // ── Live-write wiring ───────────────────────────────────────────────────────

  /// Registers callbacks into [DatabaseService] so every local write is
  /// immediately mirrored to the remote PostgreSQL database in the background.
  /// Call once after [StorageService.init] during app startup.
  static void wireDatabase() {
    DatabaseService.wireRemoteSync(
      onUpsert: (table, row) {
        _pushRowBackground(table, row);
      },
      onDelete: (table, id) {
        _deleteRowBackground(table, id);
      },
    );
  }

  /// Dispatches a background upsert for any supported table.
  /// The `users` table is always synced; all other tables require a
  /// premium or business plan, except tasks which also allow org-licensed users.
  static Future<void> _pushRowBackground(
          String table, Map<String, dynamic> row) =>
      fireAndForget((conn) async {
        if (table == 'users') {
          await upsertUser(conn, row);
          return;
        }
        final hasPlan = await _hasSyncPlan();
        if (!hasPlan) {
          if (table == 'tasks' || table == 'task_assignees') {
            final userId = StorageService.currentUserId;
            if (userId.isEmpty) return;
            if (!(await _isOrgLicenseCoveredInCloud(conn, userId))) return;
          } else {
            return;
          }
        }
        switch (table) {
          case 'contacts':
            await _upsertContact(conn, row);
          case 'reminders':
            await _upsertReminder(conn, row);
          case 'interactions':
            await _upsertInteraction(conn, row);
          case 'organizations':
            await upsertOrganization(conn, row);
          case 'organization_members':
            await upsertOrgMember(conn, row);
          case 'org_member_permissions':
            await upsertOrgMemberPermission(conn, row);
          case 'payment_history':
            await _upsertPaymentRecord(conn, row);
          case 'tasks':
            await _upsertTask(conn, row);
          case 'task_assignees':
            await _upsertTaskAssignee(conn, row);
        }
      });

  /// Dispatches a background delete for any supported table.
  /// Handles cascaded deletes for contacts (interactions + reminders)
  /// and organisations (all member rows).
  /// Data-table deletes require a premium or business plan,
  /// except tasks which also allow org-licensed users.
  static Future<void> _deleteRowBackground(String table, String id) =>
      fireAndForget((conn) async {
        final hasPlan = await _hasSyncPlan();
        if (!hasPlan) {
          if (table == 'tasks') {
            final userId = StorageService.currentUserId;
            if (userId.isEmpty) return;
            if (!(await _isOrgLicenseCoveredInCloud(conn, userId))) return;
          } else {
            return;
          }
        }
        if (table == 'contacts') {
          await conn.execute(
            Sql.named('DELETE FROM "interactions" WHERE "contact_id" = @id'),
            parameters: {'id': id},
          );
          await conn.execute(
            Sql.named('DELETE FROM "reminders" WHERE "contact_id" = @id'),
            parameters: {'id': id},
          );
        } else if (table == 'organizations') {
          await conn.execute(
            Sql.named(
                'DELETE FROM "organization_members" WHERE "organization_id" = @id'),
            parameters: {'id': id},
          );
        } else if (table == 'tasks') {
          await conn.execute(
            Sql.named('DELETE FROM "task_assignees" WHERE "task_id" = @id'),
            parameters: {'id': id},
          );
        }
        await conn.execute(
          Sql.named('DELETE FROM "$table" WHERE "id" = @id'),
          parameters: {'id': id},
        );
      });

  /// Opens a connection, runs [action], then closes.
  /// Errors are swallowed so local writes are never blocked by network issues.
  static Future<void> fireAndForget(
      Future<void> Function(Connection) action) async {
    if (kIsWeb) return;
    final connectivity = await Connectivity().checkConnectivity();
    if (connectivity.contains(ConnectivityResult.none)) return;
    final conn = await _connect();
    if (conn == null) return;
    try {
      if (!_schemaReady) {
        await _ensureSchema(conn);
        _schemaReady = true;
      }
      await action(conn);
    } catch (e) {
      debugPrint('RemoteSyncService background write error: $e');
    } finally {
      await conn.close();
    }
  }

  // ── Push (local → remote) ───────────────────────────────────────────────────

  /// Uploads all local data for [userId] to the remote PostgreSQL database.
  static Future<SyncResult> push(String userId) async {
    if (kIsWeb) return SyncResult.err('unsupported_platform');

    final connectivity = await Connectivity().checkConnectivity();
    if (connectivity.contains(ConnectivityResult.none)) {
      return SyncResult.err('no_connection');
    }

    // Photo migration for premium/business runs before the connection to
    // ensure the remote DB receives relative paths. For org-covered free users
    // it runs after the connection is established (once coverage is confirmed).
    final quickPlanCheck = await _hasSyncPlan();
    if (quickPlanCheck) {
      // Migrate old absolute photo paths → relative, then upload to FTP.
      // Must run before the PostgreSQL upserts so the remote DB receives
      // platform-neutral relative paths.
      await _migrateAndUploadPhotos(userId);
    }

    final conn = await _connect();
    if (conn == null) return SyncResult.err('auth_failed');

    try {
      if (!_schemaReady) {
        await _ensureSchema(conn);
        _schemaReady = true;
      }

      // Determine whether full data-table sync is allowed for this user.
      // Org-covered free-plan users receive business-level sync privileges.
      final canFullSync =
          quickPlanCheck || await _isOrgLicenseCoveredInCloud(conn, userId);

      // For org-covered free users, photo migration was deferred until now
      // because the connection was needed to confirm coverage. Still runs
      // before any upserts so relative paths reach the remote DB.
      if (canFullSync && !quickPlanCheck) {
        await _migrateAndUploadPhotos(userId);
      }

      // User row — always synced for all plans.
      final userRow = await DatabaseService.getRawUserRow(userId);
      if (userRow != null) await upsertUser(conn, userRow);

      var contactCount = 0;
      var reminderCount = 0;
      var interactionCount = 0;

      if (canFullSync) {
        // Contacts
        final contacts = await DatabaseService.getRawContactRows(userId);
        for (final row in contacts) {
          await _upsertContact(conn, row);
        }
        contactCount = contacts.length;

        // Reminders
        final reminders = await DatabaseService.getRawReminderRows(userId);
        for (final row in reminders) {
          await _upsertReminder(conn, row);
        }
        reminderCount = reminders.length;

        // Interactions
        final interactions =
            await DatabaseService.getRawInteractionRows(userId);
        for (final row in interactions) {
          await _upsertInteraction(conn, row);
        }
        interactionCount = interactions.length;

        // Organization (if member)
        final orgId = userRow?['organization_id'] as String?;
        if (orgId != null && orgId.isNotEmpty) {
          final orgRow = await DatabaseService.getRawOrganizationRow(orgId);
          if (orgRow != null) await upsertOrganization(conn, orgRow);

          final members = await DatabaseService.getRawOrgMemberRows(orgId);
          for (final row in members) {
            await upsertOrgMember(conn, row);
          }

          // Push org_member_permissions only when the current user is an
          // active admin or owner — regular members must not write this table.
          final userOrgRole = userRow?['org_role'] as String?;
          if (userOrgRole == 'admin' || userOrgRole == 'owner') {
            final permRows =
                await DatabaseService.getRawPermissionRows(orgId);
            for (final row in permRows) {
              await upsertOrgMemberPermission(conn, row);
            }
          }

          // Tasks
          final tasks = await DatabaseService.getRawTaskRows(orgId);
          for (final row in tasks) {
            await _upsertTask(conn, row);
          }

          // Task assignees
          final taskAssignees =
              await DatabaseService.getRawTaskAssigneeRows(orgId);
          for (final row in taskAssignees) {
            await _upsertTaskAssignee(conn, row);
          }
        }

        // Payment history
        final payments = await DatabaseService.getRawPaymentHistoryRows(userId);
        for (final row in payments) {
          await _upsertPaymentRecord(conn, row);
        }
      }

      final now = DateTime.now().toIso8601String();
      await DatabaseService.updateUserLastSync(userId, now);

      return SyncResult(
        success: true,
        contactCount: contactCount,
        reminderCount: reminderCount,
        interactionCount: interactionCount,
      );
    } catch (e) {
      debugPrint('RemoteSyncService push error: $e');
      return SyncResult.err('unknown');
    } finally {
      await conn.close();
    }
  }

  /// Returns true when the local user has any non-user rows that should
  /// be pushed before a cloud download.
  static Future<bool> _hasLocalDataToPush(String userId) async {
    final contacts = await DatabaseService.getRawContactRows(userId);
    if (contacts.isNotEmpty) return true;
    final reminders = await DatabaseService.getRawReminderRows(userId);
    if (reminders.isNotEmpty) return true;
    final interactions = await DatabaseService.getRawInteractionRows(userId);
    return interactions.isNotEmpty;
  }

  // ── Targeted user-field updates ─────────────────────────────────────────────

  /// Returns the `id` of the cloud user whose `email_lookup` matches [emailLookup],
  /// or `null` when not found or the server is unreachable.
  /// Lighter than [importUserByEmailLookup] — does not upsert locally.
  static Future<String?> findCloudUserIdByEmailLookup(
      String emailLookup) async {
    if (kIsWeb) return null;
    final connectivity = await Connectivity().checkConnectivity();
    if (connectivity.contains(ConnectivityResult.none)) return null;
    final conn = await _connect();
    if (conn == null) return null;
    try {
      final result = await conn.execute(
        Sql.named(
            'SELECT "id" FROM "users" WHERE "email_lookup" = @lookup LIMIT 1'),
        parameters: {'lookup': emailLookup},
      );
      if (result.isEmpty) return null;
      return result.first.toColumnMap()['id']?.toString();
    } catch (e) {
      debugPrint('RemoteSyncService findCloudUserIdByEmailLookup error: $e');
      return null;
    } finally {
      await conn.close();
    }
  }

  /// Updates only the password-related columns for [userId] in the remote
  /// database. The background live-write callback fired by [DatabaseService]
  /// intentionally excludes these security fields from its UPDATE clause, so
  /// this explicit call is required after every local password change.
  static Future<void> updatePasswordInCloud({
    required String userId,
    required String passwordHash,
    required String? sessionToken,
    required String? passwordChangedAt,
  }) async {
    if (kIsWeb) return;
    final conn = await _connect();
    if (conn == null) return;
    try {
      await conn.execute(
        Sql.named(
          'UPDATE "users" '
          'SET "password_hash" = @hash, '
          '"session_token" = @token, '
          '"password_changed_at" = @changed_at '
          'WHERE "id" = @id',
        ),
        parameters: {
          'hash': passwordHash,
          'token': sessionToken,
          'changed_at': passwordChangedAt,
          'id': userId,
        },
      );
    } catch (e) {
      debugPrint('RemoteSyncService updatePasswordInCloud error: $e');
    } finally {
      await conn.close();
    }
  }

  /// Sets `email_verified = 1` for [userId] in the remote database.
  /// The live-write background callback excludes this field from its UPDATE
  /// clause, so an explicit call is required after email verification.
  static Future<void> updateEmailVerifiedInCloud(String userId) async {
    if (kIsWeb) return;
    final conn = await _connect();
    if (conn == null) return;
    try {
      await conn.execute(
        Sql.named('UPDATE "users" SET "email_verified" = 1 WHERE "id" = @id'),
        parameters: {'id': userId},
      );
    } catch (e) {
      debugPrint('RemoteSyncService updateEmailVerifiedInCloud error: $e');
    } finally {
      await conn.close();
    }
  }

  /// Updates only the email-related columns for [userId] in the remote
  /// database. The background live-write callback updates `email_enc` but
  /// intentionally skips `email_lookup`, so a stale lookup hash would break
  /// cloud login after an email change. This method fixes both fields.
  static Future<void> updateEmailInCloud({
    required String userId,
    required String emailEnc,
    required String emailLookup,
    required String? sessionToken,
  }) async {
    if (kIsWeb) {
      return;
    }
    final conn = await _connect();
    if (conn == null) {
      return;
    }
    try {
      await conn.execute(
        Sql.named(
          'UPDATE "users" '
          'SET "email_enc" = @enc, '
          '"email_lookup" = @lookup, '
          '"session_token" = @token, '
          '"email_verified" = 1 '
          'WHERE "id" = @id',
        ),
        parameters: {
          'enc': emailEnc,
          'lookup': emailLookup,
          'token': sessionToken,
          'id': userId,
        },
      );
    } catch (e) {
      debugPrint('RemoteSyncService updateEmailInCloud error: $e');
    } finally {
      await conn.close();
    }
  }

  // ── Pull (remote → local) ───────────────────────────────────────────────────

  /// Downloads remote data for [userId] and replaces local rows.
  ///
  /// When the user belongs to an organisation, also pulls contacts (and
  /// reminders when the member has `can_view_reminders = 1` or `role = admin`)
  /// from every active org member, so all members share one view of the data.
  ///
  /// If the user already has local data, this method first pushes local
  /// changes online before downloading remote data back to local storage.
  static Future<SyncResult> pull(String userId) async {
    if (kIsWeb) return SyncResult.err('unsupported_platform');

    final connectivity = await Connectivity().checkConnectivity();
    if (connectivity.contains(ConnectivityResult.none)) {
      return SyncResult.err('no_connection');
    }

    if (await _hasLocalDataToPush(userId)) {
      final pushResult = await push(userId);
      if (!pushResult.success) {
        return pushResult;
      }
    }

    final conn = await _connect();
    if (conn == null) return SyncResult.err('auth_failed');

    try {
      // ── Own user row — always pulled for all plans ───────────────────────
      final userResult = await conn.execute(
        Sql.named('SELECT * FROM "users" WHERE "id" = @id'),
        parameters: {'id': userId},
      );
      final localRow = await DatabaseService.getRawUserRow(userId);
      final preservedToken = localRow?['session_token'] as String?;
      final preservedPasswordHash = localRow?['password_hash'] as String?;
      for (final row in userResult) {
        final cloudRow = _normaliseBools(row.toColumnMap(), _userBoolCols);
        // Preserve the device-local session_token and password_hash.
        // The cloud row was written by a different device and carries that
        // device's token; overwriting the local token would invalidate the
        // current session on the next app restart (StorageService.init
        // compares the secure-storage token with the DB value).
        if (localRow != null) {
          cloudRow['session_token'] = preservedToken;
          cloudRow['password_hash'] = preservedPasswordHash;
        }
        await DatabaseService.upsertRawRow('users', cloudRow);
      }
      if (preservedToken != null && StorageService.currentUser?.id == userId) {
        final refreshedUser = await DatabaseService.findUserById(userId);
        if (refreshedUser != null) {
          await StorageService.setCurrentSession(refreshedUser, preservedToken);
        }
      }

      // Data-table pull is restricted to premium / business plans,
      // unless the user is covered by a valid organisation licence.
      if (!(await _hasSyncPlan())) {
        final orgCovered = await _isOrgLicenseCoveredInCloud(conn, userId);
        if (!orgCovered) {
          final now = DateTime.now().toIso8601String();
          await DatabaseService.updateUserLastSync(userId, now);
          return const SyncResult(success: true);
        }
        // Org licence grants full-sync privileges — fall through.
      }
      // Reached here: either premium/business plan or org-licence covered.
      const canFullSync = true;

      // ── Org membership & permissions ────────────────────────────────────
      final orgId = await _remoteOrgIdForUser(conn, userId);
      var pullOwnerIds = <String>[userId];
      var canPullOrgReminders = false;
      var isAdminOrOwner = false;

      if (orgId != null) {
        final memResult = await conn.execute(
          Sql.named(
            'SELECT "user_id", "role", "can_view_reminders" '
            'FROM "organization_members" '
            'WHERE "organization_id" = @orgId AND "status" = @active',
          ),
          parameters: {'orgId': orgId, 'active': 'active'},
        );
        for (final row in memResult) {
          final m = row.toColumnMap();
          final uid = m['user_id']?.toString();
          if (uid != null && uid.isNotEmpty) pullOwnerIds.add(uid);
          if (uid == userId) {
            final role = m['role']?.toString();
            final cvr = m['can_view_reminders']?.toString();
            canPullOrgReminders = role == 'admin' || cvr == '1';
            isAdminOrOwner = role == 'admin' || role == 'owner';
          }
        }
        pullOwnerIds = pullOwnerIds.toSet().toList();
      }

      // ── Contacts ──────────────────────────────────────────────────────────
      int contactCount = 0;
      if (pullOwnerIds.length == 1) {
        final res = await conn.execute(
          Sql.named('SELECT * FROM "contacts" WHERE "owner_id" = @uid'),
          parameters: {'uid': userId},
        );
        for (final row in res) {
          await DatabaseService.upsertRawRow('contacts', row.toColumnMap());
          contactCount++;
        }
      } else {
        final inP = _buildInParams(pullOwnerIds);
        final res = await conn.execute(
          Sql.named(
              'SELECT * FROM "contacts" WHERE "owner_id" IN (${inP.placeholders})'),
          parameters: inP.params,
        );
        for (final row in res) {
          await DatabaseService.upsertRawRow('contacts', row.toColumnMap());
          contactCount++;
        }
      }

      // ── Reminders ─────────────────────────────────────────────────────────
      int reminderCount = 0;
      // Always pull the current user's own reminders.
      final ownRem = await conn.execute(
        Sql.named('SELECT * FROM "reminders" WHERE "owner_id" = @uid'),
        parameters: {'uid': userId},
      );
      for (final row in ownRem) {
        await DatabaseService.upsertRawRow(
            'reminders', _normaliseBools(row.toColumnMap(), _reminderBoolCols));
        reminderCount++;
      }
      // Pull other org members' reminders only when permitted.
      if (canPullOrgReminders && pullOwnerIds.length > 1) {
        final others = pullOwnerIds.where((id) => id != userId).toList();
        final inP = _buildInParams(others);
        final orgRem = await conn.execute(
          Sql.named(
              'SELECT * FROM "reminders" WHERE "owner_id" IN (${inP.placeholders})'),
          parameters: inP.params,
        );
        for (final row in orgRem) {
          await DatabaseService.upsertRawRow('reminders',
              _normaliseBools(row.toColumnMap(), _reminderBoolCols));
          reminderCount++;
        }
      }

      // ── Interactions ──────────────────────────────────────────────────────
      int interactionCount = 0;
      if (pullOwnerIds.length == 1) {
        final res = await conn.execute(
          Sql.named('SELECT * FROM "interactions" WHERE "owner_id" = @uid'),
          parameters: {'uid': userId},
        );
        for (final row in res) {
          await DatabaseService.upsertRawRow('interactions', row.toColumnMap());
          interactionCount++;
        }
      } else {
        final inP = _buildInParams(pullOwnerIds);
        final res = await conn.execute(
          Sql.named(
              'SELECT * FROM "interactions" WHERE "owner_id" IN (${inP.placeholders})'),
          parameters: inP.params,
        );
        for (final row in res) {
          await DatabaseService.upsertRawRow('interactions', row.toColumnMap());
          interactionCount++;
        }
      }

      // ── Organisation & member rows ─────────────────────────────────────────
      if (orgId != null) {
        final orgRes = await conn.execute(
          Sql.named('SELECT * FROM "organizations" WHERE "id" = @id'),
          parameters: {'id': orgId},
        );
        for (final row in orgRes) {
          await DatabaseService.upsertRawRow(
              'organizations', row.toColumnMap());
        }

        final memRes = await conn.execute(
          Sql.named(
              'SELECT * FROM "organization_members" WHERE "organization_id" = @id'),
          parameters: {'id': orgId},
        );
        final memberUserIds = <String>[];
        for (final row in memRes) {
          await DatabaseService.upsertRawRow('organization_members',
              _normaliseBools(row.toColumnMap(), _memberBoolCols));
          final uid = row.toColumnMap()['user_id'];
          if (uid is String && uid.isNotEmpty) memberUserIds.add(uid);
        }
        // Reconcile: remove local members that no longer exist in the cloud.
        await DatabaseService.reconcileOrgMembers(orgId, memberUserIds);

        // ── org_member_permissions ─────────────────────────────────────────
        // Admin/owner: pull all rows for the org.
        // Regular member: pull only own row.
        // SET LOCAL app.current_user_id inside a transaction so the RLS
        // SELECT policy resolves correctly for non-owner DB connections.
        try {
          if (isAdminOrOwner) {
            await conn.runTx((tx) async {
              await tx.execute(
                Sql.named('SET LOCAL app.current_user_id = @uid'),
                parameters: {'uid': userId},
              );
              final permRes = await tx.execute(
                Sql.named(
                    'SELECT * FROM "org_member_permissions" WHERE "organization_id" = @orgId'),
                parameters: {'orgId': orgId},
              );
              for (final row in permRes) {
                await DatabaseService.upsertRawRow('org_member_permissions',
                    _normaliseBools(row.toColumnMap(), _permBoolCols));
              }
            });
          } else {
            await conn.runTx((tx) async {
              await tx.execute(
                Sql.named('SET LOCAL app.current_user_id = @uid'),
                parameters: {'uid': userId},
              );
              final permRes = await tx.execute(
                Sql.named(
                    'SELECT * FROM "org_member_permissions" WHERE "organization_id" = @orgId AND "user_id" = @uid'),
                parameters: {'orgId': orgId, 'uid': userId},
              );
              for (final row in permRes) {
                await DatabaseService.upsertRawRow('org_member_permissions',
                    _normaliseBools(row.toColumnMap(), _permBoolCols));
              }
            });
          }
        } catch (e) {
          debugPrint('RemoteSyncService pull org_member_permissions: $e');
        }

        // ── Tasks ─────────────────────────────────────────────────────────
        final taskRes = await conn.execute(
          Sql.named(
              'SELECT * FROM "tasks" WHERE "organization_id" = @orgId'),
          parameters: {'orgId': orgId},
        );
        for (final row in taskRes) {
          final r = row.toColumnMap();
          await DatabaseService.upsertRawRow('tasks', {
            'id': r['id'],
            'organization_id': r['organization_id'],
            'created_by_user_id': r['created_by_user_id'],
            'assigned_to_user_id': r['assigned_to_user_id'],
            'start_date_time': r['start_date_time'],
            'end_date_time': r['end_date_time'],
            'repeat_frequency': r['repeat_frequency'],
            'note': r['note'] ?? '',
            'todo_action': r['todo_action'] ?? 'call',
            'priority': r['priority'] ?? 'normal',
            'is_completed': r['is_completed'] is bool
                ? (r['is_completed'] as bool ? 1 : 0)
                : (int.tryParse(r['is_completed']?.toString() ?? '0') ?? 0),
            'completed_by_user_id': r['completed_by_user_id'],
            'created_at': r['created_at'],
          });
        }

        // ── Task assignees ─────────────────────────────────────────────────
        final taskAssigneeRes = await conn.execute(
          Sql.named(
            'SELECT ta."task_id", ta."user_id", ta."assigned_at" '
            'FROM "task_assignees" ta '
            'INNER JOIN "tasks" t ON t."id" = ta."task_id" '
            'WHERE t."organization_id" = @orgId',
          ),
          parameters: {'orgId': orgId},
        );
        for (final row in taskAssigneeRes) {
          final r = row.toColumnMap();
          await DatabaseService.upsertRawRow('task_assignees', {
            'task_id': r['task_id']?.toString() ?? '',
            'user_id': r['user_id']?.toString() ?? '',
            'assigned_at': r['assigned_at']?.toString() ?? '',
          });
        }
      }

      // ── Payment history ───────────────────────────────────────────────────
      if (canFullSync) {
        final payRes = await conn.execute(
          Sql.named('SELECT * FROM "payment_history" WHERE "user_id" = @uid'),
          parameters: {'uid': userId},
        );
        for (final row in payRes) {
          final r = row.toColumnMap();
          await DatabaseService.upsertRawRow('payment_history', {
            'id': r['id'],
            'user_id': r['user_id'],
            'plan': r['plan'],
            'billing_cycle': r['billing_cycle'],
            'amount': double.tryParse(r['amount']?.toString() ?? '0') ?? 0.0,
            'currency': r['currency'] ?? 'EUR',
            'status': r['status'] ?? 'succeeded',
            'stripe_payment_intent_id': r['stripe_payment_intent_id'],
            'payment_method': r['payment_method'] ?? 'card',
            'created_at': r['created_at'],
          });
        }
      }

      // Download any photos that are referenced in the DB but missing locally.
      await _downloadMissingPhotos(userId, pullOwnerIds);

      final now = DateTime.now().toIso8601String();
      await DatabaseService.updateUserLastSync(userId, now);

      return SyncResult(
        success: true,
        contactCount: contactCount,
        reminderCount: reminderCount,
        interactionCount: interactionCount,
      );
    } catch (e) {
      debugPrint('RemoteSyncService pull error: $e');
      return SyncResult.err('unknown');
    } finally {
      await conn.close();
    }
  }

  // ── Upsert helpers ──────────────────────────────────────────────────────────

  static Future<void> upsertUser(
      Connection conn, Map<String, dynamic> r) async {
    // ✅ Supprimer un éventuel doublon avec même email mais id différent
    // (ex: compte recréé, changement d'auth provider, etc.)
    await conn.execute(
      Sql.named('''
      DELETE FROM "users"
      WHERE email_lookup = @email_lookup
        AND id != @id
    '''),
      parameters: {
        'email_lookup': r['email_lookup'],
        'id': r['id'],
      },
    );

    // ✅ Upsert normal sur id
    await conn.execute(
      Sql.named('''
      INSERT INTO "users"
        (id,email_enc,email_lookup,first_name_enc,last_name_enc,nickname_enc,
         phone_enc,phone_lookup,date_of_birth_enc,company_name_enc,company_role_enc,
         biography_enc,password_hash,auth_provider,session_token,created_at,
         last_login_at,password_changed_at,photo_path,email_verified,
         organization_id,org_role,plan,last_sync_at,
         plan_expires_at,subscription_billing_cycle)
      VALUES
        (@id,@email_enc,@email_lookup,@first_name_enc,@last_name_enc,@nickname_enc,
         @phone_enc,@phone_lookup,@date_of_birth_enc,@company_name_enc,@company_role_enc,
         @biography_enc,@password_hash,@auth_provider,@session_token,@created_at,
         @last_login_at,@password_changed_at,@photo_path,@email_verified,
         @organization_id,@org_role,@plan,@last_sync_at,
         @plan_expires_at,@subscription_billing_cycle)
      ON CONFLICT (id) DO UPDATE SET
        email_enc=EXCLUDED.email_enc,
        email_lookup=EXCLUDED.email_lookup,
        first_name_enc=EXCLUDED.first_name_enc,
        last_name_enc=EXCLUDED.last_name_enc,
        nickname_enc=EXCLUDED.nickname_enc,
        phone_enc=EXCLUDED.phone_enc,
        phone_lookup=EXCLUDED.phone_lookup,
        date_of_birth_enc=EXCLUDED.date_of_birth_enc,
        company_name_enc=EXCLUDED.company_name_enc,
        company_role_enc=EXCLUDED.company_role_enc,
        biography_enc=EXCLUDED.biography_enc,
        photo_path=EXCLUDED.photo_path,
        plan=EXCLUDED.plan,
        organization_id=EXCLUDED.organization_id,
        org_role=EXCLUDED.org_role,
        last_sync_at=EXCLUDED.last_sync_at,
        plan_expires_at=EXCLUDED.plan_expires_at,
        subscription_billing_cycle=EXCLUDED.subscription_billing_cycle
    '''),
      parameters: {
        'id': r['id'],
        'email_enc': r['email_enc'],
        'email_lookup': r['email_lookup'],
        'first_name_enc': r['first_name_enc'],
        'last_name_enc': r['last_name_enc'],
        'nickname_enc': r['nickname_enc'],
        'phone_enc': r['phone_enc'],
        'phone_lookup': r['phone_lookup'],
        'date_of_birth_enc': r['date_of_birth_enc'],
        'company_name_enc': r['company_name_enc'],
        'company_role_enc': r['company_role_enc'],
        'biography_enc': r['biography_enc'],
        'password_hash': r['password_hash'],
        'auth_provider': r['auth_provider'] ?? 'email',
        'session_token': r['session_token'],
        'created_at': r['created_at'],
        'last_login_at': r['last_login_at'],
        'password_changed_at': r['password_changed_at'],
        'photo_path': r['photo_path'],
        'email_verified': r['email_verified'] ?? 0,
        'organization_id': r['organization_id'],
        'org_role': r['org_role'],
        'plan': r['plan'] ?? 'free',
        'last_sync_at': r['last_sync_at'],
        'plan_expires_at': r['plan_expires_at'],
        'subscription_billing_cycle': r['subscription_billing_cycle'],
      },
    );
  }

  static Future<void> _upsertContact(
      Connection conn, Map<String, dynamic> r) async {
    // ✅ Étape 1 : supprimer uniquement le doublon du MÊME utilisateur
    // avec même email mais id différent
    await conn.execute(
      Sql.named('''
      DELETE FROM "contacts"
      WHERE owner_id    = @owner_id       -- ✅ restreint à CET utilisateur
        AND email_lookup = @email_lookup  -- même email
        AND id           != @id           -- mais id différent
    '''),
      parameters: {
        'owner_id': r['owner_id'],
        'email_lookup': r['email_lookup'],
        'id': r['id'],
      },
    );

    // ✅ Étape 2 : upsert normal
    await conn.execute(
      Sql.named('''
      INSERT INTO "contacts"
        (id,owner_id,first_name,last_name,job_title,company,phone,email,
         phone_lookup,email_lookup,source,project_1,project_1_budget,
         project_2,project_2_budget,interest,notes,tags,status,created_at,
         last_contact_date,avatar_color,capture_method,photo_path)
      VALUES
        (@id,@owner_id,@first_name,@last_name,@job_title,@company,@phone,@email,
         @phone_lookup,@email_lookup,@source,@project_1,@project_1_budget,
         @project_2,@project_2_budget,@interest,@notes,@tags,@status,@created_at,
         @last_contact_date,@avatar_color,@capture_method,@photo_path)
      ON CONFLICT (id) DO UPDATE SET
        first_name=EXCLUDED.first_name,
        last_name=EXCLUDED.last_name,
        job_title=EXCLUDED.job_title,
        company=EXCLUDED.company,
        phone=EXCLUDED.phone,
        email=EXCLUDED.email,
        phone_lookup=EXCLUDED.phone_lookup,
        email_lookup=EXCLUDED.email_lookup,
        source=EXCLUDED.source,
        project_1=EXCLUDED.project_1,
        project_1_budget=EXCLUDED.project_1_budget,
        project_2=EXCLUDED.project_2,
        project_2_budget=EXCLUDED.project_2_budget,
        interest=EXCLUDED.interest,
        notes=EXCLUDED.notes,
        tags=EXCLUDED.tags,
        status=EXCLUDED.status,
        last_contact_date=EXCLUDED.last_contact_date,
        avatar_color=EXCLUDED.avatar_color,
        capture_method=EXCLUDED.capture_method,
        photo_path=EXCLUDED.photo_path
    '''),
      parameters: {
        'id': r['id'],
        'owner_id': r['owner_id'],
        'first_name': r['first_name'],
        'last_name': r['last_name'],
        'job_title': r['job_title'],
        'company': r['company'],
        'phone': r['phone'],
        'email': r['email'],
        'phone_lookup': r['phone_lookup'],
        'email_lookup': r['email_lookup'],
        'source': r['source'],
        'project_1': r['project_1'],
        'project_1_budget': r['project_1_budget'],
        'project_2': r['project_2'],
        'project_2_budget': r['project_2_budget'],
        'interest': r['interest'],
        'notes': r['notes'],
        'tags': r['tags'],
        'status': r['status'] ?? 'warm',
        'created_at': r['created_at'],
        'last_contact_date': r['last_contact_date'],
        'avatar_color': r['avatar_color'],
        'capture_method': r['capture_method'] ?? 'manual',
        'photo_path': r['photo_path'],
      },
    );
  }

  static Future<void> _upsertReminder(
      Connection conn, Map<String, dynamic> r) async {
    await conn.execute(
      Sql.named('''
        INSERT INTO "reminders"
          (id,owner_id,contact_id,contact_ids,start_date_time,end_date_time,
           repeat_frequency,note,todo_action,priority_v2,title,description,
           due_date,priority,is_completed,created_at)
        VALUES
          (@id,@owner_id,@contact_id,@contact_ids,@start_date_time,@end_date_time,
           @repeat_frequency,@note,@todo_action,@priority_v2,@title,@description,
           @due_date,@priority,@is_completed,@created_at)
        ON CONFLICT (id) DO UPDATE SET
          contact_id=EXCLUDED.contact_id,contact_ids=EXCLUDED.contact_ids,
          start_date_time=EXCLUDED.start_date_time,end_date_time=EXCLUDED.end_date_time,
          repeat_frequency=EXCLUDED.repeat_frequency,note=EXCLUDED.note,
          todo_action=EXCLUDED.todo_action,priority_v2=EXCLUDED.priority_v2,
          is_completed=EXCLUDED.is_completed
      '''),
      parameters: {
        'id': r['id'],
        'owner_id': r['owner_id'],
        'contact_id': r['contact_id'],
        'contact_ids': r['contact_ids'] ?? '[]',
        'start_date_time': r['start_date_time'],
        'end_date_time': r['end_date_time'],
        'repeat_frequency': r['repeat_frequency'],
        'note': r['note'] ?? '',
        'todo_action': r['todo_action'] ?? 'call',
        'priority_v2': r['priority_v2'] ?? 'normal',
        'title': r['title'],
        'description': r['description'],
        'due_date': r['due_date'],
        'priority': r['priority'],
        'is_completed': r['is_completed'] ?? 0,
        'created_at': r['created_at'],
      },
    );
  }

  static Future<void> _upsertTask(
      Connection conn, Map<String, dynamic> r) async {
    await conn.execute(
      Sql.named('''
        INSERT INTO "tasks"
          (id,organization_id,created_by_user_id,assigned_to_user_id,
           start_date_time,end_date_time,repeat_frequency,note,
           todo_action,priority,is_completed,completed_by_user_id,created_at)
        VALUES
          (@id,@organization_id,@created_by_user_id,@assigned_to_user_id,
           @start_date_time,@end_date_time,@repeat_frequency,@note,
           @todo_action,@priority,@is_completed,@completed_by_user_id,@created_at)
        ON CONFLICT (id) DO UPDATE SET
          assigned_to_user_id=EXCLUDED.assigned_to_user_id,
          start_date_time=EXCLUDED.start_date_time,
          end_date_time=EXCLUDED.end_date_time,
          repeat_frequency=EXCLUDED.repeat_frequency,
          note=EXCLUDED.note,
          todo_action=EXCLUDED.todo_action,
          priority=EXCLUDED.priority,
          is_completed=EXCLUDED.is_completed,
          completed_by_user_id=EXCLUDED.completed_by_user_id
      '''),
      parameters: {
        'id': r['id'],
        'organization_id': r['organization_id'],
        'created_by_user_id': r['created_by_user_id'],
        'assigned_to_user_id': r['assigned_to_user_id'],
        'start_date_time': r['start_date_time'],
        'end_date_time': r['end_date_time'],
        'repeat_frequency': r['repeat_frequency'],
        'note': r['note'] ?? '',
        'todo_action': r['todo_action'] ?? 'call',
        'priority': r['priority'] ?? 'normal',
        'is_completed': r['is_completed'] ?? 0,
        'completed_by_user_id': r['completed_by_user_id'],
        'created_at': r['created_at'],
      },
    );
  }

  /// Push + pull for the tasks table only.
  /// Called on tasks-screen open and pull-to-refresh.
  /// Same plan/org-licence gate as the full sync.
  static Future<void> syncTasksForOrg(String userId, String orgId) async {
    if (kIsWeb) return;
    final connectivity = await Connectivity().checkConnectivity();
    if (connectivity.contains(ConnectivityResult.none)) return;

    final conn = await _connect();
    if (conn == null) return;

    try {
      if (!_schemaReady) {
        await _ensureSchema(conn);
        _schemaReady = true;
      }
      if (!(await _hasSyncPlan())) {
        if (!(await _isOrgLicenseCoveredInCloud(conn, userId))) return;
      }

      // Push local → cloud
      final localTasks = await DatabaseService.getRawTaskRows(orgId);
      for (final row in localTasks) {
        await _upsertTask(conn, row);
      }

      // Pull cloud → local
      final taskRes = await conn.execute(
        Sql.named('SELECT * FROM "tasks" WHERE "organization_id" = @orgId'),
        parameters: {'orgId': orgId},
      );
      for (final row in taskRes) {
        final r = row.toColumnMap();
        await DatabaseService.upsertRawRow('tasks', {
          'id': r['id'],
          'organization_id': r['organization_id'],
          'created_by_user_id': r['created_by_user_id'],
          'assigned_to_user_id': r['assigned_to_user_id'],
          'start_date_time': r['start_date_time'],
          'end_date_time': r['end_date_time'],
          'repeat_frequency': r['repeat_frequency'],
          'note': r['note'] ?? '',
          'todo_action': r['todo_action'] ?? 'call',
          'priority': r['priority'] ?? 'normal',
          'is_completed': r['is_completed'] is bool
              ? (r['is_completed'] as bool ? 1 : 0)
              : (int.tryParse(r['is_completed']?.toString() ?? '0') ?? 0),
          'completed_by_user_id': r['completed_by_user_id'],
          'created_at': r['created_at'],
        });
      }
    } catch (e) {
      debugPrint('RemoteSyncService.syncTasksForOrg: $e');
    } finally {
      await conn.close();
    }
  }

  static Future<void> _upsertTaskAssignee(
      Connection conn, Map<String, dynamic> r) async {
    await conn.execute(
      Sql.named('''
        INSERT INTO "task_assignees" ("task_id", "user_id", "assigned_at")
        VALUES (@task_id, @user_id, @assigned_at)
        ON CONFLICT ("task_id", "user_id") DO UPDATE SET
          "assigned_at" = EXCLUDED."assigned_at"
      '''),
      parameters: {
        'task_id': r['task_id'],
        'user_id': r['user_id'],
        'assigned_at': r['assigned_at'],
      },
    );
  }

  static Future<void> _upsertInteraction(
      Connection conn, Map<String, dynamic> r) async {
    await conn.execute(
      Sql.named('''
        INSERT INTO "interactions" (id,owner_id,contact_id,type,content,created_at)
        VALUES (@id,@owner_id,@contact_id,@type,@content,@created_at)
        ON CONFLICT (id) DO UPDATE SET
          type=EXCLUDED.type,content=EXCLUDED.content
      '''),
      parameters: {
        'id': r['id'],
        'owner_id': r['owner_id'],
        'contact_id': r['contact_id'],
        'type': r['type'],
        'content': r['content'],
        'created_at': r['created_at'],
      },
    );
  }

  static Future<void> upsertOrganization(
      Connection conn, Map<String, dynamic> r) async {
    await conn.execute(
      Sql.named('''
        INSERT INTO "organizations"
          (id,name,owner_id,invite_code,created_at,
           license_count,org_plan_expires_at,org_status,org_suspended_at)
        VALUES
          (@id,@name,@owner_id,@invite_code,@created_at,
           @license_count,@org_plan_expires_at,@org_status,@org_suspended_at)
        ON CONFLICT (id) DO UPDATE SET
          name=EXCLUDED.name,invite_code=EXCLUDED.invite_code,
          license_count=EXCLUDED.license_count,
          org_plan_expires_at=EXCLUDED.org_plan_expires_at,
          org_status=EXCLUDED.org_status,
          org_suspended_at=EXCLUDED.org_suspended_at
      '''),
      parameters: {
        'id': r['id'],
        'name': r['name'],
        'owner_id': r['owner_id'],
        'invite_code': r['invite_code'],
        'created_at': r['created_at'],
        'license_count': r['license_count'] ?? 1,
        'org_plan_expires_at': r['org_plan_expires_at'],
        'org_status': r['org_status'] ?? 'active',
        'org_suspended_at': r['org_suspended_at'],
      },
    );
  }

  /// Permanently deletes all cloud data for the given organization after the
  /// 6-month suspension window has elapsed without renewal.
  static Future<void> deleteOrganizationDataFromCloud(String orgId) async {
    if (kIsWeb) return;
    final conn = await _connect();
    if (conn == null) return;
    try {
      if (!_schemaReady) {
        await _ensureSchema(conn);
        _schemaReady = true;
      }
      await conn.execute(
        Sql.named(
            'DELETE FROM "organization_members" WHERE "organization_id" = @id'),
        parameters: {'id': orgId},
      );
      // Clear org membership fields on affected user rows
      await conn.execute(
        Sql.named(
            'UPDATE "users" SET "organization_id" = NULL, "org_role" = NULL WHERE "organization_id" = @id'),
        parameters: {'id': orgId},
      );
      await conn.execute(
        Sql.named('DELETE FROM "organizations" WHERE "id" = @id'),
        parameters: {'id': orgId},
      );
      debugPrint(
          'RemoteSyncService: org $orgId permanently deleted from cloud');
    } catch (e) {
      debugPrint('RemoteSyncService.deleteOrganizationDataFromCloud: $e');
    } finally {
      await conn.close();
    }
  }

  /// Result of a cloud invite-code lookup.
  /// [org] is the raw row map when the org was found.
  /// [error] is 'no_internet' | 'server_error' | null (null = found or not found).
  static const _kOrgLookupNoInternet = 'no_internet';
  static const _kOrgLookupServerError = 'server_error';

  /// Looks up an organization in the remote database by its invite code.
  ///
  /// Returns `(org: map, error: null)` when found, `(org: null, error: null)` when
  /// not found, or `(org: null, error: 'no_internet' | 'server_error')` on failure.
  static Future<({Map<String, dynamic>? org, String? error})>
      findOrganizationByInviteCodeInCloud(String code) async {
    if (kIsWeb) return (org: null, error: null);
    final connectivity = await Connectivity().checkConnectivity();
    if (connectivity.contains(ConnectivityResult.none)) {
      return (org: null, error: _kOrgLookupNoInternet);
    }
    final conn = await _connect();
    if (conn == null) return (org: null, error: _kOrgLookupServerError);
    try {
      if (!_schemaReady) {
        await _ensureSchema(conn);
        _schemaReady = true;
      }
      final res = await conn.execute(
        Sql.named(
            'SELECT * FROM "organizations" WHERE "invite_code" = @code LIMIT 1'),
        parameters: {'code': code.trim().toUpperCase()},
      );
      if (res.isEmpty) return (org: null, error: null);
      return (org: Map<String, dynamic>.from(res.first.toColumnMap()), error: null);
    } catch (e) {
      debugPrint('[RemoteSync] findOrganizationByInviteCodeInCloud: $e');
      return (org: null, error: _kOrgLookupServerError);
    } finally {
      await conn.close();
    }
  }

  /// Writes the new org member row and the updated user row to the remote
  /// database. Must be awaited before [pullOrganizationDataById] so the cloud
  /// already reflects the new member when the pull runs.
  ///
  /// Returns true on success, false if offline or on any error.
  static Future<bool> addMemberToOrgInCloud({
    required Map<String, dynamic> memberRow,
    required Map<String, dynamic> userRow,
  }) async {
    if (kIsWeb) return false;
    final connectivity = await Connectivity().checkConnectivity();
    if (connectivity.contains(ConnectivityResult.none)) return false;
    final conn = await _connect();
    if (conn == null) return false;
    try {
      if (!_schemaReady) {
        await _ensureSchema(conn);
        _schemaReady = true;
      }
      await upsertUser(conn, userRow);
      await upsertOrgMember(conn, memberRow);
      return true;
    } catch (e) {
      debugPrint('[RemoteSync] addMemberToOrgInCloud: $e');
      return false;
    } finally {
      await conn.close();
    }
  }

  /// Pulls the organization row and all its member rows from the remote
  /// database into the local SQLite store. Contacts are intentionally excluded
  /// — call [pullOrgContactsById] as a fire-and-forget operation for those.
  /// All errors are swallowed.
  static Future<void> pullOrganizationDataById(String orgId) async {
    if (kIsWeb) return;
    final conn = await _connect();
    if (conn == null) return;
    try {
      if (!_schemaReady) {
        await _ensureSchema(conn);
        _schemaReady = true;
      }

      // Pull org row.
      final orgRes = await conn.execute(
        Sql.named('SELECT * FROM "organizations" WHERE "id" = @id'),
        parameters: {'id': orgId},
      );
      for (final row in orgRes) {
        await DatabaseService.upsertRawRow('organizations', row.toColumnMap());
      }

      // Pull all member rows; collect user IDs for reconciliation.
      final memRes = await conn.execute(
        Sql.named(
            'SELECT * FROM "organization_members" WHERE "organization_id" = @id'),
        parameters: {'id': orgId},
      );
      final memberUserIds = <String>[];
      for (final row in memRes) {
        await DatabaseService.upsertRawRow('organization_members',
            _normaliseBools(row.toColumnMap(), _memberBoolCols));
        final uid = row.toColumnMap()['user_id'];
        if (uid is String && uid.isNotEmpty) memberUserIds.add(uid);
      }

      // Reconcile: remove local members that no longer exist in the cloud.
      await DatabaseService.reconcileOrgMembers(orgId, memberUserIds);
    } catch (e) {
      debugPrint('[RemoteSync] pullOrganizationDataById: $e');
    } finally {
      await conn.close();
    }
  }

  /// Pulls contacts owned by any member of [orgId] from the remote database
  /// into the local SQLite store. Intended to be called as a fire-and-forget
  /// operation so it never blocks the Organization Admin screen. Reads member
  /// user IDs from the local SQLite store (already up-to-date after
  /// [pullOrganizationDataById] has run). All errors are swallowed.
  static Future<void> pullOrgContactsById(String orgId) async {
    if (kIsWeb) return;
    final memberRows = await DatabaseService.getRawOrgMemberRows(orgId);
    final memberUserIds = memberRows
        .map((m) => m['user_id'] as String?)
        .where((id) => id != null && id.isNotEmpty)
        .cast<String>()
        .toList();
    if (memberUserIds.isEmpty) return;

    final conn = await _connect();
    if (conn == null) return;
    try {
      if (!_schemaReady) {
        await _ensureSchema(conn);
        _schemaReady = true;
      }
      final inP = _buildInParams(memberUserIds);
      final contactRes = await conn.execute(
        Sql.named(
            'SELECT * FROM "contacts" WHERE "owner_id" IN (${inP.placeholders})'),
        parameters: inP.params,
      );
      for (final row in contactRes) {
        await DatabaseService.upsertRawRow('contacts', row.toColumnMap());
      }
    } catch (e) {
      debugPrint('[RemoteSync] pullOrgContactsById: $e');
    } finally {
      await conn.close();
    }
  }

  static Future<void> upsertOrgMember(
      Connection conn, Map<String, dynamic> r) async {
    // can_* columns are included in INSERT for backward compat with pre-v29 rows,
    // but are intentionally excluded from ON CONFLICT DO UPDATE — org_member_permissions
    // is the authority for privileges and is upserted separately.
    await conn.execute(
      Sql.named('''
        INSERT INTO "organization_members"
          (id,organization_id,user_id,role,status,joined_at,
           first_name,last_name,email,phone,nickname,company,biography,photo_path,
           can_edit,can_create,can_view_reminders,can_view_history,can_export_contacts,can_view_others_tasks)
        VALUES
          (@id,@organization_id,@user_id,@role,@status,@joined_at,
           @first_name,@last_name,@email,@phone,@nickname,@company,@biography,@photo_path,
           @can_edit,@can_create,@can_view_reminders,@can_view_history,@can_export_contacts,@can_view_others_tasks)
        ON CONFLICT (id) DO UPDATE SET
          role=EXCLUDED.role,status=EXCLUDED.status,
          first_name=EXCLUDED.first_name,last_name=EXCLUDED.last_name,
          email=EXCLUDED.email,phone=EXCLUDED.phone,nickname=EXCLUDED.nickname,company=EXCLUDED.company,
          biography=EXCLUDED.biography,photo_path=EXCLUDED.photo_path
      '''),
      parameters: {
        'id': r['id'],
        'organization_id': r['organization_id'],
        'user_id': r['user_id'],
        'role': r['role'] ?? 'member',
        'status': r['status'] ?? 'active',
        'joined_at': r['joined_at'],
        'first_name': r['first_name'] ?? '',
        'last_name': r['last_name'] ?? '',
        'email': r['email'],
        'phone': r['phone'],
        'nickname': r['nickname'],
        'company': r['company'],
        'biography': r['biography'],
        'photo_path': r['photo_path'],
        'can_edit': r['can_edit'] ?? 0,
        'can_create': r['can_create'] ?? 1,
        'can_view_reminders': r['can_view_reminders'] ?? 0,
        'can_view_history': r['can_view_history'] ?? 0,
        'can_export_contacts': r['can_export_contacts'] ?? 0,
        'can_view_others_tasks': r['can_view_others_tasks'] ?? 0,
      },
    );
  }

  /// Upserts a single row into org_member_permissions.
  /// Called by admin/owner push path. Uses a transaction with SET LOCAL to
  /// set the current_user_id GUC so the RLS SELECT policy resolves correctly
  /// for subsequent reads on the same connection.
  static Future<void> upsertOrgMemberPermission(
      Connection conn, Map<String, dynamic> r) async {
    await conn.execute(
      Sql.named('''
        INSERT INTO "org_member_permissions"
          (id,organization_id,user_id,
           can_edit,can_create,can_view_reminders,
           can_view_history,can_export_contacts,can_view_others_tasks,
           updated_at)
        VALUES
          (@id,@organization_id,@user_id,
           @can_edit,@can_create,@can_view_reminders,
           @can_view_history,@can_export_contacts,@can_view_others_tasks,
           @updated_at)
        ON CONFLICT (id) DO UPDATE SET
          can_edit=EXCLUDED.can_edit,
          can_create=EXCLUDED.can_create,
          can_view_reminders=EXCLUDED.can_view_reminders,
          can_view_history=EXCLUDED.can_view_history,
          can_export_contacts=EXCLUDED.can_export_contacts,
          can_view_others_tasks=EXCLUDED.can_view_others_tasks,
          updated_at=EXCLUDED.updated_at
      '''),
      parameters: {
        'id': r['id'],
        'organization_id': r['organization_id'],
        'user_id': r['user_id'],
        'can_edit': r['can_edit'] ?? 0,
        'can_create': r['can_create'] ?? 1,
        'can_view_reminders': r['can_view_reminders'] ?? 0,
        'can_view_history': r['can_view_history'] ?? 0,
        'can_export_contacts': r['can_export_contacts'] ?? 0,
        'can_view_others_tasks': r['can_view_others_tasks'] ?? 0,
        'updated_at': r['updated_at'] ?? DateTime.now().toIso8601String(),
      },
    );
  }

  static Future<void> deleteOrgMember(Connection conn, String id) async {
    await conn.execute(
      Sql.named('DELETE FROM "organization_members" WHERE id = @id'),
      parameters: {'id': id},
    );
  }

  static Future<void> deleteOrganizationRecord(
      Connection conn, String orgId) async {
    await conn.execute(
      Sql.named('DELETE FROM "organizations" WHERE id = @id'),
      parameters: {'id': orgId},
    );
  }

  static Future<void> _upsertPaymentRecord(
      Connection conn, Map<String, dynamic> r) async {
    await conn.execute(
      Sql.named('''
        INSERT INTO "payment_history"
          (id,transaction_id,user_id,plan,billing_cycle,amount,currency,status,
           stripe_payment_intent_id,payment_method,account_type,created_at)
        VALUES
          (@id,@transaction_id,@user_id,@plan,@billing_cycle,@amount,@currency,@status,
           @stripe_payment_intent_id,@payment_method,@account_type,@created_at)
        ON CONFLICT (id) DO UPDATE SET
          status=EXCLUDED.status,
          payment_method=EXCLUDED.payment_method
      '''),
      parameters: {
        'id': r['id'],
        'transaction_id': r['transaction_id'] ?? '',
        'user_id': r['user_id'],
        'plan': r['plan'],
        'billing_cycle': r['billing_cycle'],
        'amount': r['amount'],
        'currency': r['currency'] ?? 'EUR',
        'status': r['status'] ?? 'succeeded',
        'stripe_payment_intent_id': r['stripe_payment_intent_id'],
        'payment_method': r['payment_method'] ?? 'card',
        'account_type': r['account_type'] ?? 'individual',
        'created_at': r['created_at'],
      },
    );
  }

  // ── Pull helpers ────────────────────────────────────────────────────────────

  /// Builds a named-parameter IN clause for a list of [ids].
  ///
  /// Returns the placeholder string (`@oid0,@oid1,...`) and the matching
  /// params map so they can be passed directly to [Connection.execute].
  static ({String placeholders, Map<String, dynamic> params}) _buildInParams(
      List<String> ids) {
    final params = <String, dynamic>{};
    final names = <String>[];
    for (var i = 0; i < ids.length; i++) {
      final key = 'oid$i';
      params[key] = ids[i];
      names.add('@$key');
    }
    return (placeholders: names.join(','), params: params);
  }

  static Future<String?> _remoteOrgIdForUser(
      Connection conn, String userId) async {
    final result = await conn.execute(
      Sql.named('SELECT "organization_id" FROM "users" WHERE "id" = @id'),
      parameters: {'id': userId},
    );
    if (result.isEmpty) return null;
    final val = result.first.toColumnMap()['organization_id'];
    if (val == null || val.toString().isEmpty) return null;
    return val.toString();
  }

  /// Returns true when [userId] belongs to an organisation whose Business-plan
  /// licence is still active and not yet expired — regardless of the user's
  /// individual plan or their membership status within the org (suspended
  /// members remain covered by the org licence).
  /// Free-plan users covered by a valid org licence receive full data-table
  /// sync privileges equivalent to the 'business' plan.
  /// All errors are swallowed and return false so they never block a sync.
  static Future<bool> _isOrgLicenseCoveredInCloud(
      Connection conn, String userId) async {
    try {
      final orgId = await _remoteOrgIdForUser(conn, userId);
      if (orgId == null) return false;

      // Confirm the user has a membership row in this org (any status —
      // suspended members remain covered by the org licence).
      final memResult = await conn.execute(
        Sql.named(
          'SELECT "id" FROM "organization_members" '
          'WHERE "organization_id" = @orgId AND "user_id" = @userId',
        ),
        parameters: {'orgId': orgId, 'userId': userId},
      );
      if (memResult.isEmpty) return false;

      final orgResult = await conn.execute(
        Sql.named(
          'SELECT "org_status", "org_plan_expires_at" '
          'FROM "organizations" WHERE "id" = @id',
        ),
        parameters: {'id': orgId},
      );
      if (orgResult.isEmpty) return false;
      final orgRow = orgResult.first.toColumnMap();

      if (orgRow['org_status']?.toString() != 'active') return false;

      final expiresStr = orgRow['org_plan_expires_at']?.toString();
      if (expiresStr == null || expiresStr.isEmpty) return false;
      final expiresAt = DateTime.tryParse(expiresStr);
      if (expiresAt == null) return false;

      return DateTime.now().isBefore(expiresAt);
    } catch (e) {
      debugPrint('RemoteSyncService._isOrgLicenseCoveredInCloud: $e');
      return false;
    }
  }

  // SMALLINT columns come back as int from postgres; ensure they are
  // stored as int in SQLite as well (guard against bool true/false).
  static const _userBoolCols = {'email_verified'};
  static const _reminderBoolCols = {'is_completed'};
  static const _memberBoolCols = {
    'can_edit',
    'can_create',
    'can_view_reminders',
    'can_view_history',
    'can_export_contacts',
    'can_view_others_tasks',
  };

  static const _permBoolCols = {
    'can_edit',
    'can_create',
    'can_view_reminders',
    'can_view_history',
    'can_export_contacts',
    'can_view_others_tasks',
  };

  static Map<String, dynamic> _normaliseBools(
      Map<String, dynamic> row, Set<String> boolCols) {
    return {
      for (final e in row.entries)
        e.key: boolCols.contains(e.key)
            ? ((e.value == true || e.value == 1 || e.value == '1') ? 1 : 0)
            : e.value,
    };
  }

  // ── Photo sync helpers ──────────────────────────────────────────────────────

  /// Migrates old absolute photo paths to relative paths in the local DB,
  /// then uploads every photo that has a relative path to FTP.
  ///
  /// Also handles active org members: uploads their denormalized profile photo
  /// (stored on the `organization_members` row) and any of their contact photos
  /// that are present on this device.
  ///
  /// Must be called before the PostgreSQL upsert step in [push] so the remote DB
  /// always receives platform-neutral relative paths.
  static Future<void> _migrateAndUploadPhotos(String userId) async {
    try {
      // User profile photo
      final userRow = await DatabaseService.getRawUserRow(userId);
      if (userRow != null) {
        final oldPath = userRow['photo_path'] as String?;
        final newPath =
            await _migratePhotoPath(oldPath, 'profile_pictures', userId);
        if (newPath != oldPath) {
          await DatabaseService.updateUserPhotoPath(userId, newPath);
        }
        if (newPath != null && !_isAbsolutePath(newPath)) {
          await FtpPhotoService.uploadPhoto(newPath);
        }
      }

      // Current user's contact photos
      final contacts = await DatabaseService.getRawContactRows(userId);
      for (final row in contacts) {
        final contactId = row['id'] as String;
        final oldPath = row['photo_path'] as String?;
        final newPath =
            await _migratePhotoPath(oldPath, 'contact_pictures', userId);
        if (newPath != oldPath) {
          await DatabaseService.updateContactPhotoPath(contactId, newPath);
        }
        if (newPath != null && !_isAbsolutePath(newPath)) {
          await FtpPhotoService.uploadPhoto(newPath);
        }
      }

      // Org member profile photos + their contact photos.
      // Only relevant for premium/business users already in an organization.
      final orgId = userRow?['organization_id'] as String?;
      if (orgId != null && orgId.isNotEmpty) {
        final orgRow = await DatabaseService.getRawOrganizationRow(orgId);
        final orgExpired = orgRow != null && _isOrgLicenseExpired(orgRow);

        final members = await DatabaseService.getRawOrgMemberRows(orgId);
        for (final member in members) {
          // When the org license has expired, include only members whose own
          // personal subscription still qualifies for data sync.
          if (orgExpired) {
            final memberId = member['user_id'] as String?;
            final memberUserRow = memberId != null
                ? await DatabaseService.getRawUserRow(memberId)
                : null;
            if (!_memberHasEligiblePlan(memberUserRow)) continue;
          }
          // Suspended members are included — only org-license expiry gates
          // photo sync; the member's org status does not.

          // Denormalized member profile photo stored on the membership row.
          final memberPhotoPath = member['photo_path'] as String?;
          if (memberPhotoPath != null &&
              memberPhotoPath.isNotEmpty &&
              !_isAbsolutePath(memberPhotoPath)) {
            await FtpPhotoService.uploadPhoto(memberPhotoPath);
          }

          // Contacts owned by this org member that are cached locally.
          final memberId = member['user_id'] as String?;
          if (memberId == null || memberId == userId) continue;
          final memberContacts =
              await DatabaseService.getRawContactRows(memberId);
          for (final contactRow in memberContacts) {
            final contactId = contactRow['id'] as String;
            final oldPath = contactRow['photo_path'] as String?;
            final newPath = await _migratePhotoPath(
                oldPath, 'contact_pictures', memberId);
            if (newPath != oldPath) {
              await DatabaseService.updateContactPhotoPath(contactId, newPath);
            }
            if (newPath != null && !_isAbsolutePath(newPath)) {
              await FtpPhotoService.uploadPhoto(newPath);
            }
          }
        }
      }
    } catch (e) {
      debugPrint('RemoteSyncService photo migration error: $e');
    }
  }

  /// Downloads photos from FTP for all records that have a relative photo_path
  /// but no local file.  Called at the end of [pull] after DB records are saved.
  ///
  /// Also fetches the profile photo for every active org member (stored on the
  /// `organization_members` row) so member avatars are available offline.
  static Future<void> _downloadMissingPhotos(
      String userId, List<String> ownerIds) async {
    try {
      // User profile photo
      final userRow = await DatabaseService.getRawUserRow(userId);
      if (userRow != null) {
        await _downloadPhotoIfMissing(userRow['photo_path'] as String?);
      }

      // Contact photos for every relevant owner
      for (final ownerId in ownerIds) {
        final contacts = await DatabaseService.getRawContactRows(ownerId);
        for (final row in contacts) {
          await _downloadPhotoIfMissing(row['photo_path'] as String?);
        }
      }

      // Org member profile photos.
      // The org_members rows are pulled before this method is called, so the
      // local table already reflects the latest server state.
      final orgId = userRow?['organization_id'] as String?;
      if (orgId != null && orgId.isNotEmpty) {
        final orgRow = await DatabaseService.getRawOrganizationRow(orgId);
        final orgExpired = orgRow != null && _isOrgLicenseExpired(orgRow);

        final members = await DatabaseService.getRawOrgMemberRows(orgId);
        for (final member in members) {
          // When the org license has expired, include only members whose own
          // personal subscription still qualifies for data sync.
          if (orgExpired) {
            final memberId = member['user_id'] as String?;
            final memberUserRow = memberId != null
                ? await DatabaseService.getRawUserRow(memberId)
                : null;
            if (!_memberHasEligiblePlan(memberUserRow)) continue;
          }
          // Suspended members are included — org-license expiry is the gate.
          await _downloadPhotoIfMissing(member['photo_path'] as String?);
        }
      }
    } catch (e) {
      debugPrint('RemoteSyncService photo download error: $e');
    }
  }

  /// Converts an old absolute [path] to a platform-neutral relative path.
  ///
  /// - `null` or empty  → `null` (no photo)
  /// - Already relative → returned unchanged
  /// - Absolute, file exists → new relative path (file copied to new location)
  /// - Absolute, file gone   → `null` (clears the stale reference)
  static Future<String?> _migratePhotoPath(
      String? path, String subDir, String userId) async {
    if (path == null || path.isEmpty) return null;
    if (!_isAbsolutePath(path)) return path; // already relative

    final file = File(path);
    if (!await file.exists()) return null;

    final filename = p.basename(path);
    final relativePath = '$subDir/$userId/$filename';

    final newFile = PhotoStorageService.localFileForRelativePath(relativePath);
    if (newFile != null && !await newFile.exists()) {
      await newFile.parent.create(recursive: true);
      await file.copy(newFile.path);
    }
    return relativePath;
  }

  /// Downloads a photo from FTP when its local file does not yet exist.
  /// Silently skips absolute paths (old records never uploaded to FTP).
  static Future<void> _downloadPhotoIfMissing(String? path) async {
    if (path == null || path.isEmpty || _isAbsolutePath(path)) return;
    final localFile = PhotoStorageService.localFileForRelativePath(path);
    if (localFile == null || await localFile.exists()) return;
    await FtpPhotoService.downloadPhoto(path);
  }

  /// Returns true when the organization's license has expired.
  ///
  /// A license is considered expired when `org_status` is not `'active'` OR
  /// when `org_plan_expires_at` is set and is in the past.
  static bool _isOrgLicenseExpired(Map<String, dynamic> orgRow) {
    final status = (orgRow['org_status'] as String?) ?? 'active';
    if (status != 'active') return true;
    final expiresStr = orgRow['org_plan_expires_at'] as String?;
    if (expiresStr == null || expiresStr.isEmpty) return false;
    final expires = DateTime.tryParse(expiresStr);
    if (expires == null) return false;
    return DateTime.now().isAfter(expires);
  }

  /// Returns true when [memberRow] represents a user whose personal
  /// subscription plan qualifies for automatic data synchronization
  /// (premium or business, and not yet expired).
  ///
  /// Returns false when the row is null (member not found locally) or when
  /// the plan is free / expired — used as the fallback gate when the org
  /// license has lapsed.
  static bool _memberHasEligiblePlan(Map<String, dynamic>? memberRow) {
    if (memberRow == null) return false;
    final plan = (memberRow['plan'] as String?) ?? 'free';
    if (plan != 'premium' && plan != 'business') return false;
    final expiresStr = memberRow['plan_expires_at'] as String?;
    if (expiresStr == null || expiresStr.isEmpty) return true;
    final expires = DateTime.tryParse(expiresStr);
    if (expires == null) return true;
    return DateTime.now().isBefore(expires);
  }

  /// Returns true for old-style absolute paths (start with `/` on Unix-like
  /// platforms, or contain a Windows drive letter followed by `:`).
  static bool _isAbsolutePath(String path) =>
      path.startsWith('/') || path.contains(':\\');
}

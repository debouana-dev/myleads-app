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

  // ── Plan gate ────────────────────────────────────────────────────────────────

  /// Returns true when the current user's plan allows full data-table sync
  /// (premium or business). The `users` table is always synced regardless.
  static bool get _hasSyncPlan {
    final plan = StorageService.userPlan;
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
  static void _syncUserRow(String userId) {
    _fireAndForget((conn) async {
      final row = await DatabaseService.getRawUserRow(userId);
      if (row != null) await _upsertUser(conn, row);
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
        "plan"                VARCHAR(20)  NOT NULL DEFAULT 'free',
        "last_sync_at"        VARCHAR(50),
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
        "role"               VARCHAR(20) NOT NULL DEFAULT 'member',
        "status"             VARCHAR(20) NOT NULL DEFAULT 'active',
        "joined_at"          VARCHAR(50) NOT NULL,
        "can_edit"           SMALLINT    NOT NULL DEFAULT 0,
        "can_create"         SMALLINT    NOT NULL DEFAULT 1,
        "can_view_reminders" SMALLINT    NOT NULL DEFAULT 0,
        "can_view_history"   SMALLINT    NOT NULL DEFAULT 0,
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
      await _upsertUser(conn, userRow);
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
  /// premium or business plan.
  static Future<void> _pushRowBackground(
          String table, Map<String, dynamic> row) =>
      _fireAndForget((conn) async {
        if (table == 'users') {
          await _upsertUser(conn, row);
          return;
        }
        if (!_hasSyncPlan) return;
        switch (table) {
          case 'contacts':
            await _upsertContact(conn, row);
          case 'reminders':
            await _upsertReminder(conn, row);
          case 'interactions':
            await _upsertInteraction(conn, row);
          case 'organizations':
            await _upsertOrganization(conn, row);
          case 'organization_members':
            await _upsertOrgMember(conn, row);
        }
      });

  /// Dispatches a background delete for any supported table.
  /// Handles cascaded deletes for contacts (interactions + reminders)
  /// and organisations (all member rows).
  /// Data-table deletes require a premium or business plan.
  static Future<void> _deleteRowBackground(String table, String id) =>
      _fireAndForget((conn) async {
        if (!_hasSyncPlan) return;
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
        }
        await conn.execute(
          Sql.named('DELETE FROM "$table" WHERE "id" = @id'),
          parameters: {'id': id},
        );
      });

  /// Opens a connection, runs [action], then closes.
  /// Errors are swallowed so local writes are never blocked by network issues.
  static Future<void> _fireAndForget(
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

    // Photo migration and data-table push are restricted to premium/business.
    if (_hasSyncPlan) {
      // Migrate old absolute photo paths → relative, then upload to FTP.
      // Must run before the PostgreSQL upserts so the remote DB receives
      // platform-neutral relative paths.
      await _migrateAndUploadPhotos(userId);
    }

    final conn = await _connect();
    if (conn == null) return SyncResult.err('auth_failed');

    try {
      await _ensureSchema(conn);
      _schemaReady = true;

      // User row — always synced for all plans.
      final userRow = await DatabaseService.getRawUserRow(userId);
      if (userRow != null) await _upsertUser(conn, userRow);

      var contactCount = 0;
      var reminderCount = 0;
      var interactionCount = 0;

      if (_hasSyncPlan) {
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
          if (orgRow != null) await _upsertOrganization(conn, orgRow);

          final members = await DatabaseService.getRawOrgMemberRows(orgId);
          for (final row in members) {
            await _upsertOrgMember(conn, row);
          }
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
      for (final row in userResult) {
        final cloudRow = _normaliseBools(row.toColumnMap(), _userBoolCols);
        // Preserve the device-local session_token and password_hash.
        // The cloud row was written by a different device and carries that
        // device's token; overwriting the local token would invalidate the
        // current session on the next app restart (StorageService.init
        // compares the secure-storage token with the DB value).
        final localRow = await DatabaseService.getRawUserRow(userId);
        if (localRow != null) {
          cloudRow['session_token'] = localRow['session_token'];
          cloudRow['password_hash'] = localRow['password_hash'];
        }
        await DatabaseService.upsertRawRow('users', cloudRow);
      }

      // Data-table pull is restricted to premium / business plans.
      if (!_hasSyncPlan) {
        final now = DateTime.now().toIso8601String();
        await DatabaseService.updateUserLastSync(userId, now);
        return const SyncResult(success: true);
      }

      // ── Org membership & permissions ────────────────────────────────────
      final orgId = await _remoteOrgIdForUser(conn, userId);
      var pullOwnerIds = <String>[userId];
      var canPullOrgReminders = false;

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
        for (final row in memRes) {
          await DatabaseService.upsertRawRow('organization_members',
              _normaliseBools(row.toColumnMap(), _memberBoolCols));
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

  static Future<void> _upsertUser(
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
         organization_id,org_role,plan,last_sync_at)
      VALUES
        (@id,@email_enc,@email_lookup,@first_name_enc,@last_name_enc,@nickname_enc,
         @phone_enc,@phone_lookup,@date_of_birth_enc,@company_name_enc,@company_role_enc,
         @biography_enc,@password_hash,@auth_provider,@session_token,@created_at,
         @last_login_at,@password_changed_at,@photo_path,@email_verified,
         @organization_id,@org_role,@plan,@last_sync_at)
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
        last_sync_at=EXCLUDED.last_sync_at
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

  static Future<void> _upsertOrganization(
      Connection conn, Map<String, dynamic> r) async {
    await conn.execute(
      Sql.named('''
        INSERT INTO "organizations" (id,name,owner_id,invite_code,created_at)
        VALUES (@id,@name,@owner_id,@invite_code,@created_at)
        ON CONFLICT (id) DO UPDATE SET
          name=EXCLUDED.name,invite_code=EXCLUDED.invite_code
      '''),
      parameters: {
        'id': r['id'],
        'name': r['name'],
        'owner_id': r['owner_id'],
        'invite_code': r['invite_code'],
        'created_at': r['created_at'],
      },
    );
  }

  static Future<void> _upsertOrgMember(
      Connection conn, Map<String, dynamic> r) async {
    await conn.execute(
      Sql.named('''
        INSERT INTO "organization_members"
          (id,organization_id,user_id,role,status,joined_at,
           can_edit,can_create,can_view_reminders,can_view_history)
        VALUES
          (@id,@organization_id,@user_id,@role,@status,@joined_at,
           @can_edit,@can_create,@can_view_reminders,@can_view_history)
        ON CONFLICT (id) DO UPDATE SET
          role=EXCLUDED.role,status=EXCLUDED.status,
          can_edit=EXCLUDED.can_edit,can_create=EXCLUDED.can_create,
          can_view_reminders=EXCLUDED.can_view_reminders,
          can_view_history=EXCLUDED.can_view_history
      '''),
      parameters: {
        'id': r['id'],
        'organization_id': r['organization_id'],
        'user_id': r['user_id'],
        'role': r['role'] ?? 'member',
        'status': r['status'] ?? 'active',
        'joined_at': r['joined_at'],
        'can_edit': r['can_edit'] ?? 0,
        'can_create': r['can_create'] ?? 1,
        'can_view_reminders': r['can_view_reminders'] ?? 0,
        'can_view_history': r['can_view_history'] ?? 0,
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

  // SMALLINT columns come back as int from postgres; ensure they are
  // stored as int in SQLite as well (guard against bool true/false).
  static const _userBoolCols = {'email_verified'};
  static const _reminderBoolCols = {'is_completed'};
  static const _memberBoolCols = {
    'can_edit',
    'can_create',
    'can_view_reminders',
    'can_view_history'
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

      // Contact photos
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
    } catch (e) {
      debugPrint('RemoteSyncService photo migration error: $e');
    }
  }

  /// Downloads photos from FTP for all records that have a relative photo_path
  /// but no local file.  Called at the end of [pull] after DB records are saved.
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

  /// Returns true for old-style absolute paths (start with `/` on Unix-like
  /// platforms, or contain a Windows drive letter followed by `:`).
  static bool _isAbsolutePath(String path) =>
      path.startsWith('/') || path.contains(':\\');
}

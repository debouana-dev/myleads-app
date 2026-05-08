import 'dart:async';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:mysql_client/mysql_client.dart';
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

/// Synchronises the local SQLite database with the remote MySQL server.
///
/// Push copies every local row for the active user to MySQL using
/// INSERT … ON DUPLICATE KEY UPDATE (upsert).
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

  static Future<MySQLConnection?> _connect() async {
    if (kIsWeb) return null;
    try {
      final conn = await MySQLConnection.createConnection(
        host: AppConfig.mysqlHost,
        port: AppConfig.mysqlPort,
        userName: AppConfig.mysqlUsername,
        password: AppConfig.mysqlPassword,
        databaseName: AppConfig.mysqlDatabase,
        secure: true,
      );
      await conn.connect();
      return conn;
    } catch (e) {
      debugPrint('RemoteSyncService connect error: $e');
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

  static Future<void> _ensureSchema(MySQLConnection conn) async {
    await conn.execute('''
      CREATE TABLE IF NOT EXISTS `users` (
        `id`                  VARCHAR(36)  NOT NULL,
        `email_enc`           TEXT         NOT NULL,
        `email_lookup`        CHAR(64)     NOT NULL,
        `first_name_enc`      TEXT         NOT NULL,
        `last_name_enc`       TEXT         NOT NULL,
        `nickname_enc`        TEXT,
        `phone_enc`           TEXT,
        `phone_lookup`        CHAR(64),
        `date_of_birth_enc`   TEXT,
        `company_name_enc`    TEXT,
        `company_role_enc`    TEXT,
        `biography_enc`       TEXT,
        `password_hash`       VARCHAR(255) NOT NULL,
        `auth_provider`       VARCHAR(50)  NOT NULL DEFAULT 'email',
        `session_token`       VARCHAR(255),
        `created_at`          VARCHAR(50)  NOT NULL,
        `last_login_at`       VARCHAR(50),
        `password_changed_at` VARCHAR(50)  NOT NULL,
        `photo_path`          TEXT,
        `email_verified`      TINYINT(1)   NOT NULL DEFAULT 0,
        `organization_id`     VARCHAR(36),
        `org_role`            VARCHAR(20),
        `plan`                VARCHAR(20)  NOT NULL DEFAULT 'free',
        `last_sync_at`        VARCHAR(50),
        PRIMARY KEY (`id`),
        UNIQUE KEY `uq_users_email_lookup` (`email_lookup`)
      ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
    ''');

    await conn.execute('''
      CREATE TABLE IF NOT EXISTS `contacts` (
        `id`                VARCHAR(36)  NOT NULL,
        `owner_id`          VARCHAR(36)  NOT NULL,
        `first_name`        VARCHAR(255) NOT NULL,
        `last_name`         VARCHAR(255) NOT NULL,
        `job_title`         VARCHAR(255),
        `company`           VARCHAR(255),
        `phone`             VARCHAR(100),
        `email`             VARCHAR(320),
        `phone_lookup`      CHAR(64),
        `email_lookup`      CHAR(64),
        `source`            VARCHAR(100),
        `project_1`         VARCHAR(255),
        `project_1_budget`  VARCHAR(100),
        `project_2`         VARCHAR(255),
        `project_2_budget`  VARCHAR(100),
        `interest`          TEXT,
        `notes`             TEXT,
        `tags`              TEXT,
        `status`            VARCHAR(20)  NOT NULL DEFAULT 'warm',
        `created_at`        VARCHAR(50)  NOT NULL,
        `last_contact_date` VARCHAR(50),
        `avatar_color`      VARCHAR(20),
        `capture_method`    VARCHAR(20)  NOT NULL DEFAULT 'manual',
        `photo_path`        TEXT,
        PRIMARY KEY (`id`),
        INDEX `idx_contacts_owner` (`owner_id`)
      ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
    ''');

    await conn.execute('''
      CREATE TABLE IF NOT EXISTS `reminders` (
        `id`               VARCHAR(36) NOT NULL,
        `owner_id`         VARCHAR(36) NOT NULL,
        `contact_id`       VARCHAR(36),
        `contact_ids`      TEXT        NOT NULL,
        `start_date_time`  VARCHAR(50) NOT NULL,
        `end_date_time`    VARCHAR(50),
        `repeat_frequency` VARCHAR(20),
        `note`             TEXT        NOT NULL,
        `todo_action`      VARCHAR(20) NOT NULL DEFAULT 'call',
        `priority_v2`      VARCHAR(30) NOT NULL DEFAULT 'normal',
        `title`            VARCHAR(255),
        `description`      TEXT,
        `due_date`         VARCHAR(50),
        `priority`         VARCHAR(20),
        `is_completed`     TINYINT(1)  NOT NULL DEFAULT 0,
        `created_at`       VARCHAR(50) NOT NULL,
        PRIMARY KEY (`id`),
        INDEX `idx_reminders_owner` (`owner_id`)
      ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
    ''');

    await conn.execute('''
      CREATE TABLE IF NOT EXISTS `interactions` (
        `id`         VARCHAR(36) NOT NULL,
        `owner_id`   VARCHAR(36) NOT NULL,
        `contact_id` VARCHAR(36) NOT NULL,
        `type`       VARCHAR(20) NOT NULL,
        `content`    TEXT        NOT NULL,
        `created_at` VARCHAR(50) NOT NULL,
        PRIMARY KEY (`id`),
        INDEX `idx_interactions_contact` (`contact_id`)
      ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
    ''');

    await conn.execute('''
      CREATE TABLE IF NOT EXISTS `organizations` (
        `id`          VARCHAR(36)  NOT NULL,
        `name`        VARCHAR(255) NOT NULL,
        `owner_id`    VARCHAR(36)  NOT NULL,
        `invite_code` CHAR(8)      NOT NULL,
        `created_at`  VARCHAR(50)  NOT NULL,
        PRIMARY KEY (`id`),
        UNIQUE KEY `uq_org_invite_code` (`invite_code`)
      ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
    ''');

    await conn.execute('''
      CREATE TABLE IF NOT EXISTS `organization_members` (
        `id`                 VARCHAR(36) NOT NULL,
        `organization_id`    VARCHAR(36) NOT NULL,
        `user_id`            VARCHAR(36) NOT NULL,
        `role`               VARCHAR(20) NOT NULL DEFAULT 'member',
        `status`             VARCHAR(20) NOT NULL DEFAULT 'active',
        `joined_at`          VARCHAR(50) NOT NULL,
        `can_edit`           TINYINT(1)  NOT NULL DEFAULT 0,
        `can_create`         TINYINT(1)  NOT NULL DEFAULT 1,
        `can_view_reminders` TINYINT(1)  NOT NULL DEFAULT 0,
        `can_view_history`   TINYINT(1)  NOT NULL DEFAULT 0,
        PRIMARY KEY (`id`),
        UNIQUE KEY `uq_org_members` (`organization_id`, `user_id`),
        INDEX `idx_org_members_org`  (`organization_id`),
        INDEX `idx_org_members_user` (`user_id`)
      ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
    ''');

    // Upgrade existing cloud databases that were bootstrapped before v11.
    await conn.execute('''
      ALTER TABLE `users`
        ADD COLUMN IF NOT EXISTS `last_sync_at` VARCHAR(50) DEFAULT NULL
    ''');

    // Upgrade existing cloud databases that were bootstrapped before v12.
    await conn.execute('''
      ALTER TABLE `organization_members`
        ADD COLUMN IF NOT EXISTS `can_view_history` TINYINT(1) NOT NULL DEFAULT 0
    ''');
    await conn.execute('''
      UPDATE `organization_members`
        SET `can_view_history` = 1
        WHERE `role` = 'admin' AND `can_view_history` = 0
    ''');
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
        'SELECT COUNT(*) AS cnt FROM `users` WHERE `email_lookup` = :lookup',
        {'lookup': emailLookup},
      );
      if (result.rows.isEmpty) return false;
      final cnt = int.tryParse(
              result.rows.first.colByName('cnt')?.toString() ?? '0') ??
          0;
      return cnt > 0;
    } catch (e) {
      debugPrint('RemoteSyncService isEmailTakenInCloud error: $e');
      return false;
    } finally {
      await conn.close();
    }
  }

  /// Pushes [userRow] to the remote MySQL database and waits for confirmation.
  ///
  /// Returns `null` on success, or an error message on failure. Unlike the
  /// live-write background callback, this method is awaitable so callers can
  /// gate further actions on a guaranteed cloud registration.
  static Future<String?> registerUserInCloud(Map<String, dynamic> userRow) async {
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

  /// Deletes all records belonging to [userId] from the remote MySQL database.
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
          'DELETE FROM `interactions` WHERE `owner_id` = :id', {'id': userId});
      await conn.execute(
          'DELETE FROM `reminders` WHERE `owner_id` = :id', {'id': userId});
      if (includeContacts) {
        await conn.execute(
            'DELETE FROM `contacts` WHERE `owner_id` = :id', {'id': userId});
      }
      await conn.execute(
          'DELETE FROM `organization_members` WHERE `user_id` = :id',
          {'id': userId});
      await conn.execute(
          'DELETE FROM `users` WHERE `id` = :id', {'id': userId});
      return null;
    } catch (e) {
      debugPrint('RemoteSyncService deleteUserFromCloud error: $e');
      return 'Erreur lors de la suppression sur le serveur';
    } finally {
      await conn.close();
    }
  }

  // ── Cloud user import ────────────────────────────────────────────────────────

  /// Looks up a user in the remote MySQL database by their [emailLookup] hash
  /// and, if found, upserts the row into the local SQLite database so the
  /// normal auth flow can proceed on this device.
  ///
  /// Returns `true` when a record was found and imported, `false` when there
  /// is no network, the server is unreachable, or no matching record exists.
  static Future<bool> importUserByEmailLookup(String emailLookup) async {
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
        'SELECT * FROM `users` WHERE `email_lookup` = :lookup',
        {'lookup': emailLookup},
      );
      if (result.rows.isEmpty) return false;
      final row = _normaliseBools(
        _rowToMap(result.rows.first, result.cols),
        _userBoolCols,
      );
      await DatabaseService.upsertRawRow('users', row);
      return true;
    } catch (e) {
      debugPrint('RemoteSyncService importUserByEmailLookup error: $e');
      return false;
    } finally {
      await conn.close();
    }
  }

  // ── Live-write wiring ───────────────────────────────────────────────────────

  /// Registers callbacks into [DatabaseService] so every local write is
  /// immediately mirrored to the remote MySQL database in the background.
  /// Call once after [StorageService.init] during app startup.
  static void wireDatabase() {
    DatabaseService.wireRemoteSync(
      onUpsert: (table, row) { _pushRowBackground(table, row); },
      onDelete: (table, id)  { _deleteRowBackground(table, id); },
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
          case 'contacts':             await _upsertContact(conn, row);
          case 'reminders':            await _upsertReminder(conn, row);
          case 'interactions':         await _upsertInteraction(conn, row);
          case 'organizations':        await _upsertOrganization(conn, row);
          case 'organization_members': await _upsertOrgMember(conn, row);
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
              'DELETE FROM `interactions` WHERE `contact_id` = :id', {'id': id});
          await conn.execute(
              'DELETE FROM `reminders` WHERE `contact_id` = :id', {'id': id});
        } else if (table == 'organizations') {
          await conn.execute(
              'DELETE FROM `organization_members` WHERE `organization_id` = :id',
              {'id': id});
        }
        await conn.execute(
            'DELETE FROM `$table` WHERE `id` = :id', {'id': id});
      });

  /// Opens a connection, runs [action], then closes.
  /// Errors are swallowed so local writes are never blocked by network issues.
  static Future<void> _fireAndForget(
      Future<void> Function(MySQLConnection) action) async {
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

  /// Uploads all local data for [userId] to the remote MySQL database.
  static Future<SyncResult> push(String userId) async {
    if (kIsWeb) return SyncResult.err('unsupported_platform');

    final connectivity = await Connectivity().checkConnectivity();
    if (connectivity.contains(ConnectivityResult.none)) {
      return SyncResult.err('no_connection');
    }

    // Photo migration and data-table push are restricted to premium/business.
    if (_hasSyncPlan) {
      // Migrate old absolute photo paths → relative, then upload to FTP.
      // Must run before the MySQL upserts so the remote DB receives
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
        final interactions = await DatabaseService.getRawInteractionRows(userId);
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
        'SELECT `id` FROM `users` WHERE `email_lookup` = :lookup LIMIT 1',
        {'lookup': emailLookup},
      );
      if (result.rows.isEmpty) return null;
      return result.rows.first.colByName('id')?.toString();
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
        'UPDATE `users` '
        'SET `password_hash` = :hash, '
            '`session_token` = :token, '
            '`password_changed_at` = :changed_at '
        'WHERE `id` = :id',
        {
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
        'UPDATE `users` SET `email_verified` = 1 WHERE `id` = :id',
        {'id': userId},
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
    if (kIsWeb) return;
    final conn = await _connect();
    if (conn == null) return;
    try {
      await conn.execute(
        'UPDATE `users` '
        'SET `email_enc` = :enc, '
            '`email_lookup` = :lookup, '
            '`session_token` = :token, '
            '`email_verified` = 1 '
        'WHERE `id` = :id',
        {
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
  static Future<SyncResult> pull(String userId) async {
    if (kIsWeb) return SyncResult.err('unsupported_platform');

    final connectivity = await Connectivity().checkConnectivity();
    if (connectivity.contains(ConnectivityResult.none)) {
      return SyncResult.err('no_connection');
    }

    final conn = await _connect();
    if (conn == null) return SyncResult.err('auth_failed');

    try {
      // ── Own user row — always pulled for all plans ───────────────────────
      final userResult = await conn.execute(
        'SELECT * FROM `users` WHERE `id` = :id',
        {'id': userId},
      );
      for (final row in userResult.rows) {
        final cloudRow =
            _normaliseBools(_rowToMap(row, userResult.cols), _userBoolCols);
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
          'SELECT `user_id`, `role`, `can_view_reminders` '
          'FROM `organization_members` '
          'WHERE `organization_id` = :orgId AND `status` = :active',
          {'orgId': orgId, 'active': 'active'},
        );
        for (final row in memResult.rows) {
          final uid = row.colByName('user_id')?.toString();
          if (uid != null && uid.isNotEmpty) pullOwnerIds.add(uid);
          if (uid == userId) {
            final role = row.colByName('role')?.toString();
            final cvr  = row.colByName('can_view_reminders')?.toString();
            canPullOrgReminders = role == 'admin' || cvr == '1';
          }
        }
        pullOwnerIds = pullOwnerIds.toSet().toList();
      }

      // ── Contacts ──────────────────────────────────────────────────────────
      int contactCount = 0;
      if (pullOwnerIds.length == 1) {
        final res = await conn.execute(
          'SELECT * FROM `contacts` WHERE `owner_id` = :uid',
          {'uid': userId},
        );
        for (final row in res.rows) {
          await DatabaseService.upsertRawRow('contacts', _rowToMap(row, res.cols));
          contactCount++;
        }
      } else {
        final inP = _buildInParams(pullOwnerIds);
        final res = await conn.execute(
          'SELECT * FROM `contacts` WHERE `owner_id` IN (${inP.placeholders})',
          inP.params,
        );
        for (final row in res.rows) {
          await DatabaseService.upsertRawRow('contacts', _rowToMap(row, res.cols));
          contactCount++;
        }
      }

      // ── Reminders ─────────────────────────────────────────────────────────
      int reminderCount = 0;
      // Always pull the current user's own reminders.
      final ownRem = await conn.execute(
        'SELECT * FROM `reminders` WHERE `owner_id` = :uid',
        {'uid': userId},
      );
      for (final row in ownRem.rows) {
        await DatabaseService.upsertRawRow(
            'reminders',
            _normaliseBools(_rowToMap(row, ownRem.cols), _reminderBoolCols));
        reminderCount++;
      }
      // Pull other org members' reminders only when permitted.
      if (canPullOrgReminders && pullOwnerIds.length > 1) {
        final others = pullOwnerIds.where((id) => id != userId).toList();
        final inP = _buildInParams(others);
        final orgRem = await conn.execute(
          'SELECT * FROM `reminders` WHERE `owner_id` IN (${inP.placeholders})',
          inP.params,
        );
        for (final row in orgRem.rows) {
          await DatabaseService.upsertRawRow(
              'reminders',
              _normaliseBools(_rowToMap(row, orgRem.cols), _reminderBoolCols));
          reminderCount++;
        }
      }

      // ── Interactions ──────────────────────────────────────────────────────
      int interactionCount = 0;
      if (pullOwnerIds.length == 1) {
        final res = await conn.execute(
          'SELECT * FROM `interactions` WHERE `owner_id` = :uid',
          {'uid': userId},
        );
        for (final row in res.rows) {
          await DatabaseService.upsertRawRow('interactions', _rowToMap(row, res.cols));
          interactionCount++;
        }
      } else {
        final inP = _buildInParams(pullOwnerIds);
        final res = await conn.execute(
          'SELECT * FROM `interactions` WHERE `owner_id` IN (${inP.placeholders})',
          inP.params,
        );
        for (final row in res.rows) {
          await DatabaseService.upsertRawRow('interactions', _rowToMap(row, res.cols));
          interactionCount++;
        }
      }

      // ── Organisation & member rows ─────────────────────────────────────────
      if (orgId != null) {
        final orgRes = await conn.execute(
          'SELECT * FROM `organizations` WHERE `id` = :id',
          {'id': orgId},
        );
        for (final row in orgRes.rows) {
          await DatabaseService.upsertRawRow(
              'organizations', _rowToMap(row, orgRes.cols));
        }

        final memRes = await conn.execute(
          'SELECT * FROM `organization_members` WHERE `organization_id` = :id',
          {'id': orgId},
        );
        for (final row in memRes.rows) {
          await DatabaseService.upsertRawRow(
              'organization_members',
              _normaliseBools(_rowToMap(row, memRes.cols), _memberBoolCols));
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
      MySQLConnection conn, Map<String, dynamic> r) async {
    await conn.execute('''
      INSERT INTO `users`
        (id,email_enc,email_lookup,first_name_enc,last_name_enc,nickname_enc,
         phone_enc,phone_lookup,date_of_birth_enc,company_name_enc,company_role_enc,
         biography_enc,password_hash,auth_provider,session_token,created_at,
         last_login_at,password_changed_at,photo_path,email_verified,
         organization_id,org_role,plan,last_sync_at)
      VALUES
        (:id,:email_enc,:email_lookup,:first_name_enc,:last_name_enc,:nickname_enc,
         :phone_enc,:phone_lookup,:date_of_birth_enc,:company_name_enc,:company_role_enc,
         :biography_enc,:password_hash,:auth_provider,:session_token,:created_at,
         :last_login_at,:password_changed_at,:photo_path,:email_verified,
         :organization_id,:org_role,:plan,:last_sync_at)
      ON DUPLICATE KEY UPDATE
        email_enc=VALUES(email_enc),first_name_enc=VALUES(first_name_enc),
        last_name_enc=VALUES(last_name_enc),nickname_enc=VALUES(nickname_enc),
        phone_enc=VALUES(phone_enc),company_name_enc=VALUES(company_name_enc),
        company_role_enc=VALUES(company_role_enc),biography_enc=VALUES(biography_enc),
        photo_path=VALUES(photo_path),plan=VALUES(plan),
        organization_id=VALUES(organization_id),org_role=VALUES(org_role),
        last_sync_at=VALUES(last_sync_at)
    ''', {
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
    });
  }

  static Future<void> _upsertContact(
      MySQLConnection conn, Map<String, dynamic> r) async {
    await conn.execute('''
      INSERT INTO `contacts`
        (id,owner_id,first_name,last_name,job_title,company,phone,email,
         phone_lookup,email_lookup,source,project_1,project_1_budget,
         project_2,project_2_budget,interest,notes,tags,status,created_at,
         last_contact_date,avatar_color,capture_method,photo_path)
      VALUES
        (:id,:owner_id,:first_name,:last_name,:job_title,:company,:phone,:email,
         :phone_lookup,:email_lookup,:source,:project_1,:project_1_budget,
         :project_2,:project_2_budget,:interest,:notes,:tags,:status,:created_at,
         :last_contact_date,:avatar_color,:capture_method,:photo_path)
      ON DUPLICATE KEY UPDATE
        owner_id=VALUES(owner_id),first_name=VALUES(first_name),
        last_name=VALUES(last_name),job_title=VALUES(job_title),
        company=VALUES(company),phone=VALUES(phone),email=VALUES(email),
        phone_lookup=VALUES(phone_lookup),email_lookup=VALUES(email_lookup),
        source=VALUES(source),project_1=VALUES(project_1),
        project_1_budget=VALUES(project_1_budget),project_2=VALUES(project_2),
        project_2_budget=VALUES(project_2_budget),interest=VALUES(interest),
        notes=VALUES(notes),tags=VALUES(tags),status=VALUES(status),
        last_contact_date=VALUES(last_contact_date),avatar_color=VALUES(avatar_color),
        capture_method=VALUES(capture_method),photo_path=VALUES(photo_path)
    ''', {
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
    });
  }

  static Future<void> _upsertReminder(
      MySQLConnection conn, Map<String, dynamic> r) async {
    await conn.execute('''
      INSERT INTO `reminders`
        (id,owner_id,contact_id,contact_ids,start_date_time,end_date_time,
         repeat_frequency,note,todo_action,priority_v2,title,description,
         due_date,priority,is_completed,created_at)
      VALUES
        (:id,:owner_id,:contact_id,:contact_ids,:start_date_time,:end_date_time,
         :repeat_frequency,:note,:todo_action,:priority_v2,:title,:description,
         :due_date,:priority,:is_completed,:created_at)
      ON DUPLICATE KEY UPDATE
        contact_id=VALUES(contact_id),contact_ids=VALUES(contact_ids),
        start_date_time=VALUES(start_date_time),end_date_time=VALUES(end_date_time),
        repeat_frequency=VALUES(repeat_frequency),note=VALUES(note),
        todo_action=VALUES(todo_action),priority_v2=VALUES(priority_v2),
        is_completed=VALUES(is_completed)
    ''', {
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
    });
  }

  static Future<void> _upsertInteraction(
      MySQLConnection conn, Map<String, dynamic> r) async {
    await conn.execute('''
      INSERT INTO `interactions` (id,owner_id,contact_id,type,content,created_at)
      VALUES (:id,:owner_id,:contact_id,:type,:content,:created_at)
      ON DUPLICATE KEY UPDATE
        type=VALUES(type),content=VALUES(content)
    ''', {
      'id': r['id'],
      'owner_id': r['owner_id'],
      'contact_id': r['contact_id'],
      'type': r['type'],
      'content': r['content'],
      'created_at': r['created_at'],
    });
  }

  static Future<void> _upsertOrganization(
      MySQLConnection conn, Map<String, dynamic> r) async {
    await conn.execute('''
      INSERT INTO `organizations` (id,name,owner_id,invite_code,created_at)
      VALUES (:id,:name,:owner_id,:invite_code,:created_at)
      ON DUPLICATE KEY UPDATE
        name=VALUES(name),invite_code=VALUES(invite_code)
    ''', {
      'id': r['id'],
      'name': r['name'],
      'owner_id': r['owner_id'],
      'invite_code': r['invite_code'],
      'created_at': r['created_at'],
    });
  }

  static Future<void> _upsertOrgMember(
      MySQLConnection conn, Map<String, dynamic> r) async {
    await conn.execute('''
      INSERT INTO `organization_members`
        (id,organization_id,user_id,role,status,joined_at,
         can_edit,can_create,can_view_reminders,can_view_history)
      VALUES
        (:id,:organization_id,:user_id,:role,:status,:joined_at,
         :can_edit,:can_create,:can_view_reminders,:can_view_history)
      ON DUPLICATE KEY UPDATE
        role=VALUES(role),status=VALUES(status),
        can_edit=VALUES(can_edit),can_create=VALUES(can_create),
        can_view_reminders=VALUES(can_view_reminders),
        can_view_history=VALUES(can_view_history)
    ''', {
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
    });
  }

  // ── Pull helpers ────────────────────────────────────────────────────────────

  /// Builds a named-parameter IN clause for a list of [ids].
  ///
  /// Returns the placeholder string (`:oid0,:oid1,...`) and the matching
  /// params map so they can be passed directly to [MySQLConnection.execute].
  static ({String placeholders, Map<String, dynamic> params}) _buildInParams(
      List<String> ids) {
    final params = <String, dynamic>{};
    final names  = <String>[];
    for (var i = 0; i < ids.length; i++) {
      final key = 'oid$i';
      params[key] = ids[i];
      names.add(':$key');
    }
    return (placeholders: names.join(','), params: params);
  }

  static Future<String?> _remoteOrgIdForUser(
      MySQLConnection conn, String userId) async {
    final result = await conn.execute(
      'SELECT `organization_id` FROM `users` WHERE `id` = :id',
      {'id': userId},
    );
    if (result.rows.isEmpty) return null;
    final val = result.rows.first.colByName('organization_id');
    if (val == null || val.toString().isEmpty) return null;
    return val.toString();
  }

  /// Converts a mysql_client result row into a plain Dart map.
  static Map<String, dynamic> _rowToMap(
      ResultSetRow row, Iterable<ResultSetColumn> cols) {
    final map = <String, dynamic>{};
    for (final col in cols) {
      map[col.name] = row.colByName(col.name);
    }
    return map;
  }

  // TINYINT(1) columns come back as int from mysql_client; ensure they are
  // stored as int in SQLite as well (guard against String '0'/'1').
  static const _userBoolCols = {'email_verified'};
  static const _reminderBoolCols = {'is_completed'};
  static const _memberBoolCols = {'can_edit', 'can_create', 'can_view_reminders', 'can_view_history'};

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
  /// Must be called before the MySQL upsert step in [push] so the remote DB
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

-- ============================================================
-- me2leads  —  MySQL schema v12
-- MySQL 8.0+  ·  InnoDB  ·  utf8mb4_unicode_ci
-- Source of truth: lib/services/remote_sync_service.dart (_ensureSchema)
--
-- Column type conventions (intentional — matches the Dart app):
--   · Datetime fields → VARCHAR(50)  ISO-8601 strings from Dart's
--     DateTime.toIso8601String(), e.g. "2026-05-04T14:30:00.000000".
--   · Array/JSON fields → TEXT  stored as raw JSON-encoded strings.
--   · Boolean fields → TINYINT(1)  0 = false, 1 = true.
--   · PK values → VARCHAR(36)  UUID v4 strings.
--   · _enc columns → TEXT  AES-256-CBC cipher text (base64).
--   · _lookup columns → CHAR(64)  hex SHA-256(salt::value) for
--     uniqueness checks without decrypting the stored value.
--
-- No application-level FK constraints: the app relies on
-- logical integrity and ON DELETE CASCADE is handled in Dart.
-- Adding FKs to an existing database requires all referenced rows
-- to already exist, which makes retroactive enforcement fragile.
-- ============================================================

SET NAMES utf8mb4;
SET foreign_key_checks = 0;

-- ============================================================
-- TABLE: users
-- One row per registered account.
-- Sensitive PII (_enc columns) encrypted with AES-256-CBC.
-- email_lookup / phone_lookup store deterministic SHA-256 hashes.
-- ============================================================
CREATE TABLE IF NOT EXISTS `users` (
  `id`                   VARCHAR(36)   NOT NULL,
  `email_enc`            TEXT          NOT NULL,
  `email_lookup`         CHAR(64)      NOT NULL      COMMENT 'SHA-256(salt::normalizedEmail)',
  `first_name_enc`       TEXT          NOT NULL,
  `last_name_enc`        TEXT          NOT NULL,
  `nickname_enc`         TEXT          DEFAULT NULL,
  `phone_enc`            TEXT          DEFAULT NULL,
  `phone_lookup`         CHAR(64)      DEFAULT NULL  COMMENT 'SHA-256(salt::normalizedPhone)',
  `date_of_birth_enc`    TEXT          DEFAULT NULL  COMMENT 'schema-compat only; not written since doc v7',
  `company_name_enc`     TEXT          DEFAULT NULL,
  `company_role_enc`     TEXT          DEFAULT NULL,
  `biography_enc`        TEXT          DEFAULT NULL,
  `password_hash`        VARCHAR(255)  NOT NULL      COMMENT 'SHA-256 with salt',
  `auth_provider`        VARCHAR(50)   NOT NULL DEFAULT 'email',
  `session_token`        VARCHAR(255)  DEFAULT NULL,
  `created_at`           VARCHAR(50)   NOT NULL,
  `last_login_at`        VARCHAR(50)   DEFAULT NULL,
  `password_changed_at`  VARCHAR(50)   NOT NULL      COMMENT 'rotated on every password change',
  `photo_path`           TEXT          DEFAULT NULL,
  `email_verified`       TINYINT(1)    NOT NULL DEFAULT 0,
  `organization_id`      VARCHAR(36)   DEFAULT NULL  COMMENT 'FK to organizations.id (nullable)',
  `org_role`             VARCHAR(20)   DEFAULT NULL  COMMENT 'admin | member | NULL',
  `plan`                 VARCHAR(20)   NOT NULL DEFAULT 'free' COMMENT 'free | premium | business',
  `last_sync_at`         VARCHAR(50)   DEFAULT NULL  COMMENT 'ISO-8601 timestamp of last successful sync (v11)',

  PRIMARY KEY (`id`),
  UNIQUE KEY `uq_users_email_lookup` (`email_lookup`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;


-- ============================================================
-- TABLE: contacts
-- One row per captured professional contact.
-- phone / email stored as-is; uniqueness checked via *_lookup.
-- ============================================================
CREATE TABLE IF NOT EXISTS `contacts` (
  `id`                VARCHAR(36)   NOT NULL,
  `owner_id`          VARCHAR(36)   NOT NULL,
  `first_name`        VARCHAR(255)  NOT NULL,
  `last_name`         VARCHAR(255)  NOT NULL,
  `job_title`         VARCHAR(255)  DEFAULT NULL,
  `company`           VARCHAR(255)  DEFAULT NULL,
  `phone`             VARCHAR(100)  DEFAULT NULL,
  `email`             VARCHAR(320)  DEFAULT NULL,
  `phone_lookup`      CHAR(64)      DEFAULT NULL  COMMENT 'SHA-256(salt::normalizedPhone)',
  `email_lookup`      CHAR(64)      DEFAULT NULL  COMMENT 'SHA-256(salt::normalizedEmail)',
  `source`            VARCHAR(100)  DEFAULT NULL,
  `project_1`         VARCHAR(255)  DEFAULT NULL,
  `project_1_budget`  VARCHAR(100)  DEFAULT NULL,
  `project_2`         VARCHAR(255)  DEFAULT NULL,
  `project_2_budget`  VARCHAR(100)  DEFAULT NULL,
  `interest`          TEXT          DEFAULT NULL,
  `notes`             TEXT          DEFAULT NULL,
  `tags`              TEXT          DEFAULT NULL  COMMENT 'JSON-encoded array e.g. [\"vip\",\"client\"]',
  `status`            VARCHAR(20)   NOT NULL DEFAULT 'warm' COMMENT 'hot | warm | cold',
  `created_at`        VARCHAR(50)   NOT NULL,
  `last_contact_date` VARCHAR(50)   DEFAULT NULL,
  `avatar_color`      VARCHAR(20)   DEFAULT NULL,
  `capture_method`    VARCHAR(20)   NOT NULL DEFAULT 'manual' COMMENT 'manual | scan | qr | nfc',
  `photo_path`        TEXT          DEFAULT NULL,

  PRIMARY KEY (`id`),
  KEY `idx_contacts_owner` (`owner_id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;


-- ============================================================
-- TABLE: reminders  (v5 schema: multi-contact + scheduling)
-- contact_ids: JSON-encoded array of contact UUIDs.
-- contact_id: legacy — first element of contact_ids (kept for compat).
-- priority_v2: canonical priority column.
-- title/description/due_date/priority: legacy columns, not read by the app.
-- ============================================================
CREATE TABLE IF NOT EXISTS `reminders` (
  `id`               VARCHAR(36)  NOT NULL,
  `owner_id`         VARCHAR(36)  NOT NULL,
  `contact_id`       VARCHAR(36)  DEFAULT NULL  COMMENT 'legacy: first element of contact_ids',
  `contact_ids`      TEXT         NOT NULL      COMMENT 'JSON-encoded array of contact UUIDs',
  `start_date_time`  VARCHAR(50)  NOT NULL,
  `end_date_time`    VARCHAR(50)  DEFAULT NULL  COMMENT 'NULL = no end',
  `repeat_frequency` VARCHAR(20)  DEFAULT NULL  COMMENT 'e.g. 1d | 1w | 1mo | NULL',
  `note`             TEXT         NOT NULL,
  `todo_action`      VARCHAR(20)  NOT NULL DEFAULT 'call'   COMMENT 'call | sms | whatsapp | email',
  `priority_v2`      VARCHAR(30)  NOT NULL DEFAULT 'normal' COMMENT 'very_important | important | normal',
  -- legacy columns kept for migration safety, not read by the app
  `title`            VARCHAR(255) DEFAULT NULL,
  `description`      TEXT         DEFAULT NULL,
  `due_date`         VARCHAR(50)  DEFAULT NULL,
  `priority`         VARCHAR(20)  DEFAULT NULL  COMMENT 'urgent | soon | later',
  `is_completed`     TINYINT(1)   NOT NULL DEFAULT 0,
  `created_at`       VARCHAR(50)  NOT NULL,

  PRIMARY KEY (`id`),
  KEY `idx_reminders_owner` (`owner_id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;


-- ============================================================
-- TABLE: interactions
-- Append-only audit log for contact actions (call, sms, email,
-- whatsapp, note) and field-level edits (type = 'edit').
-- ============================================================
CREATE TABLE IF NOT EXISTS `interactions` (
  `id`          VARCHAR(36)  NOT NULL,
  `owner_id`    VARCHAR(36)  NOT NULL,
  `contact_id`  VARCHAR(36)  NOT NULL,
  `type`        VARCHAR(20)  NOT NULL COMMENT 'call | sms | whatsapp | email | note | edit',
  `content`     TEXT         NOT NULL,
  `created_at`  VARCHAR(50)  NOT NULL,

  PRIMARY KEY (`id`),
  KEY `idx_interactions_contact` (`contact_id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;


-- ============================================================
-- TABLE: organizations  (v7)
-- invite_code: 8-char alphanumeric code [A-Z2-9] — no 0/O/1/I.
-- owner_id: not FK-enforced; references users.id logically.
-- ============================================================
CREATE TABLE IF NOT EXISTS `organizations` (
  `id`           VARCHAR(36)   NOT NULL,
  `name`         VARCHAR(255)  NOT NULL,
  `owner_id`     VARCHAR(36)   NOT NULL COMMENT 'references users.id',
  `invite_code`  CHAR(8)       NOT NULL,
  `created_at`   VARCHAR(50)   NOT NULL,

  PRIMARY KEY (`id`),
  UNIQUE KEY `uq_org_invite_code` (`invite_code`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;


-- ============================================================
-- TABLE: organization_members  (v7 + v8 privileges + v10 reminder access + v12 history access)
-- role: admin | member
-- status: active | suspended
-- can_edit / can_create / can_view_reminders / can_view_history: per-member flags.
-- Admins always have all four set to 1 regardless of stored value.
-- ============================================================
CREATE TABLE IF NOT EXISTS `organization_members` (
  `id`                  VARCHAR(36)  NOT NULL,
  `organization_id`     VARCHAR(36)  NOT NULL,
  `user_id`             VARCHAR(36)  NOT NULL,
  `role`                VARCHAR(20)  NOT NULL DEFAULT 'member' COMMENT 'admin | member',
  `status`              VARCHAR(20)  NOT NULL DEFAULT 'active' COMMENT 'active | suspended',
  `joined_at`           VARCHAR(50)  NOT NULL,
  `can_edit`            TINYINT(1)   NOT NULL DEFAULT 0 COMMENT 'overridden to 1 for role=admin',
  `can_create`          TINYINT(1)   NOT NULL DEFAULT 1 COMMENT 'overridden to 1 for role=admin',
  `can_view_reminders`  TINYINT(1)   NOT NULL DEFAULT 0 COMMENT 'overridden to 1 for role=admin',
  `can_view_history`    TINYINT(1)   NOT NULL DEFAULT 0 COMMENT 'overridden to 1 for role=admin',

  PRIMARY KEY (`id`),
  UNIQUE KEY `uq_org_members` (`organization_id`, `user_id`),
  KEY `idx_org_members_org`  (`organization_id`),
  KEY `idx_org_members_user` (`user_id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;


SET foreign_key_checks = 1;


-- ============================================================
-- UPGRADE SCRIPT — run this section against an existing cloud DB
-- to bring it to v12.  Every statement is idempotent (safe to
-- re-run).  Execute in order; stop on first error and investigate.
-- ============================================================

-- v8: per-member create / edit privileges
ALTER TABLE `organization_members`
  ADD COLUMN IF NOT EXISTS `can_edit`   TINYINT(1) NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS `can_create` TINYINT(1) NOT NULL DEFAULT 1;
-- backfill: admins get all privileges
UPDATE `organization_members`
  SET `can_edit` = 1, `can_create` = 1
  WHERE `role` = 'admin';

-- v9: subscription plan on each user row
ALTER TABLE `users`
  ADD COLUMN IF NOT EXISTS `plan` VARCHAR(20) NOT NULL DEFAULT 'free'
    COMMENT 'free | premium | business';

-- v10: per-member permission to view shared-contact reminders
ALTER TABLE `organization_members`
  ADD COLUMN IF NOT EXISTS `can_view_reminders` TINYINT(1) NOT NULL DEFAULT 0;
UPDATE `organization_members`
  SET `can_view_reminders` = 1
  WHERE `role` = 'admin';

-- v11: per-user last-sync timestamp
ALTER TABLE `users`
  ADD COLUMN IF NOT EXISTS `last_sync_at` VARCHAR(50) DEFAULT NULL
    COMMENT 'ISO-8601 timestamp of last successful sync for this user';

-- v12: per-member permission to view shared-contact history authored by other members
ALTER TABLE `organization_members`
  ADD COLUMN IF NOT EXISTS `can_view_history` TINYINT(1) NOT NULL DEFAULT 0;
UPDATE `organization_members`
  SET `can_view_history` = 1
  WHERE `role` = 'admin';

-- fix: widen invite_code from CHAR(6) to CHAR(8) — the app generator
-- has always produced 8-character codes; CHAR(6) was a documentation error.
ALTER TABLE `organizations`
  MODIFY COLUMN `invite_code` CHAR(8) NOT NULL;


-- ============================================================
-- Schema version history
-- ============================================================
-- v1–4  : Original contacts / reminders / users schema
-- v5    : Multi-contact reminders + scheduling columns
-- v6    : In-app notifications table (local-only; not synced to MySQL)
-- v7    : organizations + organization_members tables; org columns on users
-- v8    : Per-member can_edit / can_create privilege columns
-- v9    : users.plan subscription tier column
-- v10   : organization_members.can_view_reminders privilege column
-- v11   : users.last_sync_at — per-user timestamp of last successful sync
--         + correct invite_code width CHAR(6) → CHAR(8)
-- v12   : organization_members.can_view_history — controls visibility of history
--         records authored by other org members on shared contacts
-- ============================================================

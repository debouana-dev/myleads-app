-- ============================================================
-- me2leads  —  PostgreSQL schema v18
-- PostgreSQL 14+
-- Source of truth: lib/services/remote_sync_service.dart (_ensureSchema)
--
-- Column type conventions (intentional — matches the Dart app):
--   · Datetime fields → VARCHAR(50)  ISO-8601 strings from Dart's
--     DateTime.toIso8601String(), e.g. "2026-05-04T14:30:00.000000".
--   · Array/JSON fields → TEXT  stored as raw JSON-encoded strings.
--   · Boolean fields → SMALLINT  0 = false, 1 = true.
--   · PK values → VARCHAR(36)  UUID v4 strings.
--   · _enc columns → TEXT  AES-256-CBC cipher text (base64).
--   · _lookup columns → CHAR(64)  hex SHA-256(salt::value) for
--     uniqueness checks without decrypting the stored value.
--
-- No application-level FK constraints: the app relies on
-- logical integrity and ON DELETE CASCADE is handled in Dart.
-- ============================================================


-- ============================================================
-- TABLE: users
-- One row per registered account.
-- Sensitive PII (_enc columns) encrypted with AES-256-CBC.
-- email_lookup / phone_lookup store deterministic SHA-256 hashes.
-- ============================================================
CREATE TABLE IF NOT EXISTS "users" (
  "id"                   VARCHAR(36)   NOT NULL,
  "email_enc"            TEXT          NOT NULL,
  "email_lookup"         CHAR(64)      NOT NULL,
  "first_name_enc"       TEXT          NOT NULL,
  "last_name_enc"        TEXT          NOT NULL,
  "nickname_enc"         TEXT          DEFAULT NULL,
  "phone_enc"            TEXT          DEFAULT NULL,
  "phone_lookup"         CHAR(64)      DEFAULT NULL,
  "date_of_birth_enc"    TEXT          DEFAULT NULL,
  "company_name_enc"     TEXT          DEFAULT NULL,
  "company_role_enc"     TEXT          DEFAULT NULL,
  "biography_enc"        TEXT          DEFAULT NULL,
  "password_hash"        VARCHAR(255)  NOT NULL,
  "auth_provider"        VARCHAR(50)   NOT NULL DEFAULT 'email',
  "session_token"        VARCHAR(255)  DEFAULT NULL,
  "created_at"           VARCHAR(50)   NOT NULL,
  "last_login_at"        VARCHAR(50)   DEFAULT NULL,
  "password_changed_at"  VARCHAR(50)   NOT NULL,
  "photo_path"           TEXT          DEFAULT NULL,
  "email_verified"       SMALLINT      NOT NULL DEFAULT 0,
  "organization_id"      VARCHAR(36)   DEFAULT NULL,
  "org_role"             VARCHAR(20)   DEFAULT NULL,
  "plan"                        VARCHAR(20)   NOT NULL DEFAULT 'free',
  "last_sync_at"                VARCHAR(50)   DEFAULT NULL,
  "plan_expires_at"             VARCHAR(50)   DEFAULT NULL,
  "subscription_billing_cycle"  VARCHAR(10)   DEFAULT NULL,

  PRIMARY KEY ("id"),
  UNIQUE ("email_lookup")
);


-- ============================================================
-- TABLE: contacts
-- One row per captured professional contact.
-- phone / email stored as-is; uniqueness checked via *_lookup.
-- ============================================================
CREATE TABLE IF NOT EXISTS "contacts" (
  "id"                VARCHAR(36)   NOT NULL,
  "owner_id"          VARCHAR(36)   NOT NULL,
  "first_name"        VARCHAR(255)  NOT NULL,
  "last_name"         VARCHAR(255)  NOT NULL,
  "job_title"         VARCHAR(255)  DEFAULT NULL,
  "company"           VARCHAR(255)  DEFAULT NULL,
  "phone"             VARCHAR(100)  DEFAULT NULL,
  "email"             VARCHAR(320)  DEFAULT NULL,
  "phone_lookup"      CHAR(64)      DEFAULT NULL,
  "email_lookup"      CHAR(64)      DEFAULT NULL,
  "source"            VARCHAR(100)  DEFAULT NULL,
  "project_1"         VARCHAR(255)  DEFAULT NULL,
  "project_1_budget"  VARCHAR(100)  DEFAULT NULL,
  "project_2"         VARCHAR(255)  DEFAULT NULL,
  "project_2_budget"  VARCHAR(100)  DEFAULT NULL,
  "interest"          TEXT          DEFAULT NULL,
  "notes"             TEXT          DEFAULT NULL,
  "tags"              TEXT          DEFAULT NULL,
  "status"            VARCHAR(20)   NOT NULL DEFAULT 'warm',
  "created_at"        VARCHAR(50)   NOT NULL,
  "last_contact_date" VARCHAR(50)   DEFAULT NULL,
  "avatar_color"      VARCHAR(20)   DEFAULT NULL,
  "capture_method"    VARCHAR(20)   NOT NULL DEFAULT 'manual',
  "photo_path"        TEXT          DEFAULT NULL,

  PRIMARY KEY ("id")
);
CREATE INDEX IF NOT EXISTS "idx_contacts_owner" ON "contacts" ("owner_id");


-- ============================================================
-- TABLE: reminders  (v5 schema: multi-contact + scheduling)
-- contact_ids: JSON-encoded array of contact UUIDs.
-- contact_id: legacy — first element of contact_ids (kept for compat).
-- priority_v2: canonical priority column.
-- title/description/due_date/priority: legacy columns, not read by the app.
-- ============================================================
CREATE TABLE IF NOT EXISTS "reminders" (
  "id"               VARCHAR(36)  NOT NULL,
  "owner_id"         VARCHAR(36)  NOT NULL,
  "contact_id"       VARCHAR(36)  DEFAULT NULL,
  "contact_ids"      TEXT         NOT NULL,
  "start_date_time"  VARCHAR(50)  NOT NULL,
  "end_date_time"    VARCHAR(50)  DEFAULT NULL,
  "repeat_frequency" VARCHAR(20)  DEFAULT NULL,
  "note"             TEXT         NOT NULL,
  "todo_action"      VARCHAR(20)  NOT NULL DEFAULT 'call',
  "priority_v2"      VARCHAR(30)  NOT NULL DEFAULT 'normal',
  "title"            VARCHAR(255) DEFAULT NULL,
  "description"      TEXT         DEFAULT NULL,
  "due_date"         VARCHAR(50)  DEFAULT NULL,
  "priority"         VARCHAR(20)  DEFAULT NULL,
  "is_completed"     SMALLINT     NOT NULL DEFAULT 0,
  "created_at"       VARCHAR(50)  NOT NULL,

  PRIMARY KEY ("id")
);
CREATE INDEX IF NOT EXISTS "idx_reminders_owner" ON "reminders" ("owner_id");


-- ============================================================
-- TABLE: interactions
-- Append-only audit log for contact actions (call, sms, email,
-- whatsapp, note) and field-level edits (type = 'edit').
-- ============================================================
CREATE TABLE IF NOT EXISTS "interactions" (
  "id"          VARCHAR(36)  NOT NULL,
  "owner_id"    VARCHAR(36)  NOT NULL,
  "contact_id"  VARCHAR(36)  NOT NULL,
  "type"        VARCHAR(20)  NOT NULL,
  "content"     TEXT         NOT NULL,
  "created_at"  VARCHAR(50)  NOT NULL,

  PRIMARY KEY ("id")
);
CREATE INDEX IF NOT EXISTS "idx_interactions_contact" ON "interactions" ("contact_id");


-- ============================================================
-- TABLE: organizations  (v7, license columns added v17)
-- invite_code: 8-char alphanumeric code [A-Z2-9] — no 0/O/1/I.
-- owner_id: not FK-enforced; references users.id logically.
-- license_count: number of Business licenses purchased (includes admin).
-- org_status: 'active' | 'suspended' — suspended when licenses expire.
-- org_plan_expires_at: when the org licenses expire.
-- org_suspended_at: timestamp of suspension (triggers 6-month deletion).
-- ============================================================
CREATE TABLE IF NOT EXISTS "organizations" (
  "id"                  VARCHAR(36)   NOT NULL,
  "name"                VARCHAR(255)  NOT NULL,
  "owner_id"            VARCHAR(36)   NOT NULL,
  "invite_code"         CHAR(8)       NOT NULL,
  "created_at"          VARCHAR(50)   NOT NULL,
  "license_count"       INTEGER       NOT NULL DEFAULT 1,
  "org_plan_expires_at" VARCHAR(50)   DEFAULT NULL,
  "org_status"          VARCHAR(20)   NOT NULL DEFAULT 'active',
  "org_suspended_at"    VARCHAR(50)   DEFAULT NULL,

  PRIMARY KEY ("id"),
  UNIQUE ("invite_code")
);


-- ============================================================
-- TABLE: organization_members  (v7 + v8 privileges + v10 reminder access + v12 history access + v18 member profile denormalization)
-- role: admin | member
-- status: active | suspended
-- Denormalized member profile fields are stored here for fast local display.
-- can_edit / can_create / can_view_reminders / can_view_history: per-member flags.
-- Admins always have all four set to 1 regardless of stored value.
-- ============================================================
CREATE TABLE IF NOT EXISTS "organization_members" (
  "id"                  VARCHAR(36)  NOT NULL,
  "organization_id"     VARCHAR(36)  NOT NULL,
  "user_id"             VARCHAR(36)  NOT NULL,
  "role"                VARCHAR(20)  NOT NULL DEFAULT 'member',
  "status"              VARCHAR(20)  NOT NULL DEFAULT 'active',
  "joined_at"           VARCHAR(50)  NOT NULL,
  "first_name"          VARCHAR(255) NOT NULL DEFAULT '',
  "last_name"           VARCHAR(255) NOT NULL DEFAULT '',
  "email"               VARCHAR(255),
  "nickname"            VARCHAR(255),
  "company"             VARCHAR(255),
  "biography"           TEXT,
  "photo_path"          TEXT,
  "can_edit"            SMALLINT     NOT NULL DEFAULT 0,
  "can_create"          SMALLINT     NOT NULL DEFAULT 1,
  "can_view_reminders"  SMALLINT     NOT NULL DEFAULT 0,
  "can_view_history"    SMALLINT     NOT NULL DEFAULT 0,

  PRIMARY KEY ("id"),
  UNIQUE ("organization_id", "user_id")
);
CREATE INDEX IF NOT EXISTS "idx_org_members_org"  ON "organization_members" ("organization_id");
CREATE INDEX IF NOT EXISTS "idx_org_members_user" ON "organization_members" ("user_id");


-- ============================================================
-- TABLE: payment_history  (v13, payment_method added v15)
-- One row per successful Stripe payment.
-- Records billing cycle (monthly/yearly), the Stripe
-- Payment Intent ID for dispute resolution, and the payment
-- method type used (card, link, amazon_pay, etc.).
-- ============================================================
CREATE TABLE IF NOT EXISTS "payment_history" (
  "id"                        VARCHAR(36)   NOT NULL,
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
);
CREATE INDEX IF NOT EXISTS "idx_payment_history_user" ON "payment_history" ("user_id");


-- ============================================================
-- UPGRADE SCRIPT — run this section against an existing cloud DB
-- to bring it to v18.  Every statement is idempotent (safe to
-- re-run).  Execute in order; stop on first error and investigate.
-- ============================================================

-- v8: per-member create / edit privileges
ALTER TABLE "organization_members"
  ADD COLUMN IF NOT EXISTS "can_edit"   SMALLINT NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS "can_create" SMALLINT NOT NULL DEFAULT 1;
-- backfill: admins get all privileges
UPDATE "organization_members"
  SET "can_edit" = 1, "can_create" = 1
  WHERE "role" = 'admin';

-- v9: subscription plan on each user row
ALTER TABLE "users"
  ADD COLUMN IF NOT EXISTS "plan" VARCHAR(20) NOT NULL DEFAULT 'free';

-- v10: per-member permission to view shared-contact reminders
ALTER TABLE "organization_members"
  ADD COLUMN IF NOT EXISTS "can_view_reminders" SMALLINT NOT NULL DEFAULT 0;
UPDATE "organization_members"
  SET "can_view_reminders" = 1
  WHERE "role" = 'admin';

-- v11: per-user last-sync timestamp
ALTER TABLE "users"
  ADD COLUMN IF NOT EXISTS "last_sync_at" VARCHAR(50) DEFAULT NULL;

-- v12: per-member permission to view shared-contact history authored by other members
ALTER TABLE "organization_members"
  ADD COLUMN IF NOT EXISTS "can_view_history" SMALLINT NOT NULL DEFAULT 0;
UPDATE "organization_members"
  SET "can_view_history" = 1
  WHERE "role" = 'admin';

-- v18: denormalized member profile fields on organization_members
ALTER TABLE "organization_members"
  ADD COLUMN IF NOT EXISTS "first_name" VARCHAR(255) NOT NULL DEFAULT '',
  ADD COLUMN IF NOT EXISTS "last_name" VARCHAR(255) NOT NULL DEFAULT '',
  ADD COLUMN IF NOT EXISTS "email" VARCHAR(255),
  ADD COLUMN IF NOT EXISTS "nickname" VARCHAR(255),
  ADD COLUMN IF NOT EXISTS "company" VARCHAR(255),
  ADD COLUMN IF NOT EXISTS "biography" TEXT,
  ADD COLUMN IF NOT EXISTS "photo_path" TEXT;

-- fix: widen invite_code from CHAR(6) to CHAR(8) — the app generator
-- has always produced 8-character codes; CHAR(6) was a documentation error.
ALTER TABLE "organizations"
  ALTER COLUMN "invite_code" TYPE CHAR(8);

-- v13: Stripe payment history
CREATE TABLE IF NOT EXISTS "payment_history" (
  "id"                        VARCHAR(36)   NOT NULL,
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
);
CREATE INDEX IF NOT EXISTS "idx_payment_history_user" ON "payment_history" ("user_id");

-- v15: payment method type column on payment history
ALTER TABLE "payment_history"
  ADD COLUMN IF NOT EXISTS "payment_method" VARCHAR(50) NOT NULL DEFAULT 'card';

-- v16: subscription expiry tracking on users
ALTER TABLE "users"
  ADD COLUMN IF NOT EXISTS "plan_expires_at"            VARCHAR(50) DEFAULT NULL,
  ADD COLUMN IF NOT EXISTS "subscription_billing_cycle" VARCHAR(10) DEFAULT NULL;

-- v17: org license count, expiry, and suspension tracking
ALTER TABLE "organizations"
  ADD COLUMN IF NOT EXISTS "license_count"       INTEGER     NOT NULL DEFAULT 1,
  ADD COLUMN IF NOT EXISTS "org_plan_expires_at" VARCHAR(50) DEFAULT NULL,
  ADD COLUMN IF NOT EXISTS "org_status"          VARCHAR(20) NOT NULL DEFAULT 'active',
  ADD COLUMN IF NOT EXISTS "org_suspended_at"    VARCHAR(50) DEFAULT NULL;


-- ============================================================
-- Schema version history
-- ============================================================
-- v1–4  : Original contacts / reminders / users schema
-- v5    : Multi-contact reminders + scheduling columns
-- v6    : In-app notifications table (local-only; not synced to cloud)
-- v7    : organizations + organization_members tables; org columns on users
-- v8    : Per-member can_edit / can_create privilege columns
-- v9    : users.plan subscription tier column
-- v10   : organization_members.can_view_reminders privilege column
-- v11   : users.last_sync_at — per-user timestamp of last successful sync
-- v12   : organization_members.can_view_history — controls visibility of history
--         records authored by other org members on shared contacts
-- v13   : payment_history table — Stripe payment records (plan, cycle, amount)
-- v15   : payment_history.payment_method — Stripe payment method type
-- v16   : users.plan_expires_at + users.subscription_billing_cycle — subscription
--         expiry date and billing cycle for auto-downgrade and renewal UI
-- v17   : organizations.license_count + org_plan_expires_at + org_status +
--         org_suspended_at — per-org Business license pool with expiry,
--         suspension, and 6-month cloud deletion lifecycle
-- v18   : organization_members first_name + last_name + nickname + company +
--         biography + photo_path — denormalized member profile fields for org display
-- ============================================================

# CLAUDE.md — Me2Leads (Flutter mobile app)

**Permanent directives — apply to every change without exception:**

1. **Mobile only.** Do not prioritize the web build.
2. **Dark/light mode.** Use context-aware helpers in all widgets: `AppColors.bg(context)`, `.surfaceColor(context)`, `.onSurface(context)`, `.secondary(context)`, `.hint(context)`, `.borderColor(context)`, `.inputBackground(context)`, `.dividerColor(context)`. Never use static tokens (`AppColors.background`, `.card`, `.textDark`, etc.) in widgets. Never introduce a `const TextStyle` referencing a static color token that has a context-aware equivalent.
3. **Bilingual (FR/EN).** Every user-facing string must have both FR (`_en == false`) and EN (`_en == true`) entries in `lib/core/l10n/app_l10n.dart`. In widgets: `final l10n = ref.watch(l10nProvider)` → `l10n.xxx`. Never hardcode display strings. Use `"` double-quotes for literals containing apostrophes (`"Changer l'email"`).
4. **Schema sync.** Any DB change in `database_service.dart` (`_onCreate` / `_onUpgrade`) **or** `remote_sync_service.dart` (`_ensureSchema` / `_upsertXxx`) must also update `docs/schema.sql` in the same task — PostgreSQL 14+ compatible, matching column types (`VARCHAR(50)` datetimes, `TEXT` arrays, `SMALLINT` booleans), plus `ALTER TABLE … ADD COLUMN IF NOT EXISTS` in the UPGRADE SCRIPT section.

---

## 1. Project overview

- **Name:** Me2Leads — pub `myleads`, bundle `com.debouana.myleads`.
- **Pitch:** Capture professional contacts via OCR / QR / NFC / manual entry; lead scoring (hot/warm/cold), reminders, quick actions (call / SMS / WhatsApp / email).
- **Slogan:** *Scannez. Connectez. Convertissez.* (FR; EN fallback: `AppStrings.sloganEn`).
- **Stack:** Flutter 3.24.5, Dart `^3.5.0`, Riverpod 2.5, GoRouter 14, SQLite (sqflite + sqflite_common_ffi), PostgreSQL (`postgres`), FTP (`ftpconnect`), AES-256-CBC (`encrypt` + `flutter_secure_storage`), push notifications (`flutter_local_notifications` + `workmanager`), Firebase (core/auth/app-check/storage/cloud-functions), Stripe (`flutter_stripe ^12`, Android/web via Cloud Functions), RevenueCat (`purchases_flutter ^10`, iOS IAP), `flutter_dotenv`.
- **Pricing:** Free (10 contacts) · Premium `2.99 €/mo` · Business `5.99 €/user/mo`. Android/web → Stripe; iOS → RevenueCat. (`in_app_purchase` removed.)
- **Platforms:** Android (APK via GitHub Actions), iOS (CI-generated), Web (deprioritized).
- **Repository:** `debouana-dev/me2leads-app` — main branch triggers CI.

---

## 2. Directory tree

```
myleads-app/
├── CLAUDE.md
├── pubspec.yaml
├── .github/workflows/build.yml       ← CI: APK + web build + release
├── assets/  (animations/, fonts/, icons/, images/)
└── lib/
    ├── main.dart                     ← entry: SystemChrome, StorageService.init(), startUserSync()
    ├── test/org_sync_test.dart       ← 47 integration tests (org lifecycle, dedup, permissions)
    ├── config/app_config.dart        ← XOR-obfuscated creds (SMTP/PostgreSQL/FTP) + feature flags
    ├── core/
    │   ├── constants/app_strings.dart
    │   ├── l10n/app_l10n.dart        ← AppL10n class + l10nProvider (FR/EN)
    │   ├── router/app_router.dart    ← GoRouter (routes below)
    │   ├── theme/app_colors.dart     ← brand tokens + context-aware helpers (§3.1)
    │   ├── theme/app_theme.dart      ← Material ThemeData + shadow helpers
    │   └── utils/validators.dart     ← email / password / phone regex
    ├── models/
    │   ├── contact.dart
    │   ├── interaction.dart
    │   ├── reminder.dart
    │   ├── user_account.dart         ← UserAccount + PaymentRecord
    │   ├── organization.dart         ← Organization + OrgMember
    │   ├── app_notification.dart
    │   ├── plan_features.dart
    │   └── app_task.dart
    ├── providers/
    │   ├── auth_provider.dart        ← signUp / login / logout / changeEmail / changePassword / deleteAccount
    │   ├── contacts_provider.dart    ← CRUD + filters + search
    │   ├── navigation_provider.dart  ← currentTabProvider
    │   ├── reminders_provider.dart   ← CRUD + 5 computed lists
    │   ├── notifications_provider.dart
    │   ├── settings_provider.dart    ← locale + theme
    │   ├── currency_provider.dart
    │   ├── organization_provider.dart ← org CRUD + member mgmt + 7 derived privilege providers
    │   └── tasks_provider.dart        ← org task CRUD + completion + sync
    ├── screens/
    │   ├── splash/splash_screen.dart
    │   ├── auth/                     ← login / signup / forgot / verify / reset
    │   ├── home/main_shell.dart      ← IndexedStack + bottom nav (§4)
    │   ├── home/home_screen.dart     ← dashboard + stat cards
    │   ├── contacts/                 ← list, detail, edit, history, contact-reminders
    │   ├── scan/scan_screen.dart     ← card / QR / NFC
    │   ├── review/review_screen.dart ← post-OCR verification
    │   ├── reminders/                ← list, create, detail
    │   ├── profile/                  ← profile, account security, sync, import/export
    │   ├── notifications/
    │   ├── settings/
    │   ├── organization/             ← admin panel, create, join
    │   ├── tasks/                    ← list, create/edit, detail
    │   └── pricing/                  ← pricing, subscription plan, payment history, transaction detail
    ├── services/
    │   ├── action_tracker.dart       ← WidgetsBindingObserver: logs Interaction on app background
    │   ├── background_task.dart      ← WorkManager: reminders + 15-min Business auto-sync
    │   ├── calendar_service.dart     ← add_2_calendar wrapper
    │   ├── contact_actions.dart      ← url_launcher (call/sms/whatsapp/email)
    │   ├── contact_import_export_service.dart ← CSV/JSON import/export
    │   ├── currency_service.dart
    │   ├── database_service.dart     ← SQLite schema v28 + migrations
    │   ├── email_service.dart        ← SMTP (verification/reset codes)
    │   ├── encryption_service.dart   ← AES-256-CBC master key in Keystore
    │   ├── ftp_photo_service.dart    ← upload/download/delete (relative paths)
    │   ├── notification_service.dart ← in-app + push + scheduled triggers
    │   ├── ocr_parser.dart           ← text → Contact fields
    │   ├── ocr_service_mobile.dart   ← ML Kit (mobile only — never import directly)
    │   ├── ocr_service_stub.dart     ← web/desktop stub
    │   ├── photo_storage_service.dart ← local photo file resolution
    │   ├── remote_sync_service.dart  ← PostgreSQL sync + live-write + cloud user helpers
    │   ├── revenue_cat_service.dart  ← RevenueCat iOS IAP
    │   ├── storage_service.dart      ← facade: DB + crypto + sync init order
    │   ├── stripe_service.dart       ← Stripe PaymentSheet + Link recovery via Cloud Functions
    │   ├── subscription_service.dart ← grace periods, expiry, auto-downgrade
    │   └── web_db_factory_{stub,web}.dart ← conditional sqflite import
    └── widgets/
        ├── bottom_nav_bar.dart       ← legacy standalone variant
        ├── lead_card.dart
        ├── ocr_data_summary.dart     ← OCR confidence bar (high/fair/low)
        ├── phone_prefix_input.dart   ← country prefix selector (+352/+1)
        ├── quick_action_button.dart
        ├── search_bar_widget.dart
        └── status_badge.dart
```

### Routes (`lib/core/router/app_router.dart`)

All "Slide" transitions are Slide L→R unless noted.

| Path | Screen | Transition |
|------|--------|------------|
| `/` | `SplashScreen` | — |
| `/login` | `LoginScreen` | Fade |
| `/signup` | `SignupScreen` | Slide |
| `/forgot-password` | `ForgotPasswordScreen` | Slide |
| `/email-verification` | `EmailVerificationScreen(email)` | Slide |
| `/recovery-code` | `RecoveryCodeScreen(email)` | Slide |
| `/reset-password` | `ResetPasswordScreen(email,code)` | Slide |
| `/main` | `MainShell` (tabbed) | Fade |
| `/scan` | `ScanScreen` | Fade |
| `/review` | `ReviewScreen(ocrData)` | Slide |
| `/contact/new` | `ContactEditScreen` | Slide |
| `/contact/:id` | `ContactDetailScreen` | Slide |
| `/contact/:id/edit` | `ContactEditScreen(contactId)` | Slide |
| `/contact/:id/history` | `ContactHistoryScreen` | Slide |
| `/contact/:id/reminders` | `ContactRemindersScreen` | Slide |
| `/reminder/new` | `CreateReminderScreen` | Slide |
| `/reminder/:id` | `ReminderDetailScreen` | Slide |
| `/my-profile` | `MyProfileScreen` | Slide |
| `/account-security` | `AccountSecurityScreen` | Slide |
| `/pricing` | `PricingScreen` | Slide (bottom) |
| `/subscription-plan` | `SubscriptionPlanScreen` | Slide |
| `/payment-history` | `PaymentHistoryScreen` | Slide |
| `/transaction-details` | `TransactionDetailScreen(record)` | Slide |
| `/notifications` | `NotificationsScreen` | Slide |
| `/settings` | `SettingsScreen` | Slide |
| `/sync` | `SyncScreen` | Slide |
| `/import-export` | `ImportExportScreen` | Slide |
| `/organization` | `OrganizationAdminScreen` | Slide |
| `/organization/create` | `CreateOrganizationScreen` | Slide |
| `/organization/join` | `JoinOrganizationScreen` | Slide |
| `/organization/tasks` | `TasksScreen` | Slide |
| `/organization/tasks/new` | `CreateTaskScreen(existing?)` | Slide |
| `/organization/task/:id` | `TaskDetailScreen(taskId)` | Slide |

---

## 3. Design system

### 3.1 Brand colors — `lib/core/theme/app_colors.dart`

Never hardcode hex. Context-aware helpers are **required in all widgets** (see Directive 2). Static tokens are valid only in gradient stops and `const` contexts.

| Token | Hex | Usage |
|-------|-----|-------|
| `primary` | `#0B3C5D` | Brand navy — CTAs, titles, nav highlight |
| `primaryLight` | `#134B73` | `primaryGradient` top-end |
| `primaryDark` | `#072A42` | Pressed state |
| `accent` | `#D4AF37` | Brand gold — scan button, secondary CTA |
| `accentLight` | `#E8CC6E` | `accentGradient` top-end |
| `hot` | `#E74C3C` | HOT status / error / `very_important` |
| `hotLight` | `#FF6B6B` | gradient companion |
| `warm` | `#F39C12` | WARM status / warning / `important` |
| `warmLight` | `#FFC048` | gradient companion |
| `cold` | `#95A5A6` | COLD status |
| `coldLight` | `#B0BEC5` | gradient companion |
| `success` | `#27AE60` | Success, call tint |
| `successLight` | `#6DD5A0` | gradient companion |
| `error` | `#E74C3C` | = `hot` |
| `warning` | `#F39C12` | = `warm` |
| `info` | `#3498DB` | Informational |
| `background` | `#F0F2F5` | Scaffold bg |
| `card` | `#FFFFFF` | Card surfaces |
| `textDark` | `#1A1A2E` | Headings |
| `textMid` | `#5A5A7A` | Secondary copy |
| `textLight` | `#9A9ABF` | Hints, inactive nav |
| `border` | `#E8EAF0` | Dividers, inputs |
| `divider` | `#F0F0F5` | Thin rules |
| `inputBg` | `#F0F2F5` | = `background` |

**Gradients** (all 135° TL→BR): `primaryGradient` · `accentGradient` · `hotGradient` · `warmGradient` · `avatarGradient(status)`.

### 3.2 Typography

Font: `PlusJakartaSans` (`assets/fonts/`). Weights: 400 body · 600 nav/labels · 700 buttons · 800 page titles.
Input label: 12px / w700 / `textLight` / ls=1 (see `app_theme.dart:63`). Snackbar: 14px / w600 / white on `primary`.

### 3.3 Spacing, radii, shadows

Radii: `8` chips · `10` small buttons · `12` inputs/small cards · `14–16` cards · `20` filter chips · `22` pill tabs · `24–28` large cards.

Shadows — always use helpers, never raw `BoxShadow`:
- `AppTheme.cardShadow` → blur 20, y=4, primary @8%
- `AppTheme.cardShadowLg` → blur 40, y=8, primary @12%
- `AppTheme.accentShadow` → blur 20, y=6, accent @30%

Section padding: 20–24px horizontal · 16–24px vertical. Respect `MediaQuery.padding` safe-area + 88px shell footer.

### 3.4 Status semantics

| Value | Color | Badge |
|---|---|---|
| `status='hot'` | `hot` | HOT |
| `status='warm'` | `warm` | WARM |
| `status='cold'` | `cold` | COLD |
| `priority='very_important'` | `hot` | — |
| `priority='important'` | `warm` | — |
| `priority='normal'` | `success` | — |

New status values require changes in `AppColors`, `status_badge.dart`, and filter chips in `contacts_screen.dart` / `reminders_screen.dart`.

### 3.5 Iconography

Use `Icons.xxx_rounded` throughout. `iconsax` 0.0.8 available as fallback. No asset icon set.

---

## 4. Navigation & shell

`MainShell` (`lib/screens/home/main_shell.dart`): `IndexedStack`, 88px bottom nav + safe-area, `extendBody: true`. Never add `Scaffold.bottomNavigationBar` to a tab screen.

| # | Icon | Label | Screen |
|---|------|-------|--------|
| 0 | `home_rounded` | Home | `HomeScreen` |
| 1 | `people_rounded` | Contacts | `ContactsScreen` |
| 2 | `qr_code_scanner_rounded` *(gold pill, +16px)* | — | `ScanScreen` |
| 3 | `access_time_rounded` | Rappels | `RemindersScreen` |
| 4 | `person_rounded` | Compte | `ProfileScreen` |

Active: `AppColors.accent` · Inactive: `AppColors.textLight`. Scan pill: `accentGradient`, 4px white border, `accent @40%` shadow.

**FAB rule:** `Padding(padding: EdgeInsets.only(bottom: 88 + MediaQuery.of(context).padding.bottom))`.

**Sub-screen navigation** — always forward the Riverpod container:
```dart
Navigator.push(context, MaterialPageRoute(
  builder: (_) => ProviderScope(
    parent: ProviderScope.containerOf(context),
    child: const CreateReminderScreen(),
  ),
));
```
Top-level jumps: `context.go` / `context.push` (GoRouter).

---

## 5. State management (Riverpod 2)

All providers: `StateNotifierProvider` + immutable state with `copyWith` + `_sentinel` to distinguish "not provided" from explicit null.

| Provider | Exposes |
|---|---|
| `authProvider` | `signUp`, `login`, `logout`, `changePassword`, `changeEmail`, `deleteAccount` |
| `contactsProvider` | CRUD + `filteredContacts`, `activeFilter`, `statusFilter`, `searchQuery`, `totalContacts` |
| `remindersProvider` | CRUD + `todayReminders`, `weekReminders`, `laterReminders`, `lateReminders`, `doneReminders`, `refresh()` |
| `currentTabProvider` | `StateProvider<int>` — active tab index |
| `notificationsProvider` | Feed: unread count, mark-read, delete |
| `settingsProvider` | Locale (`_en` bool) + theme |
| `currencyProvider` | Real-time currency conversion |
| `organizationProvider` | Org CRUD + member mgmt; `OrgState`: `uniqueContactCount`, `currentUserCanViewHistory`, `currentUserCanExportContacts`; derived: `orgCanCreateProvider`, `orgCanEditOthersProvider`, `orgCanViewRemindersProvider`, `orgCanViewHistoryProvider`, `orgCanExportContactsProvider`, `orgCanViewOthersTasksProvider`, `orgCurrentUserIsSuspendedProvider` |
| `tasksProvider` | Org task CRUD + `pendingTasks`, `completedTasks`, `myAssignedTasks()`, `syncAndLoad()`, `syncSilently()`, `completeTask()`, `uncompleteTask()`, `deleteTask()` |
| `l10nProvider` | Defined in `lib/core/l10n/app_l10n.dart`; returns `AppL10n(_en)`. Use `ref.watch(l10nProvider)` in every widget displaying user-facing text. |

---

## 6. Data model (SQLite schema v28)

### Contact
```
id TEXT PK, first_name, last_name, job_title, company,
phone (AES-encrypted), email (AES-encrypted), source,
project_1, project_1_budget, project_2, project_2_budget,
interest, notes, tags, status, created_at, last_contact_date,
avatar_color, capture_method, owner_id, photo_path,
email_lookup (SHA-256), phone_lookup (SHA-256)
```
`photo_path` is always a **relative path** (e.g. `contact_pictures/<userId>/<file>.jpg`). Resolve to absolute with `PhotoStorageService`; upload/download with `FtpPhotoService`.

### Reminder
```
id, owner_id, contact_ids (JSON array), start_datetime, end_datetime,
repeat_frequency, note, to_do_action (call|sms|whatsapp|email),
priority (very_important|important|normal), is_completed, created_at
```

### UserAccount
```
id, full_name, email, email_hash, password_hash, phone,
photo_path, session_token, created_at, plan, last_sync_at,
plan_expires_at, subscription_billing_cycle (monthly|yearly),
apple_user_identifier
```
- `plan_expires_at` + `subscription_billing_cycle`: renewal windows and grace-period tracking (v16).
- `apple_user_identifier`: Apple Sign-In reconnection when email is hidden by Apple relay (v23).
- `session_token` rotated on logout/password change. `last_sync_at` updated on every successful PostgreSQL pull.

### Interaction
```
id, contact_id, type (call|sms|whatsapp|email|note|edit), at, payload
```

### Organization
```
id, name, owner_id, invite_code (8-char alphanumeric), created_at,
license_count, org_plan_expires_at, org_status (active|suspended), org_suspended_at
```
`license_count` / `org_plan_expires_at` / `org_status` added v17 for org-tier subscription gating.

### OrgMember
```
id, org_id, user_id, role (admin|member|owner), status (active|suspended),
can_edit, can_create, can_view_reminders, can_view_history, can_export_contacts,
can_view_others_tasks,
joined_at, first_name, last_name, phone (org-key AES-encrypted),
email (org-key AES-encrypted), nickname, company, biography, photo_path
```
- All six privileges true for admins and owners.
- `role='owner'` introduced in v25 — org creator's row promoted from `'admin'`. Owners have the same privileges as admins.
- Profile fields (v18) denormalized to avoid cross-user DB joins.
- `email` encrypted with the **org-specific key** (not user master key). v21 migrated any plaintext rows — ciphertext never contains `@`, so `email.contains('@')` detects un-encrypted values.
- `removeMember` / `suspendMember` transfers only non-duplicate contacts to admin (dedup by `phone_lookup` / `email_lookup`).

### PaymentRecord
```
id, user_id, plan, billing_cycle (monthly|yearly), amount, currency,
status, stripe_payment_intent_id, payment_method,
transaction_id (M2L + 7 digits), account_type (individual|organization), created_at
```
Displayed on `PaymentHistoryScreen`; detail view on `TransactionDetailScreen`.

### AppNotification
```
id, owner_id, type, title, body, scheduled_at, created_at, reference_id, is_read
```

### AppTask
```
id, organization_id (nullable — future personal tasks), created_by_user_id,
assigned_to_user_id (legacy only — source of truth is task_assignees join table),
assignee_user_ids (List<String>, populated at read time from task_assignees),
start_date_time, end_date_time, repeat_frequency,
note, todo_action (call|sms|whatsapp|email), priority (very_important|important|normal),
is_completed, completed_by_user_id, created_at
```
Helper properties: `isOverdue`, `isToday`, `isThisWeek`, `isLater`, `isLate`, `sortKey`.

### task_assignees (join table)
```
task_id TEXT, user_id TEXT, assigned_at TEXT — PK (task_id, user_id)
```
`assigned_to_user_id` kept in `tasks` for SQLite backward compat (cannot drop columns); `task_assignees` is authoritative. Never read `assigned_to_user_id` directly — always use `AppTask.assigneeUserIds`.

### Schema version history

| Version | Change |
|---------|--------|
| 1–4 | Base: contacts / reminders / users |
| 5 | Multi-contact reminders |
| 6 | `app_notifications` table |
| 7 | `organizations` + `org_members` |
| 8 | `can_edit` / `can_create` on members |
| 9 | `users.plan` |
| 10 | `org_members.can_view_reminders` |
| 11 | `users.last_sync_at` |
| 12 | `org_members.can_view_history` |
| 13 | `payment_history` table |
| 14 | No-op gap |
| 15 | `payment_history.payment_method` |
| 16 | `users.plan_expires_at` + `subscription_billing_cycle` |
| 17 | Org licensing columns (`license_count`, `org_plan_expires_at`, `org_status`, `org_suspended_at`) |
| 18 | Denormalized member profile fields |
| 19 | `payment_history.transaction_id` |
| 20 | `org_members.can_export_contacts` |
| 21 | Re-encrypt member emails with org key |
| 22 | `payment_history.account_type` |
| 23 | `users.apple_user_identifier` |
| 24 | `org_members.phone` (org-key AES-encrypted) |
| 25 | Org creator `role` promoted `admin` → `owner`; `users.org_role` synced |
| 26 | `tasks` table (org task assignment) |
| 27 | `task_assignees` join table (multi-member); legacy `assigned_to_user_id` kept in `tasks` |
| 28 | `org_members.can_view_others_tasks` (default 0; 1 for admin/owner) |

**Bump `_dbVersion` and add `if (oldVersion < N)` on every schema change. Never rewrite existing tables.**

---

## 7. Remote sync & photo storage

### PostgreSQL sync (`remote_sync_service.dart`)

- **Target:** `AppConfig.pgHost:5432`, db `me2leads`. Credentials XOR-obfuscated in `app_config.dart` (key `MyLeads2026SecretKey`).
- **Plan gate:** Free → user row only. Premium/Business → full sync. Enforced via `_hasSyncPlan` on both push and pull.
- **Push:** user row always; contacts/reminders/interactions/org data require Premium+. Migrates absolute photo paths to relative before upsert (`_migrateAndUploadPhotos`).
- **Pull:** upserts to SQLite. Never overwrites local `session_token` or `password_hash` — prevents multi-device logout. Updates `last_sync_at`.
- **Auto sync:** `startUserSync()` in `main.dart` — debounces 3s on connectivity restore, all plans.
- **Business background sync:** `scheduleBusinessSync()` → WorkManager every 15 min. Cancelled via `cancelBusinessSync()` on logout/plan change.
- **Live-write:** every `DatabaseService` write fires a background `ON CONFLICT … DO UPDATE` upsert. Errors swallowed by `_fireAndForget()` — never blocks UI.
- **Cloud user helpers:** `isEmailTakenInCloud()`, `registerUserInCloud()`, `importUserByEmailLookup()`, `deleteUserFromCloud()`, `findCloudUserIdByEmailLookup()`.
- **Security-field helpers:** `updatePasswordInCloud()`, `updateEmailInCloud()`, `updateEmailVerifiedInCloud()` — use these for sensitive fields; live-write intentionally excludes password hash.

### FTP photo storage (`ftp_photo_service.dart`)

Layout: `photos/profile_pictures/<userId>/` · `photos/contact_pictures/<userId>/`.
`photo_path` in SQLite is always **relative**. `PhotoStorageService` resolves to absolute; `FtpPhotoService` uses the relative path directly. Server directories auto-created on first upload. All failures silently ignored; web always returns false.

---

## 8. Organizations & team management

- **Create/join:** `/organization/create` (owner) or `/organization/join` (invite code).
- **Admin panel `/organization`:** member list, invite code (copy/regenerate), privilege matrix, suspend/remove.

| Privilege flag | Allows |
|---|---|
| `can_create` | add contacts |
| `can_edit` | edit any org contact |
| `can_view_reminders` | see reminders on shared contacts |
| `can_view_history` | see history from other members |
| `can_export_contacts` | CSV/JSON export |
| `can_view_others_tasks` | see tasks assigned to other members |

Derived providers: `orgCanCreateProvider` · `orgCanEditOthersProvider` · `orgCanViewRemindersProvider` · `orgCanViewHistoryProvider` · `orgCanExportContactsProvider` · `orgCanViewOthersTasksProvider` · `orgCurrentUserIsSuspendedProvider`.

`ContactHistoryScreen` filters to current-user entries only when `orgCanViewHistoryProvider` is false.
`OrgState.uniqueContactCount` is the deduplicated org total (not raw per-member sum).

**Task access rules:**
- `orgCurrentUserIsSuspendedProvider = true` → blocks all task view/create/interact operations; screens show a warning overlay.
- `orgCanViewOthersTasksProvider = false` → `TasksScreen` defaults to "Mine" scope; "All" toggle is hidden.
- Admin/owner can assign tasks to multiple members; regular members always self-assign on creation.
- Edit: admin, owner, or task creator only. Complete/reopen: admin, owner, creator, or assignee. Delete: admin/owner only.

---

## 9. Conventions

1. **Colors — tokens only.** Context-aware helpers in widgets (see Directive 2 and §3.1). Static tokens valid only in `const`/gradient contexts.
2. **Strings — AppL10n only.** FR + EN in `app_l10n.dart`. `ref.watch(l10nProvider)` in every widget. See Directive 3.
3. **Forms.** Lean on `InputDecorationTheme`. When overriding: `cursorColor: AppColors.primary`, `style: TextStyle(color: AppColors.onSurface(context))`, `hintStyle: TextStyle(color: AppColors.hint(context))`.
4. **Buttons.** Primary → `ElevatedButton` · Secondary → `OutlinedButton` · Tertiary → `TextButton`. No custom wrapper unless reused ≥ 3×.
5. **Cards.** `Container` with `color: AppColors.surfaceColor(context)`, `BorderRadius.circular(14–16)`, **either** `border` **or** `boxShadow` (not both).
6. **Priority bars.** 4px left-side vertical bar in `priorityColor` on all priority-bearing cards.
7. **Icons.** `Icons.xxx_rounded` throughout. `iconsax` available as fallback.
8. **Encryption.** New sensitive columns: (a) `EncryptionService.encryptText`, (b) `_lookup` SHA-256 companion if uniqueness queries needed.
9. **No PII in logs.** `debugPrint` for non-sensitive metadata only.
10. **Platform guards.** `kIsWeb` + `Platform.isWindows/isLinux` in services; conditional imports via `web_db_factory_{stub,web}.dart`.
11. **OCR.** Never import `ocr_service_mobile.dart` directly — use `storage_service.dart`.
12. **Sync writes.** Never call PostgreSQL from providers/screens — always `DatabaseService`; live-write callbacks propagate automatically.
13. **Photo paths.** Always relative in SQLite. `PhotoStorageService` → absolute; `FtpPhotoService` → relative as-is.
14. **Org privilege checks.** `orgCanCreateProvider` / `orgCanEditOthersProvider` before mutations; `orgCanViewHistoryProvider` before history display; `orgCanExportContactsProvider` before export.
15. **Payments.** Android/web → `StripeService`. iOS → `RevenueCatService`. Subscription changes → `SubscriptionService`. Never call Stripe SDK or write plan to DB directly.

---

## 10. Build & CI

`.github/workflows/build.yml` — triggered on push to `main`.

| Job | Steps |
|---|---|
| `build-android` | Java 17 → Flutter 3.24.5 → `flutter create` → patch `build.gradle` (ProGuard) → patch `AndroidManifest.xml` (INTERNET + POST_NOTIFICATIONS + RECEIVE_BOOT_COMPLETED + WAKE_LOCK + `<queries>` for tel/sms/mailto/https/http) → `flutter build apk --release --no-tree-shake-icons` → `dart run sqflite_common_ffi_web:setup` → `flutter build web --base-href "/me2leads-app/"` → upload |
| `release` | Delete + recreate `v1.0.0` release, attach APK |
| `deploy-web` | Publish `build/web/` to GitHub Pages |

**`android/` and `ios/` are regenerated on every CI run.** All manifest/gradle changes go in the workflow patch steps, not committed files. CAMERA permission is injected by `mobile_scanner` / `image_picker` library manifests — do not add it manually.

Release URL: `https://github.com/debouana-dev/me2leads-app/releases/download/v1.0.0/app-release.apk`

---

## 11. Quick-start

| Task | Start here |
|---|---|
| New screen | `lib/screens/…` + `GoRoute` in `app_router.dart` |
| New tab | `MainShell._screens` + `_buildBottomNav` Row + `currentTabProvider` default |
| New model | `lib/models/` → `_onCreate` + bump `_dbVersion` + `_onUpgrade` in `database_service.dart` → `_ensureSchema` in `remote_sync_service.dart` → `docs/schema.sql` |
| Any DB change | Same three files: `database_service.dart` + `remote_sync_service.dart` + `docs/schema.sql` |
| New string | FR + EN in `app_l10n.dart` (+ `AppStrings` if also a constant) |
| Brand colour | Edit `AppColors` — propagates through `AppTheme` + gradients |
| Platform permission | Patch step in `build.yml` — not `AndroidManifest.xml` (regenerated) |
| Release APK | Push to `main` — CI builds and publishes |
| Watch CI | `gh run list --limit 3` → `gh run watch <id> --exit-status` |
| Manual sync | `/sync` → push/pull via `RemoteSyncService` |
| Org-gated UI | Check relevant `orgCan…Provider` before action/display |
| Org task | `lib/screens/tasks/` + `tasksProvider` + `syncTasksForOrg()` in `remote_sync_service.dart` |
| Payment (Android/web) | `StripeService` |
| Payment (iOS) | `RevenueCatService` |
| Subscription change | `SubscriptionService` — never raw DB plan writes |
| Test org/sync | `test/org_sync_test.dart` (47 cases) |

---

## 12. Known constraints & gotchas

- **`DropdownButtonFormField`:** `value:` not `initialValue:` — the latter requires Flutter >3.27; pinned SDK is 3.24.5.
- **Scanner black-screen:** camera starts in `initState` intentionally — removing it reintroduces the bug. `onDetect` is a no-op in card mode.
- **Riverpod sub-screen:** `Navigator.push` must wrap in `ProviderScope(parent: …)` or providers reset to initial state.
- **`extendBody: true`:** tab FABs render behind the nav unless wrapped with `Padding(bottom: 88 + safeArea.bottom)`.
- **No build-runner output committed.** Run `flutter pub run build_runner build` locally; CI regenerates.
- **Live-write errors swallowed.** `_fireAndForget()` logs but never throws. Use `/sync` to investigate divergence.
- **Session preservation.** `pull()` never overwrites local `session_token` / `password_hash`. Use targeted helpers (`updatePasswordInCloud`, `updateEmailInCloud`) for security-field syncs.
- **Plan-gated sync.** Calling `push()` / `pull()` on Free plan is safe — data tables silently skipped.
- **Multi-device login.** Email not found locally → `AuthNotifier` calls `importUserByEmailLookup()`. Only `session_token` updated locally — password hash left intact to avoid decryption key mismatch.
- **Org member email.** Encrypted with org key (not user master key). Detect plaintext via `email.contains('@')`. Always use org-keyed encryption path in `EncryptionService`.
- **Contact transfer.** `removeMember` / `suspendMember` transfers non-duplicate contacts in both SQLite + PostgreSQL before membership change commits. Never remove members via raw DB calls.
- **Stripe Link recovery.** Mid-flow Link browser redirects store a pending-recovery record in `StripeService`. Resume logic stays in `StripeService` — do not handle payment state in screens.
- **RevenueCat.** Must be configured before any purchase attempt. Android/web use Stripe; iOS uses RevenueCat.
- **Apple Sign-In.** `apple_user_identifier` matches accounts when Apple hides the email via relay.
- **Task multi-assignee.** `task_assignees` is the source of truth; `tasks.assigned_to_user_id` is a legacy remnant (SQLite cannot drop columns). Never read it directly — always use `AppTask.assigneeUserIds`.
- **Task suspension gate.** `orgCurrentUserIsSuspendedProvider` is checked at the top of `TasksScreen` and `CreateTaskScreen`. Suspended members see a warning overlay and cannot perform any task operations.
- **Subscription lifecycle.** Grace periods: 1 day monthly, 5 days yearly. Auto-downgrade on expiry via `SubscriptionService` — never raw DB plan writes.
- **Credentials.** PostgreSQL + FTP XOR-obfuscated in `app_config.dart` (key `MyLeads2026SecretKey`). Firebase/Stripe keys via `flutter_dotenv`. Never commit secrets.
- **SQLite web.** `dart run sqflite_common_ffi_web:setup` required before `flutter build web` (CI handles this).

---

## 13. Version history anchors

| Anchor | Schema | Highlights |
|---|---|---|
| doc v3 | — | Multi-contact reminders, QR, calendar sync, email change (first pass) |
| doc v4 | — | Clickable stat cards, search-bar polish, functional `changeEmail` |
| doc v5 | — | FAB fix, scanner black-screen fix, notifications screen, delete account, OCR enrichment |
| doc v7 | — | WhatsApp off list card (kept on detail), `font_awesome_flutter`, DOB removed, auto-calendar on reminder save, `ActionTracker`, field-diff edit logging, unified history |
| doc v8 | v11 | Orgs + member roles, invite codes, 3 privileges, contact transfer, PostgreSQL sync, FTP photos, push notifications, notification feed, settings, pricing/payment, import/export, Me2Leads rename |
| doc v9 | v12 | Plan-gated sync, multi-device login, session preservation, `startUserSync`, Business 15-min bg sync, security-field helpers, `transferNonDuplicateContactsToAdmin`, `can_view_history`, `uniqueContactCount`, 47-case test suite |
| doc v10 | v20 | MySQL→PostgreSQL (port 5432, `ON CONFLICT…DO UPDATE`), `can_export_contacts` + `orgCanExportContactsProvider` |
| doc v11 | v23 | Stripe + RevenueCat, `SubscriptionService`, `PaymentRecord` / `payment_history`, `TransactionDetailScreen`, org licensing (v17), member profile fields (v18), org-key email encryption (v21), Apple Sign-In (v23), Firebase, `OcrDataSummary`, `PhonePrefixInput` |
| doc v12 | v28 | Task management: `AppTask`, `tasksProvider`, `TasksScreen` / `CreateTaskScreen` / `TaskDetailScreen`, multi-member `task_assignees` (v27), `can_view_others_tasks` + `owner` role (v28), `syncTasksForOrg()`, task notifications + calendar integration |

*When "doc vN" is referenced, match behavior to the nearest anchor and consult `git log --oneline`.*

---

*On adding a top-level `lib/` folder, new route, theme token, or CI step: update §2, §3, §4, §5, §6, §10 as appropriate.*

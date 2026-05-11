import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:sign_in_with_apple/sign_in_with_apple.dart';
import 'package:uuid/uuid.dart';

import '../core/l10n/app_l10n.dart';
import '../core/utils/validators.dart';
import '../models/contact.dart';
import '../models/user_account.dart';
import '../services/database_service.dart';
import '../services/email_service.dart';
import '../services/encryption_service.dart';
import '../services/notification_service.dart';
import '../services/photo_storage_service.dart';
import '../services/background_task.dart';
import '../services/remote_sync_service.dart';
import '../services/storage_service.dart';

const _uuid = Uuid();

// Sentinel used in AuthState.copyWith to distinguish "not provided" from null.
const _authSentinel = Object();

/// In-memory container for a pending password-recovery code.
class _RecoveryCode {
  final String code;
  final DateTime expiresAt;
  _RecoveryCode(this.code, this.expiresAt);
  bool get isExpired => DateTime.now().isAfter(expiresAt);
}

class AuthState {
  final bool isLoggedIn;
  final bool isLoading;
  final String userName;
  final String userEmail;
  final String? userPhotoPath;
  final String? error;
  final bool requiresEmailVerification;

  /// Current subscription plan: 'free' | 'premium' | 'business'.
  final String plan;

  /// When the current paid subscription expires (null for free plan).
  final DateTime? planExpiresAt;

  /// 'monthly' | 'yearly' | null (null for free plan).
  final String? subscriptionBillingCycle;

  const AuthState({
    this.isLoggedIn = false,
    this.isLoading = false,
    this.userName = '',
    this.userEmail = '',
    this.userPhotoPath,
    this.error,
    this.requiresEmailVerification = false,
    this.plan = 'free',
    this.planExpiresAt,
    this.subscriptionBillingCycle,
  });

  AuthState copyWith({
    bool? isLoggedIn,
    bool? isLoading,
    String? userName,
    String? userEmail,
    String? userPhotoPath,
    String? error,
    bool clearError = false,
    bool clearPhoto = false,
    bool? requiresEmailVerification,
    String? plan,
    Object? planExpiresAt = _authSentinel,
    Object? subscriptionBillingCycle = _authSentinel,
  }) {
    return AuthState(
      isLoggedIn: isLoggedIn ?? this.isLoggedIn,
      isLoading: isLoading ?? this.isLoading,
      userName: userName ?? this.userName,
      userEmail: userEmail ?? this.userEmail,
      userPhotoPath: clearPhoto ? null : (userPhotoPath ?? this.userPhotoPath),
      error: clearError ? null : (error ?? this.error),
      requiresEmailVerification:
          requiresEmailVerification ?? this.requiresEmailVerification,
      plan: plan ?? this.plan,
      planExpiresAt: identical(planExpiresAt, _authSentinel)
          ? this.planExpiresAt
          : planExpiresAt as DateTime?,
      subscriptionBillingCycle:
          identical(subscriptionBillingCycle, _authSentinel)
              ? this.subscriptionBillingCycle
              : subscriptionBillingCycle as String?,
    );
  }
}

class AuthNotifier extends StateNotifier<AuthState> {
  final Ref _ref;

  AuthNotifier(this._ref)
      : super(AuthState(
          isLoggedIn: StorageService.isLoggedIn,
          userName: StorageService.userName,
          userEmail: StorageService.userEmail,
          userPhotoPath: StorageService.currentUser?.photoPath,
          plan: StorageService.currentUser?.plan ?? 'free',
          planExpiresAt: StorageService.currentUser?.planExpiresAt,
          subscriptionBillingCycle:
              StorageService.currentUser?.subscriptionBillingCycle,
        ));

  AppL10n get _l10n => _ref.read(l10nProvider);

  // ---------------- Email login ----------------

  Future<bool> login(String email, String password) async {
    state = state.copyWith(isLoading: true, clearError: true);

    final emailErr = Validators.validateEmail(email);
    if (emailErr != null) {
      state = state.copyWith(
        isLoading: false,
        error: emailErr,
        requiresEmailVerification: false,
      );
      return false;
    }

    final lookup = _emailLookup(email);
    await EncryptionService.initFromEnv(email);
    var user = await DatabaseService.findUserByEmailLookup(lookup);
    var importedFromCloud = false;

    if (user == null) {
      // No local account — try the cloud database.
      debugPrint(
          'AuthNotifier.login: local user missing, attempting cloud import for lookup $lookup');
      final cloudResult =
          await RemoteSyncService.importUserByEmailLookup(lookup);
      if (cloudResult == null) {
        debugPrint(
            'AuthNotifier.login: cloud lookup failed for lookup $lookup');
        state = state.copyWith(
          isLoading: false,
          error: _l10n.authCloudConnectionError,
          requiresEmailVerification: false,
        );
        return false;
      }
      if (cloudResult) {
        importedFromCloud = true;
        debugPrint(
            'AuthNotifier.login: cloud account found and imported for lookup $lookup');
        user = await DatabaseService.findUserByEmailLookup(lookup);
      }
      if (user == null) {
        debugPrint(
            'AuthNotifier.login: no account found in cloud for lookup $lookup');
        state = state.copyWith(
          isLoading: false,
          error: _l10n.authNoAccountForEmail,
          requiresEmailVerification: false,
        );
        return false;
      }
    }

    if (user.authProvider != 'email') {
      final providerName = user.authProvider == 'google' ? 'Google' : 'Apple';
      state = state.copyWith(
        isLoading: false,
        error: _l10n.authWrongProvider(providerName),
        requiresEmailVerification: false,
      );
      return false;
    }

    if (!EncryptionService.verifyPassword(password, user.passwordHash)) {
      state = state.copyWith(
        isLoading: false,
        error: _l10n.authInvalidCredentials,
        requiresEmailVerification: false,
      );
      return false;
    }

    // If the email has not been verified yet, send a verification code and
    // block login until verification is complete.
    if (!user.emailVerified) {
      await sendVerificationCode(email);
      state = state.copyWith(
        isLoading: false,
        error: _l10n.authEmailNotVerified(email),
        requiresEmailVerification: true,
      );
      return false;
    }

    final token = EncryptionService.generateSessionToken();
    final updated = user.copyWith(
      sessionToken: token,
      lastLoginAt: DateTime.now(),
    );

    if (importedFromCloud) {
      // The profile fields in the local SQLite row are encrypted with another
      // device's AES key. Calling updateUser would re-encrypt empty/garbled
      // decrypted values and push them back to the cloud via the live-write
      // callback, erasing the correct profile data.
      // Only update session-specific columns — the cloud data stays intact.
      await DatabaseService.updateUserSessionToken(
          user.id, token, DateTime.now());
    } else {
      await DatabaseService.updateUser(updated);
    }
    await StorageService.setCurrentSession(updated, token);
    await EncryptionService.initFromEnv(updated.email);

    state = state.copyWith(
      isLoggedIn: true,
      isLoading: false,
      userName: updated.fullName,
      userEmail: updated.email,
      plan: updated.plan,
      clearError: true,
      requiresEmailVerification: false,
    );

    if (await StorageService.getEffectivePlan() == 'business') {
      await scheduleBusinessSync();
    }

    // When the user record was pulled from the cloud, bring their data too.
    if (importedFromCloud) {
      debugPrint(
          'AuthNotifier.login: user imported from cloud, starting RemoteSyncService.pull for ${updated.id}');
      unawaited(RemoteSyncService.pull(updated.id));
    }

    return true;
  }

  // ---------------- Email signup ----------------

  Future<bool> signup({
    required String firstName,
    required String lastName,
    required String email,
    required String password,
    String? phone,
  }) async {
    state = state.copyWith(isLoading: true, clearError: true);

    // Require internet — account must be registered in both local and cloud DB.
    if (!kIsWeb) {
      final connectivity = await Connectivity().checkConnectivity();
      if (connectivity.contains(ConnectivityResult.none)) {
        state = state.copyWith(
          isLoading: false,
          error: _l10n.authInternetRequiredSignup,
        );
        return false;
      }
    }

    if (firstName.trim().isEmpty || lastName.trim().isEmpty) {
      state = state.copyWith(
        isLoading: false,
        error: _l10n.authFirstLastNameRequired,
      );
      return false;
    }

    final emailErr = Validators.validateEmail(email);
    if (emailErr != null) {
      state = state.copyWith(isLoading: false, error: emailErr);
      return false;
    }

    final pwdErr = Validators.validatePassword(password);
    if (pwdErr != null) {
      state = state.copyWith(isLoading: false, error: pwdErr);
      return false;
    }

    if (phone != null && phone.trim().isNotEmpty) {
      final phoneErr = Validators.validatePhone(phone, required: false);
      if (phoneErr != null) {
        state = state.copyWith(isLoading: false, error: phoneErr);
        return false;
      }
    }

    if (await DatabaseService.isEmailTaken(email)) {
      state = state.copyWith(
        isLoading: false,
        error: _l10n.authEmailAlreadyUsed,
      );
      return false;
    }

    // Also check the cloud database — an account registered on another device
    // would not appear in the local DB.
    final emailLookup = DatabaseService.lookupHashForEmail(email.trim());
    if (await RemoteSyncService.isEmailTakenInCloud(emailLookup)) {
      state = state.copyWith(
        isLoading: false,
        error: _l10n.authEmailAlreadyUsed,
      );
      return false;
    }

    if (phone != null &&
        phone.trim().isNotEmpty &&
        await DatabaseService.isPhoneTaken(phone)) {
      state = state.copyWith(
        isLoading: false,
        error: _l10n.authPhoneAlreadyUsed,
      );
      return false;
    }

    await EncryptionService.initFromEnv(email.trim());
    final token = EncryptionService.generateSessionToken();
    final user = UserAccount(
      id: _uuid.v4(),
      email: email.trim(),
      firstName: firstName.trim(),
      lastName: lastName.trim(),
      phone: phone?.trim(),
      passwordHash: EncryptionService.hashPassword(password),
      authProvider: 'email',
      sessionToken: token,
      lastLoginAt: DateTime.now(),
    );

    await DatabaseService.insertUser(user);

    // Explicitly register in the cloud database (awaited for guaranteed write).
    // The live-write background callback fired by insertUser is best-effort;
    // this call confirms the record is present before we complete signup.
    final rawRow = await DatabaseService.getRawUserRow(user.id);
    final cloudErr = rawRow != null
        ? await RemoteSyncService.registerUserInCloud(rawRow)
        : 'local_insert_missing';
    if (cloudErr != null) {
      // Roll back the local insert and clean up any partial cloud write.
      await DatabaseService.deleteUserAndAllData(user.id);
      unawaited(RemoteSyncService.deleteUserFromCloud(user.id));
      state = state.copyWith(
        isLoading: false,
        error: _l10n.createAccErrRetry,
      );
      return false;
    }

    await StorageService.setCurrentSession(user, token);

    state = state.copyWith(
      isLoggedIn: true,
      isLoading: false,
      userName: user.fullName,
      userEmail: user.email,
      clearError: true,
    );

    // Send email verification code (non-blocking).
    unawaited(sendVerificationCode(email.trim()));

    return true;
  }

  // ---------------- Google sign-in ----------------

  Future<bool> signInWithGoogle() async {
    state = state.copyWith(isLoading: true, clearError: true);
    try {
      debugPrint('AuthNotifier.signInWithGoogle: starting Google sign-in flow');
      final google = GoogleSignIn(
          scopes: ['email'], serverClientId: dotenv.env['SERVERCLIENTID']);
      final account = await google.signIn();
      if (account == null) {
        state = state.copyWith(isLoading: false);
        return false;
      }
      debugPrint(
          'AuthNotifier.signInWithGoogle: Google account retrieved (email: ${account.email})');
      return _upsertOAuthUser(
        email: account.email,
        firstName: account.displayName?.split(' ').first ?? 'User',
        lastName: account.displayName?.split(' ').skip(1).join(' ') ?? '',
        provider: 'google',
      );
    } catch (e) {
      state = state.copyWith(
        isLoading: false,
        error: _l10n.authGoogleFailed(e.toString()),
      );
      return false;
    }
  }

  // ---------------- Apple sign-in ----------------

  Future<bool> signInWithApple() async {
    state = state.copyWith(isLoading: true, clearError: true);
    try {
      debugPrint('AuthNotifier.signInWithApple: starting Apple sign-in flow');
      final credential = await SignInWithApple.getAppleIDCredential(
        scopes: [
          AppleIDAuthorizationScopes.email,
          AppleIDAuthorizationScopes.fullName,
        ],
      );
      final email = credential.email;
      if (email == null) {
        state = state.copyWith(
          isLoading: false,
          error: _l10n.authAppleNoEmail,
        );
        return false;
      }
      debugPrint(
          'AuthNotifier.signInWithApple: Apple account retrieved (email: $email)');
      return _upsertOAuthUser(
        email: email,
        firstName: credential.givenName ?? 'User',
        lastName: credential.familyName ?? '',
        provider: 'apple',
      );
    } catch (e) {
      state = state.copyWith(
        isLoading: false,
        error: _l10n.authAppleFailed(e.toString()),
      );
      return false;
    }
  }

  Future<bool> _upsertOAuthUser({
    required String email,
    required String firstName,
    required String lastName,
    required String provider,
  }) async {
    // Initialize encryption with user-specific key for OAuth users
    await EncryptionService.initFromEnv(email);

    final lookup = _emailLookup(email);
    debugPrint(
        'AuthNotifier._upsertOAuthUser: checking local/remote OAuth account for provider=$provider, lookup=$lookup');
    var user = await DatabaseService.findUserByEmailLookup(lookup);
    final token = EncryptionService.generateSessionToken();

    if (user == null) {
      debugPrint(
          'AuthNotifier._upsertOAuthUser: no local account found, attempting cloud import for $provider');
      // Try to import from cloud
      final cloudResult =
          await RemoteSyncService.importUserByEmailLookup(lookup);
      if (cloudResult == true) {
        debugPrint(
            'AuthNotifier._upsertOAuthUser: cloud account found and imported for $provider');
        user = await DatabaseService.findUserByEmailLookup(lookup);
      } else if (cloudResult == false) {
        debugPrint(
            'AuthNotifier._upsertOAuthUser: no cloud account found, creating new $provider account');
      } else {
        debugPrint(
            'AuthNotifier._upsertOAuthUser: cloud lookup failed (no connection), proceeding with local creation for $provider');
      }

      if (user == null) {
        user = UserAccount(
          id: _uuid.v4(),
          email: email,
          firstName: firstName,
          lastName: lastName,
          passwordHash: '',
          authProvider: provider,
          sessionToken: token,
          lastLoginAt: DateTime.now(),
        );
        await DatabaseService.insertUser(user);
        debugPrint(
            'AuthNotifier._upsertOAuthUser: new $provider account created with id=${user.id}');
      }
    } else {
      debugPrint(
          'AuthNotifier._upsertOAuthUser: existing local account found (id=${user.id}, provider=${user.authProvider})');
      if (user.authProvider != provider) {
        state = state.copyWith(
          isLoading: false,
          error: _l10n.authOAuthEmailConflict(user.authProvider),
        );
        return false;
      }
      user = user.copyWith(sessionToken: token, lastLoginAt: DateTime.now());
      await DatabaseService.updateUser(user);
    }

    await StorageService.setCurrentSession(user, token);
    // Encryption already initialized above
    state = state.copyWith(
      isLoggedIn: true,
      isLoading: false,
      userName: user.fullName,
      userEmail: user.email,
      plan: user.plan,
      clearError: true,
    );
    if (await StorageService.getEffectivePlan() == 'business') {
      await scheduleBusinessSync();
    }
    return true;
  }

  // ---------------- Plan management ----------------

  /// Switches the current user's subscription plan, persists it to the database,
  /// and updates the in-memory session so every Riverpod listener is notified.
  ///
  /// [billingCycle] is required for paid plans ('monthly' | 'yearly').
  /// It is ignored when [plan] is 'free'.
  ///
  /// Returns `null` on success, or an error string on failure.
  Future<String?> changePlan(String plan,
      {String billingCycle = 'monthly'}) async {
    final user = StorageService.currentUser;
    if (user == null) return _l10n.authNoUserLoggedIn;
    if (!['free', 'premium', 'business'].contains(plan)) {
      return _l10n.authInvalidPlan;
    }

    DateTime? planExpiresAt;
    String? subscriptionBillingCycle;

    if (plan != 'free') {
      planExpiresAt = billingCycle == 'yearly'
          ? DateTime.now().add(const Duration(days: 365))
          : DateTime.now().add(const Duration(days: 30));
      subscriptionBillingCycle = billingCycle;
    }

    final updated = user.copyWith(
      plan: plan,
      planExpiresAt: planExpiresAt,
      subscriptionBillingCycle: subscriptionBillingCycle,
    );
    await DatabaseService.updateUser(updated);
    await StorageService.setCurrentSession(updated, user.sessionToken ?? '');
    state = state.copyWith(
      plan: plan,
      planExpiresAt: planExpiresAt,
      subscriptionBillingCycle: subscriptionBillingCycle,
    );

    if (await StorageService.getEffectivePlan() == 'business') {
      await scheduleBusinessSync();
    } else {
      await cancelBusinessSync();
    }

    // Manage subscription renewal push notifications.
    if (plan == 'free') {
      unawaited(
          NotificationService.cancelSubscriptionRenewalNotifications(user.id));
    } else {
      unawaited(NotificationService.scheduleSubscriptionRenewalNotifications(
        userId: user.id,
        planExpiresAt: planExpiresAt!,
        billingCycle: billingCycle,
      ));
    }

    return null;
  }

  // ---------------- Logout ----------------

  Future<void> logout() async {
    await cancelBusinessSync();
    await StorageService.clearSession();
    state = const AuthState();
  }

  /// Permanently deletes the current user account and every piece of
  /// data that belongs to them (contacts, reminders, interactions,
  /// payment methods, photo files) from both local and cloud databases.
  /// Requires an active internet connection.
  ///
  /// When the user is a non-admin org member, their contacts are transferred
  /// to the org admin first so the org workspace is not affected.
  /// When the user is the org admin with remaining members, deletion is
  /// blocked — they must transfer or dissolve the org first.
  ///
  /// Returns `null` on success, or an error string on failure.
  Future<String?> deleteAccount() async {
    final user = StorageService.currentUser;
    if (user == null) return _l10n.authNoUserLoggedIn;

    // Require internet — account must be erased from both databases.
    if (!kIsWeb) {
      final connectivity = await Connectivity().checkConnectivity();
      if (connectivity.contains(ConnectivityResult.none)) {
        return _l10n.authInternetRequiredDelete;
      }
    }

    try {
      final userPhotoPath = user.photoPath;
      final userId = user.id;

      if (user.organizationId != null) {
        if (user.orgRole == 'admin') {
          // Block deletion if other members still depend on this org.
          final members = await DatabaseService.getMembersForOrganization(
              user.organizationId!);
          final hasOtherMembers = members.any((m) => m.userId != userId);
          if (hasOtherMembers) {
            return _l10n.authDeleteOrgBlocker;
          }
          // Last admin and sole member — dissolve the org before erasing data.
          // The live-write callback on deleteOrganization handles the cloud
          // org + org_members deletion in the background.
          await DatabaseService.deleteOrganization(user.organizationId!);
        } else {
          // Non-admin member: transfer contacts to the admin (cloud handled via
          // live-write callbacks), then erase this user from both databases.
          // Contact photo files are NOT deleted — they now belong to the admin.
          await DatabaseService.transferOrgContactsToAdmin(
              fromUserId: userId, orgId: user.organizationId!);
          // Cloud delete excludes contacts (already re-owned by admin).
          final cloudErr = await RemoteSyncService.deleteUserFromCloud(
            userId,
            includeContacts: false,
          );
          if (cloudErr != null) {
            debugPrint('deleteAccount cloud error: $cloudErr');
          }
          await DatabaseService.deleteUserAndAllData(userId);
          await StorageService.clearSession();
          state = const AuthState();
          if (!kIsWeb) _deleteFileIfExists(userPhotoPath);
          return null;
        }
      }

      // Standard path (solo user or admin who just dissolved their org):
      // collect contact photo paths before rows are erased.
      final List<Contact> contacts =
          await DatabaseService.getAllContactsForOwner(userId);
      // Delete all user data from the cloud first, then locally.
      final cloudErr = await RemoteSyncService.deleteUserFromCloud(userId);
      if (cloudErr != null) debugPrint('deleteAccount cloud error: $cloudErr');
      await DatabaseService.deleteUserAndAllData(userId);
      await StorageService.clearSession();
      state = const AuthState();
      if (!kIsWeb) {
        _deleteFileIfExists(userPhotoPath);
        for (final c in contacts) {
          _deleteFileIfExists(c.photoPath);
        }
      }

      return null;
    } catch (e) {
      return _l10n.authDeleteError(e.toString());
    }
  }

  static void _deleteFileIfExists(String? path) {
    if (path == null || path.isEmpty) return;
    try {
      final resolved = PhotoStorageService.resolveAbsolutePath(path);
      if (resolved == null) return;
      final file = File(resolved);
      if (file.existsSync()) file.deleteSync();
    } catch (_) {}
  }

  // ---------------- Change password ----------------

  /// Changes the user's password and rotates the session token.
  /// All other devices using the previous token will fail validation
  /// and be forced to log in again (effectively logging them out).
  Future<String?> changePassword(
      String currentPassword, String newPassword) async {
    final user = StorageService.currentUser;
    if (user == null) return _l10n.authNoUserLoggedIn;

    if (user.authProvider != 'email') {
      return _l10n.authPasswordNotModifiable(user.authProvider);
    }

    if (!EncryptionService.verifyPassword(currentPassword, user.passwordHash)) {
      return _l10n.authCurrentPasswordIncorrect;
    }

    final pwdErr = Validators.validatePassword(newPassword);
    if (pwdErr != null) return pwdErr;

    // Rotate session token — invalidates all other devices.
    final newToken = EncryptionService.generateSessionToken();
    final updated = user.copyWith(
      passwordHash: EncryptionService.hashPassword(newPassword),
      sessionToken: newToken,
      passwordChangedAt: DateTime.now(),
    );
    await DatabaseService.updateUser(updated);
    await StorageService.setCurrentSession(updated, newToken);

    // Sync to cloud — the background live-write callback excludes password_hash
    // from its ON DUPLICATE KEY UPDATE clause, so an explicit call is required.
    final rawRow = await DatabaseService.getRawUserRow(updated.id);
    if (rawRow != null) {
      unawaited(RemoteSyncService.updatePasswordInCloud(
        userId: updated.id,
        passwordHash: (rawRow['password_hash'] as String?) ?? '',
        sessionToken: rawRow['session_token'] as String?,
        passwordChangedAt: rawRow['password_changed_at'] as String?,
      ));
    }

    return null; // success
  }

  /// Changes the user's email, validated by a 6-digit code previously
  /// sent to the new address via [sendVerificationCode]. Requires the
  /// current password as an extra safeguard and rotates the session token
  /// so other devices are forced to log in again.
  ///
  /// Returns `null` on success, or an error string on failure.
  Future<String?> changeEmail(
      String newEmail, String code, String currentPassword) async {
    final user = StorageService.currentUser;
    if (user == null) return _l10n.authNoUserLoggedIn;

    if (user.authProvider != 'email') {
      return _l10n.authEmailNotModifiable(user.authProvider);
    }

    // Validate new email format.
    final emailErr = Validators.validateEmail(newEmail);
    if (emailErr != null) return emailErr;

    // Check current password.
    if (!EncryptionService.verifyPassword(currentPassword, user.passwordHash)) {
      return _l10n.authCurrentPasswordIncorrect;
    }

    // Disallow changing to an email already in use by another account —
    // check both the local database and the cloud database.
    final newLookup = _emailLookup(newEmail);
    final existing = await DatabaseService.findUserByEmailLookup(newLookup);
    if (existing != null && existing.id != user.id) {
      return _l10n.authEmailAlreadyInUse;
    }
    final cloudOwnerId =
        await RemoteSyncService.findCloudUserIdByEmailLookup(newLookup);
    if (cloudOwnerId != null && cloudOwnerId != user.id) {
      return _l10n.authEmailAlreadyInUse;
    }

    // Verify the 6-digit code sent to the new address.
    final stored = _verificationCodes[newLookup];
    if (stored == null) {
      return _l10n.authNoVerificationCodePending;
    }
    if (stored.isExpired) {
      _verificationCodes.remove(newLookup);
      return _l10n.authCodeExpired;
    }
    if (stored.code != code.trim()) {
      return _l10n.authInvalidVerificationCode;
    }

    // Preserve the old email so we can decrypt existing contacts with the old key.
    final oldEmail = user.email;
    await EncryptionService.initFromEnv(oldEmail);
    final contacts = await DatabaseService.getAllContactsForOwner(user.id);

    // Rotate session token (invalidates other devices) and persist.
    final newToken = EncryptionService.generateSessionToken();
    final updated = user.copyWith(
      email: newEmail.trim(),
      sessionToken: newToken,
      emailVerified: true,
    );
    await DatabaseService.updateUser(updated);
    await StorageService.setCurrentSession(updated, newToken);
    await EncryptionService.initFromEnv(updated.email);
    state = state.copyWith(userEmail: newEmail.trim());

    // Re-encrypt all contacts with the new email-derived key.
    for (final contact in contacts) {
      await DatabaseService.updateContact(contact);
    }

    // Clear the used code.
    _verificationCodes.remove(newLookup);

    // Sync to cloud — the background live-write callback updates email_enc but
    // intentionally skips email_lookup, which would leave the cloud with a
    // stale lookup hash and break login on other devices after an email change.
    final rawRow = await DatabaseService.getRawUserRow(updated.id);
    if (rawRow != null) {
      unawaited(RemoteSyncService.updateEmailInCloud(
        userId: updated.id,
        emailEnc: (rawRow['email_enc'] as String?) ?? '',
        emailLookup: (rawRow['email_lookup'] as String?) ?? '',
        sessionToken: rawRow['session_token'] as String?,
      ));
    }

    return null; // success
  }

  /// Refreshes userName, userEmail, userPhotoPath and plan from the current
  /// in-memory session so every Riverpod watcher rebuilds immediately.
  /// Call this after any profile mutation that doesn't go through AuthNotifier
  /// (e.g. saving first/last name in MyProfileScreen).
  void refreshFromStorage() {
    final user = StorageService.currentUser;
    if (user == null) return;
    state = state.copyWith(
      userName: user.fullName,
      userEmail: user.email,
      userPhotoPath: user.photoPath,
      plan: user.plan,
      planExpiresAt: user.planExpiresAt,
      subscriptionBillingCycle: user.subscriptionBillingCycle,
    );
  }

  /// Update the current user's profile photo path.
  Future<void> updatePhoto(String? photoPath) async {
    final user = StorageService.currentUser;
    if (user == null) return;
    final updated = user.copyWith(photoPath: photoPath);
    await DatabaseService.updateUser(updated);
    await StorageService.setCurrentSession(updated, user.sessionToken ?? '');
    state = state.copyWith(userPhotoPath: photoPath);
  }

  // ---------------- Password Recovery ----------------

  /// In-memory map of email-lookup → pending recovery code.
  /// Keyed by the same deterministic lookup hash used for DB lookups so we
  /// never store the raw email in memory beyond what is strictly needed.
  static final Map<String, _RecoveryCode> _recoveryCodes = {};

  /// In-memory map of email-lookup → pending email-verification code.
  /// Same keying strategy as [_recoveryCodes].
  static final Map<String, _RecoveryCode> _verificationCodes = {};

  /// Validates [email], checks that a local account exists, generates a
  /// random 6-digit recovery code valid for 10 minutes and stores it in
  /// [_recoveryCodes].
  ///
  /// Returns `null` on success, or an error string on failure.
  Future<String?> sendRecoveryCode(String email) async {
    final emailErr = Validators.validateEmail(email);
    if (emailErr != null) return emailErr;

    final lookup = _emailLookup(email);
    var user = await DatabaseService.findUserByEmailLookup(lookup);
    if (user == null) {
      // No local account — try the cloud database.
      final cloudResult =
          await RemoteSyncService.importUserByEmailLookup(lookup);
      if (cloudResult == null) {
        return _l10n.authCloudConnectionError;
      }
      if (cloudResult) {
        user = await DatabaseService.findUserByEmailLookup(lookup);
      }
      if (user == null) {
        return _l10n.authNoAccountForEmailRecovery;
      }
    }

    if (user.authProvider != 'email') {
      final providerName = user.authProvider == 'google' ? 'Google' : 'Apple';
      return _l10n.authOAuthNoRecovery(providerName);
    }

    // Generate a 6-digit code.
    final rand = Random.secure();
    final code = (100000 + rand.nextInt(900000)).toString();

    _recoveryCodes[lookup] = _RecoveryCode(
      code,
      DateTime.now().add(const Duration(minutes: 10)),
    );

    // Try to send email (non-blocking — code is still valid if email fails).
    unawaited(EmailService.sendRecoveryEmail(email, code));

    return null; // success
  }

  /// Verifies that [code] matches the stored recovery code for [email] and
  /// hasn't expired.
  ///
  /// Returns `null` on success, or an error string on failure.
  Future<String?> verifyRecoveryCode(String email, String code) async {
    final lookup = _emailLookup(email);
    final stored = _recoveryCodes[lookup];

    if (stored == null) {
      return _l10n.authNoRecoveryCodePending;
    }
    if (stored.isExpired) {
      _recoveryCodes.remove(lookup);
      return _l10n.authCodeExpired;
    }
    if (stored.code != code.trim()) {
      return _l10n.authInvalidRecoveryCode;
    }
    return null; // success
  }

  /// Resets the password for the account identified by [email], after
  /// re-verifying [code].  Rotates the session token so that any other active
  /// sessions are invalidated.
  ///
  /// Returns `null` on success, or an error string on failure.
  Future<String?> resetPassword(
      String email, String code, String newPassword) async {
    // Re-verify the code.
    final codeErr = await verifyRecoveryCode(email, code);
    if (codeErr != null) return codeErr;

    // Validate new password strength.
    final pwdErr = Validators.validatePassword(newPassword);
    if (pwdErr != null) return pwdErr;

    // Fetch the user.
    final lookup = _emailLookup(email);
    final user = await DatabaseService.findUserByEmailLookup(lookup);
    if (user == null) return _l10n.authNoAccountForEmailRecovery;

    // Hash the new password, rotate token and persist.
    final newToken = EncryptionService.generateSessionToken();
    final updated = user.copyWith(
      passwordHash: EncryptionService.hashPassword(newPassword),
      sessionToken: newToken,
      passwordChangedAt: DateTime.now(),
    );
    await DatabaseService.updateUser(updated);

    // Clear the used recovery code.
    _recoveryCodes.remove(lookup);

    // If this user happens to be the currently-logged-in user, update the
    // local session so they remain logged in after reset.
    final current = StorageService.currentUser;
    if (current != null && current.id == user.id) {
      await StorageService.setCurrentSession(updated, newToken);
      await EncryptionService.initFromEnv(updated.email);
      state = state.copyWith(
        isLoggedIn: true,
        userName: updated.fullName,
        userEmail: updated.email,
        clearError: true,
      );
    }

    // Sync to cloud — same reason as changePassword: password_hash is excluded
    // from the background live-write ON DUPLICATE KEY UPDATE clause.
    final rawRow = await DatabaseService.getRawUserRow(updated.id);
    if (rawRow != null) {
      unawaited(RemoteSyncService.updatePasswordInCloud(
        userId: updated.id,
        passwordHash: (rawRow['password_hash'] as String?) ?? '',
        sessionToken: rawRow['session_token'] as String?,
        passwordChangedAt: rawRow['password_changed_at'] as String?,
      ));
    }

    return null; // success
  }

  // ---------------- Email Verification ----------------

  /// Generates a 6-digit email-verification code, stores it in
  /// [_verificationCodes] (valid for 10 minutes), and attempts to deliver
  /// it via [EmailService].
  ///
  /// Returns `null` on success, or an error string on failure.
  Future<String?> sendVerificationCode(String email) async {
    final emailErr = Validators.validateEmail(email);
    if (emailErr != null) return emailErr;

    final lookup = _emailLookup(email);
    final rand = Random.secure();
    final code = (100000 + rand.nextInt(900000)).toString();

    _verificationCodes[lookup] = _RecoveryCode(
      code,
      DateTime.now().add(const Duration(minutes: 10)),
    );

    // Try to send email (non-blocking — code is still valid if email fails).
    unawaited(EmailService.sendVerificationEmail(email, code));

    return null; // success
  }

  /// Verifies [code] against the stored email-verification code for [email].
  /// On success, sets `email_verified = 1` in the database and updates the
  /// local session, then clears the pending code.
  ///
  /// Returns `null` on success, or an error string on failure.
  Future<String?> verifyEmailCode(String email, String code) async {
    final lookup = _emailLookup(email);
    final stored = _verificationCodes[lookup];

    if (stored == null) {
      return _l10n.authNoVerificationCodePending;
    }
    if (stored.isExpired) {
      _verificationCodes.remove(lookup);
      return _l10n.authCodeExpired;
    }
    if (stored.code != code.trim()) {
      return _l10n.authInvalidVerificationCode;
    }

    // Mark the account as email-verified in the DB.
    final user = await DatabaseService.findUserByEmailLookup(lookup);
    if (user != null) {
      final updated = user.copyWith(emailVerified: true);
      await DatabaseService.updateUser(updated);

      // Sync email_verified to cloud — this field is excluded from the
      // live-write ON DUPLICATE KEY UPDATE clause, so an explicit call is needed.
      unawaited(RemoteSyncService.updateEmailVerifiedInCloud(user.id));

      // If this is the currently logged-in user, refresh the session.
      final current = StorageService.currentUser;
      if (current != null && current.id == user.id) {
        await StorageService.setCurrentSession(
            updated, user.sessionToken ?? '');
        await EncryptionService.initFromEnv(updated.email);
      }
    }

    // Clear the used verification code.
    _verificationCodes.remove(lookup);

    return null; // success
  }

  // ----------------------------------------------------------------

  String _emailLookup(String email) =>
      DatabaseService.lookupHashForEmail(email);
}

final effectivePlanProvider = FutureProvider<String>((ref) async {
  ref.watch(authProvider);
  return StorageService.getEffectivePlan();
});

final authProvider = StateNotifierProvider<AuthNotifier, AuthState>((ref) {
  return AuthNotifier(ref);
});

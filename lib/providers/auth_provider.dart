import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:sign_in_with_apple/sign_in_with_apple.dart';
import 'package:uuid/uuid.dart';

import '../core/utils/validators.dart';
import '../models/contact.dart';
import '../models/user_account.dart';
import '../services/database_service.dart';
import '../services/email_service.dart';
import '../services/encryption_service.dart';
import '../services/photo_storage_service.dart';
import '../services/remote_sync_service.dart';
import '../services/storage_service.dart';

const _uuid = Uuid();

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

  /// Current subscription plan: 'free' | 'premium' | 'business'.
  final String plan;

  const AuthState({
    this.isLoggedIn = false,
    this.isLoading = false,
    this.userName = '',
    this.userEmail = '',
    this.userPhotoPath,
    this.error,
    this.plan = 'free',
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
    String? plan,
  }) {
    return AuthState(
      isLoggedIn: isLoggedIn ?? this.isLoggedIn,
      isLoading: isLoading ?? this.isLoading,
      userName: userName ?? this.userName,
      userEmail: userEmail ?? this.userEmail,
      userPhotoPath: clearPhoto ? null : (userPhotoPath ?? this.userPhotoPath),
      error: clearError ? null : (error ?? this.error),
      plan: plan ?? this.plan,
    );
  }
}

class AuthNotifier extends StateNotifier<AuthState> {
  AuthNotifier()
      : super(AuthState(
          isLoggedIn: StorageService.isLoggedIn,
          userName: StorageService.userName,
          userEmail: StorageService.userEmail,
          userPhotoPath: StorageService.currentUser?.photoPath,
          plan: StorageService.currentUser?.plan ?? 'free',
        ));

  // ---------------- Email login ----------------

  Future<bool> login(String email, String password) async {
    state = state.copyWith(isLoading: true, clearError: true);

    final emailErr = Validators.validateEmail(email);
    if (emailErr != null) {
      state = state.copyWith(isLoading: false, error: emailErr);
      return false;
    }

    final lookup = _emailLookup(email);
    var user = await DatabaseService.findUserByEmailLookup(lookup);
    var importedFromCloud = false;

    if (user == null) {
      // No local account — try the cloud database.
      importedFromCloud =
          await RemoteSyncService.importUserByEmailLookup(lookup);
      if (importedFromCloud) {
        user = await DatabaseService.findUserByEmailLookup(lookup);
      }
      if (user == null) {
        state = state.copyWith(
          isLoading: false,
          error: 'Aucun compte trouvé pour cet email',
        );
        return false;
      }
    }

    if (user.authProvider != 'email') {
      state = state.copyWith(
        isLoading: false,
        error:
            'Ce compte utilise ${user.authProvider == 'google' ? 'Google' : 'Apple'}. Connectez-vous via ce service.',
      );
      return false;
    }

    if (!EncryptionService.verifyPassword(password, user.passwordHash)) {
      state = state.copyWith(
        isLoading: false,
        error: 'Email ou mot de passe incorrect',
      );
      return false;
    }

    // If the email has not been verified yet, send a verification code and
    // block login until verification is complete.
    if (!user.emailVerified) {
      await sendVerificationCode(email);
      state = state.copyWith(
        isLoading: false,
        error: 'Veuillez vérifier votre email. Un code a été envoyé à $email.',
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

    state = state.copyWith(
      isLoggedIn: true,
      isLoading: false,
      userName: updated.fullName,
      userEmail: updated.email,
      plan: updated.plan,
      clearError: true,
    );

    // When the user record was pulled from the cloud, bring their data too.
    if (importedFromCloud) {
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
          error: 'Une connexion internet est requise pour créer un compte',
        );
        return false;
      }
    }

    if (firstName.trim().isEmpty || lastName.trim().isEmpty) {
      state = state.copyWith(
        isLoading: false,
        error: 'Prénom et nom sont obligatoires',
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
        error: 'Un compte existe déjà pour cet email',
      );
      return false;
    }

    // Also check the cloud database — an account registered on another device
    // would not appear in the local DB.
    final emailLookup = DatabaseService.lookupHashForEmail(email.trim());
    if (await RemoteSyncService.isEmailTakenInCloud(emailLookup)) {
      state = state.copyWith(
        isLoading: false,
        error: 'Un compte existe déjà pour cet email',
      );
      return false;
    }

    if (phone != null &&
        phone.trim().isNotEmpty &&
        await DatabaseService.isPhoneTaken(phone)) {
      state = state.copyWith(
        isLoading: false,
        error: 'Un compte existe déjà pour ce numéro de téléphone',
      );
      return false;
    }

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
        : "Données introuvables après l'insertion locale";
    if (cloudErr != null) {
      // Roll back the local insert and clean up any partial cloud write.
      await DatabaseService.deleteUserAndAllData(user.id);
      unawaited(RemoteSyncService.deleteUserFromCloud(user.id));
      state = state.copyWith(
        isLoading: false,
        error: 'Impossible de créer le compte. Veuillez réessayer.',
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
      final google = GoogleSignIn(
          scopes: ['email'],
          serverClientId:
              '772969451694-npt8ctok5nbm0g6sl6t7ttmn6q7cbgqb.apps.googleusercontent.com');
      final account = await google.signIn();
      if (account == null) {
        state = state.copyWith(isLoading: false);
        return false;
      }
      return _upsertOAuthUser(
        email: account.email,
        firstName: account.displayName?.split(' ').first ?? 'User',
        lastName: account.displayName?.split(' ').skip(1).join(' ') ?? '',
        provider: 'google',
      );
    } catch (e) {
      state = state.copyWith(
        isLoading: false,
        error: 'Connexion Google échouée: ${e.toString()}',
      );
      return false;
    }
  }

  // ---------------- Apple sign-in ----------------

  Future<bool> signInWithApple() async {
    state = state.copyWith(isLoading: true, clearError: true);
    try {
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
          error: 'Apple n\'a pas fourni d\'email',
        );
        return false;
      }
      return _upsertOAuthUser(
        email: email,
        firstName: credential.givenName ?? 'User',
        lastName: credential.familyName ?? '',
        provider: 'apple',
      );
    } catch (e) {
      state = state.copyWith(
        isLoading: false,
        error: 'Connexion Apple échouée: ${e.toString()}',
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
    final lookup = _emailLookup(email);
    var user = await DatabaseService.findUserByEmailLookup(lookup);
    final token = EncryptionService.generateSessionToken();

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
    } else {
      if (user.authProvider != provider) {
        state = state.copyWith(
          isLoading: false,
          error: 'Cet email est déjà associé à un compte ${user.authProvider}.',
        );
        return false;
      }
      user = user.copyWith(sessionToken: token, lastLoginAt: DateTime.now());
      await DatabaseService.updateUser(user);
    }

    await StorageService.setCurrentSession(user, token);
    state = state.copyWith(
      isLoggedIn: true,
      isLoading: false,
      userName: user.fullName,
      userEmail: user.email,
      plan: user.plan,
      clearError: true,
    );
    return true;
  }

  // ---------------- Plan management ----------------

  /// Switches the current user's subscription plan, persists it to the database,
  /// and updates the in-memory session so every Riverpod listener is notified.
  ///
  /// Returns `null` on success, or an error string on failure.
  Future<String?> changePlan(String plan) async {
    final user = StorageService.currentUser;
    if (user == null) return 'Aucun utilisateur connecté';
    if (!['free', 'premium', 'business'].contains(plan)) {
      return 'Forfait invalide';
    }
    final updated = user.copyWith(plan: plan);
    await DatabaseService.updateUser(updated);
    await StorageService.setCurrentSession(updated, user.sessionToken ?? '');
    state = state.copyWith(plan: plan);
    return null;
  }

  // ---------------- Logout ----------------

  Future<void> logout() async {
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
    if (user == null) return 'Aucun utilisateur connecté';

    // Require internet — account must be erased from both databases.
    if (!kIsWeb) {
      final connectivity = await Connectivity().checkConnectivity();
      if (connectivity.contains(ConnectivityResult.none)) {
        return 'Une connexion internet est requise pour supprimer votre compte';
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
            return "Supprimez ou transférez l'administration de l'organisation avant de supprimer votre compte.";
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
          if (cloudErr != null)
            debugPrint('deleteAccount cloud error: $cloudErr');
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
      return 'Erreur lors de la suppression : $e';
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
    if (user == null) return 'Aucun utilisateur connecté';

    if (user.authProvider != 'email') {
      return 'Mot de passe non modifiable pour les comptes ${user.authProvider}';
    }

    if (!EncryptionService.verifyPassword(currentPassword, user.passwordHash)) {
      return 'Mot de passe actuel incorrect';
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
    if (user == null) return 'Aucun utilisateur connecté';

    if (user.authProvider != 'email') {
      return 'Email non modifiable pour les comptes ${user.authProvider}';
    }

    // Validate new email format.
    final emailErr = Validators.validateEmail(newEmail);
    if (emailErr != null) return emailErr;

    // Check current password.
    if (!EncryptionService.verifyPassword(currentPassword, user.passwordHash)) {
      return 'Mot de passe actuel incorrect';
    }

    // Disallow changing to an email already in use by another account —
    // check both the local database and the cloud database.
    final newLookup = _emailLookup(newEmail);
    final existing = await DatabaseService.findUserByEmailLookup(newLookup);
    if (existing != null && existing.id != user.id) {
      return 'Cet email est déjà utilisé par un autre compte';
    }
    final cloudOwnerId =
        await RemoteSyncService.findCloudUserIdByEmailLookup(newLookup);
    if (cloudOwnerId != null && cloudOwnerId != user.id) {
      return 'Cet email est déjà utilisé par un autre compte';
    }

    // Verify the 6-digit code sent to the new address.
    final stored = _verificationCodes[newLookup];
    if (stored == null) {
      return 'Aucun code de vérification en attente. Veuillez en demander un nouveau.';
    }
    if (stored.isExpired) {
      _verificationCodes.remove(newLookup);
      return 'Le code a expiré. Veuillez en demander un nouveau.';
    }
    if (stored.code != code.trim()) {
      return 'Code de vérification invalide';
    }

    // Rotate session token (invalidates other devices) and persist.
    final newToken = EncryptionService.generateSessionToken();
    final updated = user.copyWith(
      email: newEmail.trim(),
      sessionToken: newToken,
      emailVerified: true,
    );
    await DatabaseService.updateUser(updated);
    await StorageService.setCurrentSession(updated, newToken);
    state = state.copyWith(userEmail: newEmail.trim());

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
      final imported = await RemoteSyncService.importUserByEmailLookup(lookup);
      if (imported) user = await DatabaseService.findUserByEmailLookup(lookup);
      if (user == null) return 'Aucun compte associé à cet email';
    }

    if (user.authProvider != 'email') {
      return 'Ce compte utilise ${user.authProvider == 'google' ? 'Google' : 'Apple'}. '
          'La récupération par code n\'est pas disponible pour ce type de compte.';
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
      return 'Aucun code de récupération en attente. Veuillez en demander un nouveau.';
    }
    if (stored.isExpired) {
      _recoveryCodes.remove(lookup);
      return 'Le code a expiré. Veuillez en demander un nouveau.';
    }
    if (stored.code != code.trim()) {
      return 'Code de récupération invalide';
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
    if (user == null) return 'Aucun compte associé à cet email';

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
      return 'Aucun code de vérification en attente. Veuillez en demander un nouveau.';
    }
    if (stored.isExpired) {
      _verificationCodes.remove(lookup);
      return 'Le code a expiré. Veuillez en demander un nouveau.';
    }
    if (stored.code != code.trim()) {
      return 'Code de vérification invalide';
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

final authProvider = StateNotifierProvider<AuthNotifier, AuthState>((ref) {
  return AuthNotifier();
});

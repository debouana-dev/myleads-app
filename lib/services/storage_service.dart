import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../models/contact.dart';
import '../models/interaction.dart';
import '../models/reminder.dart';
import '../models/user_account.dart';
import 'database_service.dart';
import 'encryption_service.dart';
import 'photo_storage_service.dart';

/// High-level storage facade combining secure key/value storage for
/// session/preferences and the encrypted SQLite database for entities.
class StorageService {
  static const _secure = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
    iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock),
  );

  // Session keys
  static const _kCurrentUserId = 'current_user_id';
  static const _kCurrentUserEmail = 'current_user_email';
  static const _kCurrentSessionToken = 'current_session_token';
  static const _kHasOnboarded = 'has_onboarded';
  static const _kUserPlan = 'user_plan';

  static UserAccount? _cachedUser;

  static Future<void> init() async {
    //await EncryptionService.init();
    // Cache the platform documents directory for cross-platform photo paths.
    await PhotoStorageService.init();
    // Open the database eagerly so the first query is fast.
    await DatabaseService.database;

    // Load cached user if a session exists.
    final userId = await _secure.read(key: _kCurrentUserId);
    final email = await _secure.read(key: _kCurrentUserEmail);
    final token = await _secure.read(key: _kCurrentSessionToken);
    if (userId != null && token != null && email != null) {
      // Initialize encryption for the restored session
      await EncryptionService.initFromEnv(email);
      final user = await DatabaseService.findUserById(userId);
      if (user != null && user.sessionToken == token) {
        _cachedUser = user;
      } else {
        // Stale or invalidated session — wipe it.
        await _secure.delete(key: _kCurrentUserId);
        await _secure.delete(key: _kCurrentSessionToken);
      }
    }
  }

  // -------- Session --------

  static UserAccount? get currentUser => _cachedUser;
  static bool get isLoggedIn => _cachedUser != null;
  static String get currentUserId => _cachedUser?.id ?? '';
  static String get userName => _cachedUser?.fullName ?? '';
  static String get userEmail => _cachedUser?.email ?? '';

  static Future<void> setCurrentSession(UserAccount user, String token) async {
    _cachedUser = user.copyWith(sessionToken: token);
    await _secure.write(key: _kCurrentUserId, value: user.id);
    await _secure.write(key: _kCurrentUserEmail, value: user.email);
    await _secure.write(key: _kCurrentSessionToken, value: token);
  }

  static Future<void> clearSession() async {
    _cachedUser = null;
    await _secure.delete(key: _kCurrentUserId);
    await _secure.delete(key: _kCurrentUserEmail);
    await _secure.delete(key: _kCurrentSessionToken);
  }

  static Future<bool> get hasCompletedOnboarding async =>
      (await _secure.read(key: _kHasOnboarded)) == 'true';

  static Future<void> setHasCompletedOnboarding(bool value) async {
    await _secure.write(key: _kHasOnboarded, value: value.toString());
  }

  /// Current user's subscription plan, read directly from the cached user row.
  /// Falls back to 'free' when no session is active.
  static String get userPlan => _cachedUser?.plan ?? 'free';

  /// Effective plan: 'business' if the user belongs to an active organization,
  /// otherwise the stored personal subscription plan.
  static Future<String> getEffectivePlan() async {
    final user = _cachedUser;
    if (user == null) return 'free';
    if (user.organizationId != null &&
        await DatabaseService.isUserAssignedToOrganization(user.id) &&
        await DatabaseService.isOrganizationActive(user.organizationId!)) {
      return 'business';
    }
    return user.plan;
  }

  /// Kept for backwards-compatibility. Plan changes should go through
  /// [AuthNotifier.changePlan], which persists to the database.
  static Future<void> setUserPlan(String plan) async {
    await _secure.write(key: _kUserPlan, value: plan);
  }

  // -------- Contacts --------

  static Future<List<Contact>> getAllContacts() async {
    if (_cachedUser == null) return [];
    return DatabaseService.getAllContactsForOwner(_cachedUser!.id);
  }

  static Future<void> saveContact(Contact contact) async {
    final existing = await DatabaseService.findContactById(contact.id);
    if (existing == null) {
      await DatabaseService.insertContact(contact);
    } else {
      await DatabaseService.updateContact(contact);
    }
  }

  static Future<void> deleteContact(String id) async {
    await DatabaseService.deleteContact(id);
  }

  // -------- Reminders --------

  static Future<List<Reminder>> getAllReminders() async {
    if (_cachedUser == null) return [];
    return DatabaseService.getAllRemindersForOwner(_cachedUser!.id);
  }

  static Future<void> saveReminder(Reminder reminder) async {
    final db = await DatabaseService.database;
    final existing = await db.query('reminders',
        where: 'id = ?', whereArgs: [reminder.id], limit: 1);
    if (existing.isEmpty) {
      await DatabaseService.insertReminder(reminder);
    } else {
      await DatabaseService.updateReminder(reminder);
    }
  }

  static Future<void> deleteReminder(String id) async {
    await DatabaseService.deleteReminder(id);
  }

  // -------- Interactions --------

  static Future<List<Interaction>> getInteractionsForContact(
      String contactId) async {
    return DatabaseService.getInteractionsForContact(contactId);
  }

  static Future<void> saveInteraction(Interaction interaction) async {
    await DatabaseService.insertInteraction(interaction);
  }
}

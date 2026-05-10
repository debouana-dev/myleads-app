import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:timezone/data/latest_all.dart' as tz;
import 'package:timezone/timezone.dart' as tz;

import '../models/app_notification.dart';
import '../models/contact.dart';
import '../models/reminder.dart';
import '../services/database_service.dart';
import '../services/storage_service.dart';

/// Handles both device push notifications (flutter_local_notifications) and
/// in-app notification records persisted in the local SQLite database.
///
/// Push notifications are scheduled via [zonedSchedule] so they fire at the
/// correct wall-clock time even when the app is backgrounded or closed.
/// Cancellation is performed whenever a reminder is completed or deleted.
class NotificationService {
  static final _plugin = FlutterLocalNotificationsPlugin();

  static const _chHighId = 'myleads_high';
  static const _chMediumId = 'myleads_medium';
  static const _chLowId = 'myleads_low';
  static const _chPaymentId = 'myleads_payment';

  // Fixed ID for the one-at-a-time payment-in-progress notification.
  static const _kPaymentNotifId = 9000001;

  static bool _initialized = false;

  // -----------------------------------------------------------------------
  // Init
  // -----------------------------------------------------------------------

  static Future<void> init() async {
    if (_initialized || kIsWeb) return;

    // Load timezone database and pin to device locale.
    tz.initializeTimeZones();
    try {
      final localTz = await FlutterTimezone.getLocalTimezone();
      tz.setLocalLocation(tz.getLocation(localTz.identifier));
    } catch (_) {
      // Fall back to UTC if the timezone lookup fails (e.g. simulator edge cases).
    }

    const android = AndroidInitializationSettings('@mipmap/ic_launcher');
    const ios = DarwinInitializationSettings(
      requestAlertPermission: true,
      requestBadgePermission: true,
      requestSoundPermission: true,
    );
    await _plugin.initialize(
      const InitializationSettings(android: android, iOS: ios),
    );

    // Android notification channels
    final androidImpl = _plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    await androidImpl?.createNotificationChannel(
      const AndroidNotificationChannel(
        _chHighId,
        'Rappels urgents',
        description: 'Rappels très importants',
        importance: Importance.high,
      ),
    );
    await androidImpl?.createNotificationChannel(
      const AndroidNotificationChannel(
        _chMediumId,
        'Rappels importants',
        description: 'Rappels importants',
        importance: Importance.defaultImportance,
      ),
    );
    await androidImpl?.createNotificationChannel(
      const AndroidNotificationChannel(
        _chLowId,
        'Rappels',
        description: 'Rappels normaux et alertes contacts',
        importance: Importance.low,
      ),
    );
    await androidImpl?.createNotificationChannel(
      const AndroidNotificationChannel(
        _chPaymentId,
        'Paiements',
        description: 'Statut du paiement en cours',
        importance: Importance.low,
        playSound: false,
        enableVibration: false,
      ),
    );

    // Request POST_NOTIFICATIONS permission on Android 13+.
    // Permission.notification is a no-op on Android < 13 and non-Android.
    try {
      await Permission.notification.request();
    } catch (_) {}

    _initialized = true;
  }

  // -----------------------------------------------------------------------
  // Deterministic push IDs  (must be stable for cancel to work)
  // -----------------------------------------------------------------------

  static int _upcomingPushId(String reminderId) =>
      'upcoming_$reminderId'.hashCode.abs() % 1000000;

  static int _overduePushId(String reminderId) =>
      'overdue_$reminderId'.hashCode.abs() % 1000000;

  static int _incompletePushId(String contactId) =>
      'incomplete_$contactId'.hashCode.abs() % 1000000;

  // -----------------------------------------------------------------------
  // Internal push helpers
  // -----------------------------------------------------------------------

  static NotificationDetails _detailsForPriority(String priority) {
    final AndroidNotificationDetails android;
    switch (priority) {
      case 'very_important':
        android = const AndroidNotificationDetails(
          _chHighId,
          'Rappels urgents',
          importance: Importance.high,
          priority: Priority.high,
        );
        break;
      case 'important':
        android = const AndroidNotificationDetails(
          _chMediumId,
          'Rappels importants',
          importance: Importance.defaultImportance,
          priority: Priority.defaultPriority,
        );
        break;
      default:
        android = const AndroidNotificationDetails(
          _chLowId,
          'Rappels',
          importance: Importance.low,
          priority: Priority.low,
        );
    }
    return NotificationDetails(
        android: android, iOS: const DarwinNotificationDetails());
  }

  // -----------------------------------------------------------------------
  // Payment-in-progress notification
  // -----------------------------------------------------------------------

  /// Shows a persistent, non-dismissible notification while a Stripe redirect
  /// payment (Link, Amazon Pay, bank redirect) is open in an external browser.
  ///
  /// Keeping a visible notification raises this process's priority in Android's
  /// LMK (Low Memory Killer) table so it survives while Chrome Custom Tabs is
  /// in the foreground. Call [dismissPaymentProgressNotification] when the
  /// payment flow completes or is cancelled.
  static Future<void> showPaymentProgressNotification() async {
    if (kIsWeb || !_initialized) return;
    try {
      const android = AndroidNotificationDetails(
        _chPaymentId,
        'Paiements',
        channelDescription: 'Statut du paiement en cours',
        importance: Importance.low,
        priority: Priority.low,
        ongoing: true,
        autoCancel: false,
        playSound: false,
        enableVibration: false,
        icon: '@mipmap/ic_launcher',
      );
      await _plugin.show(
        _kPaymentNotifId,
        'Paiement en cours…',
        'Ne fermez pas l\'application. Revenez ici une fois le paiement terminé.',
        const NotificationDetails(
            android: android, iOS: DarwinNotificationDetails()),
      );
    } catch (_) {}
  }

  /// Cancels the payment-in-progress notification posted by
  /// [showPaymentProgressNotification].
  static Future<void> dismissPaymentProgressNotification() async {
    if (kIsWeb || !_initialized) return;
    try {
      await _plugin.cancel(_kPaymentNotifId);
    } catch (_) {}
  }

  /// Show a push notification immediately.
  static Future<void> _sendPush({
    required int id,
    required String title,
    required String body,
    required String priority,
  }) async {
    if (kIsWeb || !_initialized) return;
    try {
      await _plugin.show(id, title, body, _detailsForPriority(priority));
    } catch (_) {}
  }

  /// Schedule a push notification at [scheduledAt] (local wall-clock time).
  /// Uses [AndroidScheduleMode.inexactAllowWhileIdle] — no SCHEDULE_EXACT_ALARM
  /// permission needed; the notification fires approximately on time even in Doze.
  static Future<void> _schedulePush({
    required int id,
    required String title,
    required String body,
    required String priority,
    required DateTime scheduledAt,
  }) async {
    if (kIsWeb || !_initialized) return;
    try {
      final tzScheduled = tz.TZDateTime(
        tz.local,
        scheduledAt.year,
        scheduledAt.month,
        scheduledAt.day,
        scheduledAt.hour,
        scheduledAt.minute,
        scheduledAt.second,
      );
      await _plugin.zonedSchedule(
        id,
        title,
        body,
        tzScheduled,
        _detailsForPriority(priority),
        androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
        uiLocalNotificationDateInterpretation:
            UILocalNotificationDateInterpretation.absoluteTime,
      );
    } catch (_) {}
  }

  // -----------------------------------------------------------------------
  // Internal: persist an in-app notification (deduplication by id)
  // -----------------------------------------------------------------------

  static Future<void> _persistIfNew(AppNotification n) async {
    final exists = await DatabaseService.notificationExists(n.id);
    if (!exists) {
      await DatabaseService.insertNotification(n);
    }
  }

  // -----------------------------------------------------------------------
  // Public API — upcoming reminder push (15 min before start)
  // -----------------------------------------------------------------------

  /// Call whenever a reminder is created or updated.
  ///
  /// Persists the in-app record immediately and (re-)schedules the device
  /// push so it fires 15 minutes before [reminder.startDateTime].
  /// Any previously scheduled push for the same reminder is cancelled first
  /// so stale alarms don't accumulate.
  static Future<void> scheduleReminderUpcoming(Reminder reminder) async {
    final ownerId = StorageService.currentUserId;
    if (ownerId.isEmpty) return;

    final scheduledAt =
        reminder.startDateTime.subtract(const Duration(minutes: 15));
    final now = DateTime.now();

    final title = 'Rappel dans 15 min';
    final body = reminder.note.isNotEmpty
        ? reminder.note
        : 'Rappel prévu à ${_formatTime(reminder.startDateTime)}';

    // Persist in-app notification (visible to the screen only at scheduledAt).
    await _persistIfNew(AppNotification(
      id: 'upcoming_${reminder.id}',
      ownerId: ownerId,
      type: 'reminder_upcoming',
      title: title,
      body: body,
      scheduledAt: scheduledAt,
      createdAt: now,
      referenceId: reminder.id,
    ));

    // Cancel any stale scheduled push before (re-)registering.
    final pushId = _upcomingPushId(reminder.id);
    if (!kIsWeb && _initialized) {
      try {
        await _plugin.cancel(pushId);
      } catch (_) {}
    }

    if (scheduledAt.isAfter(now)) {
      // Future reminder — schedule the push via the OS alarm manager.
      await _schedulePush(
        id: pushId,
        title: title,
        body: body,
        priority: reminder.priority,
        scheduledAt: scheduledAt,
      );
    } else if (reminder.startDateTime.isAfter(now)) {
      // Between scheduledAt and startDateTime (0–15 min window) — fire now.
      await _sendPush(
          id: pushId, title: title, body: body, priority: reminder.priority);
    }
    // Both times are past → no push needed (reminder is already overdue).
  }

  // -----------------------------------------------------------------------
  // Public API — overdue reminder push (4+ hours past deadline)
  // -----------------------------------------------------------------------

  static Future<void> createOverdueReminderNotification(
      Reminder reminder) async {
    final ownerId = StorageService.currentUserId;
    if (ownerId.isEmpty) return;

    final notifId = 'overdue_${reminder.id}';
    final deadline = reminder.endDateTime ?? reminder.startDateTime;
    final scheduledAt = deadline.add(const Duration(hours: 4));
    final now = DateTime.now();

    final title = 'Rappel en retard';
    final body = reminder.note.isNotEmpty
        ? reminder.note
        : 'Rappel du ${_formatDate(deadline)} non effectué';

    final existed = await DatabaseService.notificationExists(notifId);
    await _persistIfNew(AppNotification(
      id: notifId,
      ownerId: ownerId,
      type: 'reminder_overdue',
      title: title,
      body: body,
      scheduledAt: scheduledAt,
      createdAt: now,
      referenceId: reminder.id,
    ));

    // Only schedule/show the push the first time we create this record.
    if (!existed) {
      final pushId = _overduePushId(reminder.id);
      if (scheduledAt.isAfter(now)) {
        await _schedulePush(
          id: pushId,
          title: title,
          body: body,
          priority: reminder.priority,
          scheduledAt: scheduledAt,
        );
      } else {
        await _sendPush(
            id: pushId, title: title, body: body, priority: reminder.priority);
      }
    }
  }

  // -----------------------------------------------------------------------
  // Public API — incomplete hot/warm contact push (3+ days after creation)
  // -----------------------------------------------------------------------

  static Future<void> createIncompleteContactNotification(
      Contact contact) async {
    final ownerId = StorageService.currentUserId;
    if (ownerId.isEmpty) return;
    if (contact.status != 'hot' && contact.status != 'warm') return;

    final missingFields = _missingFields(contact);
    if (missingFields.isEmpty) return;

    final notifId = 'incomplete_${contact.id}';
    final label = contact.status == 'hot' ? 'HOT' : 'WARM';
    final title = 'Profil $label incomplet';
    final body =
        '${contact.fullName} — champs manquants : ${missingFields.join(', ')}';
    final scheduledAt = contact.createdAt.add(const Duration(days: 3));
    final now = DateTime.now();
    final priority = contact.status == 'hot' ? 'important' : 'normal';

    final existed = await DatabaseService.notificationExists(notifId);
    await _persistIfNew(AppNotification(
      id: notifId,
      ownerId: ownerId,
      type: 'contact_incomplete',
      title: title,
      body: body,
      scheduledAt: scheduledAt,
      createdAt: now,
      referenceId: contact.id,
    ));

    if (!existed) {
      final pushId = _incompletePushId(contact.id);
      if (scheduledAt.isAfter(now)) {
        await _schedulePush(
          id: pushId,
          title: title,
          body: body,
          priority: priority,
          scheduledAt: scheduledAt,
        );
      } else {
        await _sendPush(
            id: pushId, title: title, body: body, priority: priority);
      }
    }
  }

  // -----------------------------------------------------------------------
  // Public API — schedule both upcoming + overdue pushes for a reminder
  // -----------------------------------------------------------------------

  /// Call on every reminder create/update.
  ///
  /// Schedules the upcoming push (15 min before start) and — crucially —
  /// also pre-schedules the overdue push (4 h after the deadline) so it
  /// fires even when the app is closed. Any previously registered overdue
  /// push is cancelled and its in-app record removed first so that a
  /// changed deadline is always honoured.
  static Future<void> scheduleAllReminderNotifications(
      Reminder reminder) async {
    if (reminder.isCompleted) return;

    // Re-schedule upcoming push (cancels stale alarm internally).
    await scheduleReminderUpcoming(reminder);

    // Reset the overdue push so an updated end-time takes effect.
    final overdueNotifId = 'overdue_${reminder.id}';
    if (!kIsWeb && _initialized) {
      try {
        await _plugin.cancel(_overduePushId(reminder.id));
      } catch (_) {}
    }
    final exists = await DatabaseService.notificationExists(overdueNotifId);
    if (exists) {
      await DatabaseService.deleteNotification(overdueNotifId);
    }

    // Re-create (and schedule) the overdue push for the current deadline.
    await createOverdueReminderNotification(reminder);
  }

  // -----------------------------------------------------------------------
  // Public API — cancel all scheduled pushes for a reminder
  // -----------------------------------------------------------------------

  /// Must be called when a reminder is deleted or marked complete so stale
  /// OS-level alarms don't fire after the fact.
  static Future<void> cancelReminderScheduledNotification(
      String reminderId) async {
    if (kIsWeb || !_initialized) return;
    try {
      await _plugin.cancel(_upcomingPushId(reminderId));
      await _plugin.cancel(_overduePushId(reminderId));
    } catch (_) {}
  }

  // -----------------------------------------------------------------------
  // Periodic check — run on app resume and provider refresh
  // -----------------------------------------------------------------------

  /// Scans all active reminders and hot/warm contacts, creates any missing
  /// in-app notification records, and (re-)schedules device pushes.
  ///
  /// This covers two scenarios:
  /// 1. A device reboot clears all pending OS alarms — this call re-registers them.
  /// 2. Newly overdue reminders get their overdue notification created.
  static Future<void> runPeriodicCheck({
    required List<Reminder> reminders,
    required List<Contact> contacts,
  }) async {
    final ownerId = StorageService.currentUserId;
    if (ownerId.isEmpty) return;

    final now = DateTime.now();

    // Upcoming reminder pushes (15 min before start)
    for (final r in reminders) {
      if (r.isCompleted) continue;
      await scheduleReminderUpcoming(r);
    }

    // Overdue reminder pushes (4+ hours past deadline)
    for (final r in reminders) {
      if (r.isCompleted) continue;
      final deadline = r.endDateTime ?? r.startDateTime;
      if (now.isAfter(deadline.add(const Duration(hours: 4)))) {
        await createOverdueReminderNotification(r);
      }
    }

    // Incomplete hot/warm contact pushes (3+ days after creation)
    for (final c in contacts) {
      if (c.status != 'hot' && c.status != 'warm') continue;
      if (now.isAfter(c.createdAt.add(const Duration(days: 3)))) {
        await createIncompleteContactNotification(c);
      }
    }
  }

  // -----------------------------------------------------------------------
  // Helpers
  // -----------------------------------------------------------------------

  static List<String> _missingFields(Contact c) {
    final missing = <String>[];
    if (c.phone == null || c.phone!.trim().isEmpty) missing.add('téléphone');
    if (c.email == null || c.email!.trim().isEmpty) missing.add('email');
    if (c.company == null || c.company!.trim().isEmpty)
      missing.add('entreprise');
    if (c.jobTitle == null || c.jobTitle!.trim().isEmpty) missing.add('poste');
    if (c.notes == null || c.notes!.trim().isEmpty) missing.add('notes');
    if (c.interest == null || c.interest!.trim().isEmpty)
      missing.add('intérêt');
    if (c.source == null || c.source!.trim().isEmpty) missing.add('source');
    return missing;
  }

  static String _formatTime(DateTime dt) =>
      '${dt.hour.toString().padLeft(2, '0')}h${dt.minute.toString().padLeft(2, '0')}';

  static String _formatDate(DateTime dt) =>
      '${dt.day.toString().padLeft(2, '0')}/${dt.month.toString().padLeft(2, '0')}/${dt.year}';
}

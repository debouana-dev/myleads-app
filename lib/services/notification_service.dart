import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:timezone/data/latest_all.dart' as tz;
import 'package:timezone/timezone.dart' as tz;

import '../models/app_notification.dart';
import '../models/app_task.dart';
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

  // Number of future repeat occurrences pre-scheduled per reminder.
  // Kept at 20 to stay under iOS's 64 system notification ceiling.
  static const _kMaxRepeatSlots = 20;

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
        description: 'Rappels très importants (Alarme)',
        importance: Importance.max, // Max importance for alarms
        enableVibration: true,
        playSound: true,
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

  static int _onTimePushId(String reminderId) =>
      'ontime_$reminderId'.hashCode.abs() % 1000000;

  static int _overduePushId(String reminderId) =>
      'overdue_$reminderId'.hashCode.abs() % 1000000;

  static int _incompletePushId(String contactId) =>
      'incomplete_$contactId'.hashCode.abs() % 1000000;

  static int _subEarlyPushId(String userId) =>
      'sub_early_$userId'.hashCode.abs() % 1000000;

  static int _subMidPushId(String userId) =>
      'sub_mid_$userId'.hashCode.abs() % 1000000;

  static int _subLastPushId(String userId) =>
      'sub_last_$userId'.hashCode.abs() % 1000000;

  static int _repeatPushId(String reminderId, int i) =>
      'repeat_${reminderId}_$i'.hashCode.abs() % 1000000;

  // Task push IDs — use 'task_' prefix to avoid colliding with reminder IDs.
  static int _taskUpcomingPushId(String taskId) =>
      'task_upcoming_$taskId'.hashCode.abs() % 1000000;
  static int _taskOnTimePushId(String taskId) =>
      'task_ontime_$taskId'.hashCode.abs() % 1000000;
  static int _taskOverduePushId(String taskId) =>
      'task_overdue_$taskId'.hashCode.abs() % 1000000;
  static int _taskRepeatPushId(String taskId, int i) =>
      'task_repeat_${taskId}_$i'.hashCode.abs() % 1000000;

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
          importance: Importance.max,
          priority: Priority.max,
          fullScreenIntent: true, // Try to show full screen if possible (alarm style)
          category: AndroidNotificationCategory.alarm,
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

  /// Schedules a push notification exactly at [reminder.startDateTime].
  /// This acts as the "alarm" for the reminder.
  static Future<void> scheduleReminderOnTime(Reminder reminder) async {
    final ownerId = StorageService.currentUserId;
    if (ownerId.isEmpty) return;

    final scheduledAt = reminder.startDateTime;
    final now = DateTime.now();

    final title = 'Me2Leads : Rappel maintenant !';
    final body = reminder.note.isNotEmpty ? reminder.note : 'C\'est le moment de votre tâche.';

    await _persistIfNew(AppNotification(
      id: 'ontime_${reminder.id}',
      ownerId: ownerId,
      type: 'reminder_ontime',
      title: title,
      body: body,
      scheduledAt: scheduledAt,
      createdAt: now,
      referenceId: reminder.id,
    ));

    final pushId = _onTimePushId(reminder.id);
    if (!kIsWeb && _initialized) {
      try {
        await _plugin.cancel(pushId);
      } catch (_) {}
    }

    if (scheduledAt.isAfter(now)) {
      await _schedulePush(
        id: pushId,
        title: title,
        body: body,
        priority: reminder.priority,
        scheduledAt: scheduledAt,
      );
    } else if (now.difference(scheduledAt).inMinutes < 5) {
      // If we're within 5 minutes after the time (e.g. just missed it), fire now.
      await _sendPush(id: pushId, title: title, body: body, priority: reminder.priority);
    }
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

    // Re-schedule on-time push (alarm).
    await scheduleReminderOnTime(reminder);

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

    // Schedule repeat occurrences (cancels stale slots internally).
    await scheduleRepeatReminderNotifications(reminder);
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
      await _plugin.cancel(_onTimePushId(reminderId));
      await _plugin.cancel(_overduePushId(reminderId));
    } catch (_) {}
    await cancelRepeatReminderNotifications(reminderId);
  }

  /// Cancels all pre-scheduled repeat-occurrence OS alarms for [reminderId]
  /// by iterating over all [_kMaxRepeatSlots] slot IDs, and removes the
  /// in-app notification record for this reminder's repeat series.
  static Future<void> cancelRepeatReminderNotifications(
      String reminderId) async {
    if (!kIsWeb && _initialized) {
      for (int i = 0; i < _kMaxRepeatSlots; i++) {
        try {
          await _plugin.cancel(_repeatPushId(reminderId, i));
        } catch (_) {}
      }
    }
    await DatabaseService.deleteNotification('repeat_$reminderId');
  }

  /// Schedules up to [_kMaxRepeatSlots] future repeat occurrences for [reminder].
  ///
  /// Always cancels all existing repeat slots first so calling this method
  /// again (e.g. on frequency change or WorkManager refresh) is idempotent.
  ///
  /// Does nothing when:
  ///   - [reminder.isCompleted] is true
  ///   - [reminder.repeatFrequency] is null
  ///   - [reminder.startDateTime] is still in the future
  static Future<void> scheduleRepeatReminderNotifications(
      Reminder reminder) async {
    // Cancel existing slots first — this method is idempotent.
    await cancelRepeatReminderNotifications(reminder.id);

    if (reminder.isCompleted) return;

    final step = _frequencyToDuration(reminder.repeatFrequency);
    if (step == null) return;

    final now = DateTime.now();

    // Repeat fires only after startDateTime has passed.
    if (reminder.startDateTime.isAfter(now)) return;

    final ownerId = StorageService.currentUserId;
    if (ownerId.isEmpty) return;

    const title = 'Rappel récurrent';
    final body = reminder.note.isNotEmpty
        ? reminder.note
        : 'Rappel prévu à ${_formatTime(reminder.startDateTime)}';

    // Compute the first occurrence strictly after now.
    DateTime nextTime = _computeNextRepeatTime(
      startDateTime: reminder.startDateTime,
      step: step,
      now: now,
    );

    // Upsert the in-app notification record (represents the next occurrence).
    await DatabaseService.insertNotification(AppNotification(
      id: 'repeat_${reminder.id}',
      ownerId: ownerId,
      type: 'reminder_repeat',
      title: title,
      body: body,
      scheduledAt: nextTime,
      createdAt: now,
      referenceId: reminder.id,
    ));

    // Schedule MAX_SLOTS future occurrences as OS alarms.
    for (int i = 0; i < _kMaxRepeatSlots; i++) {
      await _schedulePush(
        id: _repeatPushId(reminder.id, i),
        title: title,
        body: body,
        priority: reminder.priority,
        scheduledAt: nextTime,
      );
      nextTime = nextTime.add(step);
    }
  }

  // -----------------------------------------------------------------------
  // Public API — task notifications (mirrors reminder pattern)
  // -----------------------------------------------------------------------

  /// Schedules the upcoming push (15 min before task start) for the assignee.
  /// [assigneeId] is stored as ownerId on the in-app notification so it appears
  /// in the assignee's notification feed, not the creator's.
  static Future<void> scheduleTaskUpcoming(
      AppTask task, String assigneeId) async {
    if (kIsWeb || !_initialized) return;
    final scheduledAt =
        task.startDateTime.subtract(const Duration(minutes: 15));
    final now = DateTime.now();
    final title = 'Tâche dans 15 min';
    final body = task.note.isNotEmpty
        ? task.note
        : 'Tâche prévue à ${_formatTime(task.startDateTime)}';

    await _persistIfNew(AppNotification(
      id: 'task_upcoming_${task.id}',
      ownerId: assigneeId,
      type: 'task_upcoming',
      title: title,
      body: body,
      scheduledAt: scheduledAt,
      createdAt: now,
      referenceId: task.id,
    ));

    final pushId = _taskUpcomingPushId(task.id);
    try {
      await _plugin.cancel(pushId);
    } catch (_) {}

    if (scheduledAt.isAfter(now)) {
      await _schedulePush(
          id: pushId,
          title: title,
          body: body,
          priority: task.priority,
          scheduledAt: scheduledAt);
    } else if (task.startDateTime.isAfter(now)) {
      await _sendPush(
          id: pushId, title: title, body: body, priority: task.priority);
    }
  }

  /// Schedules the on-time push (at task startDateTime) for the assignee.
  static Future<void> scheduleTaskOnTime(
      AppTask task, String assigneeId) async {
    if (kIsWeb || !_initialized) return;
    final scheduledAt = task.startDateTime;
    final now = DateTime.now();
    final title = 'Me2Leads : Tâche maintenant !';
    final body =
        task.note.isNotEmpty ? task.note : "C'est le moment de votre tâche.";

    await _persistIfNew(AppNotification(
      id: 'task_ontime_${task.id}',
      ownerId: assigneeId,
      type: 'task_ontime',
      title: title,
      body: body,
      scheduledAt: scheduledAt,
      createdAt: now,
      referenceId: task.id,
    ));

    final pushId = _taskOnTimePushId(task.id);
    try {
      await _plugin.cancel(pushId);
    } catch (_) {}

    if (scheduledAt.isAfter(now)) {
      await _schedulePush(
          id: pushId,
          title: title,
          body: body,
          priority: task.priority,
          scheduledAt: scheduledAt);
    } else if (now.difference(scheduledAt).inMinutes < 5) {
      await _sendPush(
          id: pushId, title: title, body: body, priority: task.priority);
    }
  }

  /// Schedules the overdue push (4 hours after deadline) for the assignee.
  static Future<void> createOverdueTaskNotification(
      AppTask task, String assigneeId) async {
    final notifId = 'task_overdue_${task.id}';
    final deadline = task.endDateTime ?? task.startDateTime;
    final scheduledAt = deadline.add(const Duration(hours: 4));
    final now = DateTime.now();
    final title = 'Tâche en retard';
    final body = task.note.isNotEmpty
        ? task.note
        : 'Tâche du ${_formatDate(deadline)} non effectuée';

    final existed = await DatabaseService.notificationExists(notifId);
    await _persistIfNew(AppNotification(
      id: notifId,
      ownerId: assigneeId,
      type: 'task_overdue',
      title: title,
      body: body,
      scheduledAt: scheduledAt,
      createdAt: now,
      referenceId: task.id,
    ));

    if (!existed) {
      final pushId = _taskOverduePushId(task.id);
      if (scheduledAt.isAfter(now)) {
        if (!kIsWeb && _initialized) {
          await _schedulePush(
              id: pushId,
              title: title,
              body: body,
              priority: task.priority,
              scheduledAt: scheduledAt);
        }
      } else {
        await _sendPush(
            id: pushId, title: title, body: body, priority: task.priority);
      }
    }
  }

  /// Schedules up to [_kMaxRepeatSlots] future repeat occurrences for [task].
  static Future<void> scheduleTaskRepeats(
      AppTask task, String assigneeId) async {
    // Cancel existing repeat slots first (idempotent).
    if (!kIsWeb && _initialized) {
      for (int i = 0; i < _kMaxRepeatSlots; i++) {
        try {
          await _plugin.cancel(_taskRepeatPushId(task.id, i));
        } catch (_) {}
      }
    }
    await DatabaseService.deleteNotification('task_repeat_${task.id}');

    if (task.isCompleted) return;
    final step = _frequencyToDuration(task.repeatFrequency);
    if (step == null) return;
    final now = DateTime.now();
    if (task.startDateTime.isAfter(now)) return;

    const title = 'Tâche récurrente';
    final body = task.note.isNotEmpty
        ? task.note
        : 'Tâche prévue à ${_formatTime(task.startDateTime)}';

    DateTime nextTime = _computeNextRepeatTime(
        startDateTime: task.startDateTime, step: step, now: now);

    await DatabaseService.insertNotification(AppNotification(
      id: 'task_repeat_${task.id}',
      ownerId: assigneeId,
      type: 'task_repeat',
      title: title,
      body: body,
      scheduledAt: nextTime,
      createdAt: now,
      referenceId: task.id,
    ));

    for (int i = 0; i < _kMaxRepeatSlots; i++) {
      await _schedulePush(
          id: _taskRepeatPushId(task.id, i),
          title: title,
          body: body,
          priority: task.priority,
          scheduledAt: nextTime);
      nextTime = nextTime.add(step);
    }
  }

  /// Schedules all notifications (upcoming, on-time, overdue, repeat) for a
  /// task on the **assignee's** device only. No-op if the task is completed.
  static Future<void> scheduleAllTaskNotifications(
      AppTask task, String assigneeId) async {
    if (task.isCompleted) return;
    await scheduleTaskUpcoming(task, assigneeId);
    await scheduleTaskOnTime(task, assigneeId);

    // Reset overdue push so an updated deadline takes effect.
    final overdueId = 'task_overdue_${task.id}';
    if (!kIsWeb && _initialized) {
      try {
        await _plugin.cancel(_taskOverduePushId(task.id));
      } catch (_) {}
    }
    final exists = await DatabaseService.notificationExists(overdueId);
    if (exists) await DatabaseService.deleteNotification(overdueId);
    await createOverdueTaskNotification(task, assigneeId);

    await scheduleTaskRepeats(task, assigneeId);
  }

  /// Cancels all scheduled OS alarms and in-app records for [taskId].
  static Future<void> cancelTaskScheduledNotifications(String taskId) async {
    if (!kIsWeb && _initialized) {
      try {
        await _plugin.cancel(_taskUpcomingPushId(taskId));
        await _plugin.cancel(_taskOnTimePushId(taskId));
        await _plugin.cancel(_taskOverduePushId(taskId));
      } catch (_) {}
      for (int i = 0; i < _kMaxRepeatSlots; i++) {
        try {
          await _plugin.cancel(_taskRepeatPushId(taskId, i));
        } catch (_) {}
      }
    }
    await DatabaseService.deleteNotification('task_upcoming_$taskId');
    await DatabaseService.deleteNotification('task_ontime_$taskId');
    await DatabaseService.deleteNotification('task_overdue_$taskId');
    await DatabaseService.deleteNotification('task_repeat_$taskId');
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
    List<AppTask> tasks = const [],
  }) async {
    final ownerId = StorageService.currentUserId;
    if (ownerId.isEmpty) return;

    final now = DateTime.now();

    // Upcoming reminder pushes (15 min before start)
    for (final r in reminders) {
      if (r.isCompleted) continue;
      await scheduleReminderUpcoming(r);
      await scheduleReminderOnTime(r);
    }

    // Overdue reminder pushes (4+ hours past deadline)
    for (final r in reminders) {
      if (r.isCompleted) continue;
      final deadline = r.endDateTime ?? r.startDateTime;
      if (now.isAfter(deadline.add(const Duration(hours: 4)))) {
        await createOverdueReminderNotification(r);
      }
    }

    // Repeat reminder pushes — refresh rolling window for all active repeating reminders.
    for (final r in reminders) {
      if (r.isCompleted) continue;
      if (r.repeatFrequency == null) continue;
      if (r.startDateTime.isAfter(now)) continue;
      await scheduleRepeatReminderNotifications(r);
    }

    // Incomplete hot/warm contact pushes (3+ days after creation)
    for (final c in contacts) {
      if (c.status != 'hot' && c.status != 'warm') continue;
      if (now.isAfter(c.createdAt.add(const Duration(days: 3)))) {
        await createIncompleteContactNotification(c);
      }
    }

    // Task notifications — only schedule for tasks assigned to the current user.
    for (final t in tasks) {
      if (t.isCompleted) continue;
      if (!t.assigneeUserIds.contains(ownerId)) continue;
      await scheduleTaskUpcoming(t, ownerId);
      await scheduleTaskOnTime(t, ownerId);
    }
    for (final t in tasks) {
      if (t.isCompleted) continue;
      if (!t.assigneeUserIds.contains(ownerId)) continue;
      final deadline = t.endDateTime ?? t.startDateTime;
      if (now.isAfter(deadline.add(const Duration(hours: 4)))) {
        await createOverdueTaskNotification(t, ownerId);
      }
    }
    for (final t in tasks) {
      if (t.isCompleted) continue;
      if (!t.assigneeUserIds.contains(ownerId)) continue;
      if (t.repeatFrequency == null) continue;
      if (t.startDateTime.isAfter(now)) continue;
      await scheduleTaskRepeats(t, ownerId);
    }
  }

  // -----------------------------------------------------------------------
  // Public API — subscription renewal reminders
  // -----------------------------------------------------------------------

  /// Schedules (or re-schedules) the 3 renewal push + in-app notifications
  /// for the current subscription cycle:
  ///   Monthly → early = expiry−5d, mid = expiry−3d, last = expiry
  ///   Yearly  → early = expiry−7d, mid = expiry−3d, last = expiry
  ///
  /// Safe to call multiple times — existing pushes are cancelled first and
  /// in-app records are deduplicated by ID.
  static Future<void> scheduleSubscriptionRenewalNotifications({
    required String userId,
    required DateTime planExpiresAt,
    required String billingCycle,
  }) async {
    final earlyOffset =
        billingCycle == 'yearly' ? const Duration(days: 7) : const Duration(days: 5);
    final earlyDate = planExpiresAt.subtract(earlyOffset);
    final midDate = planExpiresAt.subtract(const Duration(days: 3));
    final lastDate = planExpiresAt;
    final now = DateTime.now();

    // Cancel stale pushes first so re-scheduling on renewal is clean.
    if (!kIsWeb && _initialized) {
      try { await _plugin.cancel(_subEarlyPushId(userId)); } catch (_) {}
      try { await _plugin.cancel(_subMidPushId(userId)); } catch (_) {}
      try { await _plugin.cancel(_subLastPushId(userId)); } catch (_) {}
    }

    // Delete stale in-app records so they get fresh scheduled_at dates.
    await DatabaseService.deleteNotification('sub_early_$userId');
    await DatabaseService.deleteNotification('sub_mid_$userId');
    await DatabaseService.deleteNotification('sub_last_$userId');

    final earlyDays = billingCycle == 'yearly' ? '7' : '5';

    Future<void> _schedule(String notifId, int pushId, DateTime scheduledAt,
        String title, String body) async {
      if (scheduledAt.isBefore(now)) return;
      await _persistIfNew(AppNotification(
        id: notifId,
        ownerId: userId,
        type: 'subscription_renewal',
        title: title,
        body: body,
        scheduledAt: scheduledAt,
        createdAt: now,
      ));
      await _schedulePush(
        id: pushId,
        title: title,
        body: body,
        priority: 'important',
        scheduledAt: scheduledAt,
      );
    }

    await _schedule(
      'sub_early_$userId',
      _subEarlyPushId(userId),
      earlyDate,
      'Abonnement bientôt expiré',
      'Votre abonnement expire dans $earlyDays jours. Renouvelez maintenant pour conserver toutes vos fonctionnalités.',
    );
    await _schedule(
      'sub_mid_$userId',
      _subMidPushId(userId),
      midDate,
      'Abonnement bientôt expiré',
      'Votre abonnement expire dans 3 jours. Renouvelez maintenant.',
    );
    await _schedule(
      'sub_last_$userId',
      _subLastPushId(userId),
      lastDate,
      "Dernier jour de votre abonnement",
      "C'est le dernier jour de votre abonnement. Renouvelez dès maintenant.",
    );
  }

  /// Cancels all subscription renewal push and in-app notifications for [userId].
  /// Call when the user changes plan (renew, upgrade, or downgrade to free).
  static Future<void> cancelSubscriptionRenewalNotifications(
      String userId) async {
    if (!kIsWeb && _initialized) {
      try { await _plugin.cancel(_subEarlyPushId(userId)); } catch (_) {}
      try { await _plugin.cancel(_subMidPushId(userId)); } catch (_) {}
      try { await _plugin.cancel(_subLastPushId(userId)); } catch (_) {}
    }
    await DatabaseService.deleteNotification('sub_early_$userId');
    await DatabaseService.deleteNotification('sub_mid_$userId');
    await DatabaseService.deleteNotification('sub_last_$userId');
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

  /// Maps a repeat frequency string to its [Duration] equivalent.
  /// Returns null for null or unknown values (treated as "no repeat").
  static Duration? _frequencyToDuration(String? frequency) {
    if (frequency == null) return null;
    final match = RegExp(r'^(\d+)(m|h|d|w|mo)$').firstMatch(frequency);
    if (match == null) return null;

    final value = int.tryParse(match.group(1)!) ?? 0;
    final unit = match.group(2);

    switch (unit) {
      case 'm':
        return Duration(minutes: value);
      case 'h':
        return Duration(hours: value);
      case 'd':
        return Duration(days: value);
      case 'w':
        return Duration(days: value * 7);
      case 'mo':
        return Duration(days: value * 30);
      default:
        return null;
    }
  }

  /// Returns the first repeat occurrence strictly after [now].
  ///
  /// Uses integer division: floor(elapsed / step) complete intervals have
  /// passed since [startDateTime], so the next occurrence is exactly one
  /// step beyond that — guaranteed to be after [now] without any loop.
  static DateTime _computeNextRepeatTime({
    required DateTime startDateTime,
    required Duration step,
    required DateTime now,
  }) {
    if (startDateTime.isAfter(now)) return startDateTime.add(step);
    final elapsedMs = now.difference(startDateTime).inMilliseconds;
    final stepsCompleted = elapsedMs ~/ step.inMilliseconds;
    return startDateTime
        .add(Duration(milliseconds: step.inMilliseconds * (stepsCompleted + 1)));
  }
}

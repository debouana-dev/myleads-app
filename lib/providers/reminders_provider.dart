import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../models/reminder.dart';
import '../services/database_service.dart';
import '../services/notification_service.dart';
import '../services/storage_service.dart';

const _uuid = Uuid();

class RemindersState {
  final List<Reminder> reminders;
  final String activeTab;

  const RemindersState({
    this.reminders = const [],
    this.activeTab = 'today',
  });

  List<Reminder> get todayReminders {
    final list = reminders
        .where((r) => r.isToday && !r.isCompleted && !r.isLate)
        .toList();
    list.sort((a, b) => a.startDateTime.compareTo(b.startDateTime));
    return list;
  }

  List<Reminder> get weekReminders {
    final list = reminders
        .where((r) => r.isThisWeek && !r.isToday && !r.isCompleted && !r.isLate)
        .toList();
    list.sort((a, b) => a.startDateTime.compareTo(b.startDateTime));
    return list;
  }

  List<Reminder> get laterReminders {
    final list = reminders.where((r) => r.isLater && !r.isCompleted).toList();
    list.sort((a, b) => a.startDateTime.compareTo(b.startDateTime));
    return list;
  }

  List<Reminder> get lateReminders {
    final list = reminders.where((r) => r.isLate && !r.isCompleted).toList();
    list.sort((a, b) => a.startDateTime.compareTo(b.startDateTime));
    return list;
  }

  List<Reminder> get doneReminders {
    final list = reminders.where((r) => r.isCompleted).toList();
    list.sort((a, b) => b.sortKey.compareTo(a.sortKey));
    return list;
  }

  // Backward compat
  List<Reminder> get overdueReminders => lateReminders;
  List<Reminder> get completedReminders => doneReminders;

  List<Reminder> getRemindersForContact(String contactId) {
    final list =
        reminders.where((r) => r.contactIds.contains(contactId)).toList();
    list.sort((a, b) => a.startDateTime.compareTo(b.startDateTime));
    return list;
  }

  RemindersState copyWith({List<Reminder>? reminders, String? activeTab}) {
    return RemindersState(
      reminders: reminders ?? this.reminders,
      activeTab: activeTab ?? this.activeTab,
    );
  }
}

class RemindersNotifier extends StateNotifier<RemindersState> {
  RemindersNotifier() : super(const RemindersState()) {
    _load().then((_) async {
      _lastSyncAt =
          await DatabaseService.getUserLastSync(StorageService.currentUserId);
      _syncCheckTimer = Timer.periodic(
          const Duration(seconds: 30), (_) => _checkForSyncUpdate());
    });
  }

  Timer? _syncCheckTimer;
  String? _lastSyncAt;

  Future<void> _load() async {
    final user = StorageService.currentUser;
    if (user == null || user.id.isEmpty) return;
    final orgId = user.organizationId;
    final List<Reminder> list;
    if (orgId != null) {
      final privs = await DatabaseService.getMemberPrivileges(
        userId: user.id,
        orgId: orgId,
      );
      list = await DatabaseService.getRemindersForOrgUser(
        userId: user.id,
        orgId: orgId,
        canViewReminders: privs.canViewReminders,
      );
    } else {
      list = await DatabaseService.getAllRemindersForOwner(user.id);
    }
    state = state.copyWith(reminders: list);
  }

  Future<Reminder> addReminder({
    required List<String> contactIds,
    required DateTime startDateTime,
    DateTime? endDateTime,
    String? repeatFrequency,
    required String note,
    String toDoAction = 'call',
    String priority = 'normal',
  }) async {
    final ownerId = StorageService.currentUserId;
    final r = Reminder(
      id: _uuid.v4(),
      ownerId: ownerId,
      contactIds: contactIds,
      startDateTime: startDateTime,
      endDateTime: endDateTime,
      repeatFrequency: repeatFrequency,
      note: note,
      toDoAction: toDoAction,
      priority: priority,
    );
    await DatabaseService.insertReminder(r);
    state = state.copyWith(reminders: [...state.reminders, r]);
    NotificationService.scheduleAllReminderNotifications(r);
    return r;
  }

  Future<void> updateReminder(Reminder reminder) async {
    await DatabaseService.updateReminder(reminder);
    state = state.copyWith(
      reminders: state.reminders
          .map((r) => r.id == reminder.id ? reminder : r)
          .toList(),
    );
    if (!reminder.isCompleted) {
      NotificationService.scheduleAllReminderNotifications(reminder);
    }
  }

  Future<void> completeReminder(String id) async {
    final reminder = state.reminders.firstWhere((r) => r.id == id);
    final updated = reminder.copyWith(isCompleted: true);
    await updateReminder(updated);
    // Cancel any pending OS alarm — reminder is done.
    NotificationService.cancelReminderScheduledNotification(id);
  }

  Future<void> deleteReminder(String id) async {
    await DatabaseService.deleteReminder(id);
    state = state.copyWith(
        reminders: state.reminders.where((r) => r.id != id).toList());
    // Cancel any pending OS alarm so stale pushes don't fire.
    NotificationService.cancelReminderScheduledNotification(id);
  }

  void setActiveTab(String tab) {
    state = state.copyWith(activeTab: tab);
  }

  Future<void> refresh() => _load();
  Future<void> reload() => _load();

  Future<void> _checkForSyncUpdate() async {
    final userId = StorageService.currentUserId;
    if (userId.isEmpty) return;
    final currentSyncAt = await DatabaseService.getUserLastSync(userId);
    if (currentSyncAt != null && currentSyncAt != _lastSyncAt) {
      _lastSyncAt = currentSyncAt;
      await _load();
    }
  }

  @override
  void dispose() {
    _syncCheckTimer?.cancel();
    super.dispose();
  }
}

final remindersProvider =
    StateNotifierProvider<RemindersNotifier, RemindersState>((ref) {
  return RemindersNotifier();
});

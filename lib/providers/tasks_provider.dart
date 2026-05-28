import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../models/app_task.dart';
import '../services/calendar_service.dart';
import '../services/database_service.dart';
import '../services/notification_service.dart';
import '../services/remote_sync_service.dart';
import '../services/storage_service.dart';

const _uuid = Uuid();

class TasksState {
  final List<AppTask> tasks;
  final bool isLoading;
  final String? error;

  const TasksState({
    this.tasks = const [],
    this.isLoading = false,
    this.error,
  });

  /// All non-completed tasks, sorted DESC by startDateTime (DB order preserved).
  List<AppTask> get pendingTasks =>
      tasks.where((t) => !t.isCompleted).toList();

  /// All completed tasks, sorted DESC by startDateTime (DB order preserved).
  List<AppTask> get completedTasks =>
      tasks.where((t) => t.isCompleted).toList();

  /// Pending tasks where the current user is one of the assignees.
  List<AppTask> myAssignedTasks(String currentUserId) => tasks
      .where((t) => !t.isCompleted && t.assigneeUserIds.contains(currentUserId))
      .toList();

  /// Completed tasks where the current user is one of the assignees.
  List<AppTask> completedTasksForUser(String currentUserId) => tasks
      .where((t) => t.isCompleted && t.assigneeUserIds.contains(currentUserId))
      .toList();

  TasksState copyWith({
    List<AppTask>? tasks,
    bool? isLoading,
    Object? error = _sentinel,
  }) {
    return TasksState(
      tasks: tasks ?? this.tasks,
      isLoading: isLoading ?? this.isLoading,
      error: error == _sentinel ? this.error : error as String?,
    );
  }

  static const Object _sentinel = Object();
}

class TasksNotifier extends StateNotifier<TasksState> {
  TasksNotifier() : super(const TasksState());

  String? _orgId;
  String? _userId;

  // ── Load ─────────────────────────────────────────────────────────────────

  Future<void> loadTasksForOrg(String orgId) async {
    _orgId = orgId;
    state = state.copyWith(isLoading: true, error: null);
    try {
      final tasks = await DatabaseService.getTasksForOrganization(orgId);
      state = state.copyWith(tasks: tasks, isLoading: false);
      _scheduleNotificationsForMyTasks(tasks);
    } catch (e) {
      state = state.copyWith(isLoading: false, error: e.toString());
    }
  }

  /// Syncs tasks to/from the cloud then reloads from local DB.
  /// Used on tasks-screen open and pull-to-refresh.
  Future<void> syncAndLoad(String orgId, String userId) async {
    _orgId = orgId;
    _userId = userId;
    state = state.copyWith(isLoading: true, error: null);
    try {
      await RemoteSyncService.syncTasksForOrg(userId, orgId);
      final tasks = await DatabaseService.getTasksForOrganization(orgId);
      state = state.copyWith(tasks: tasks, isLoading: false);
      _scheduleNotificationsForMyTasks(tasks);
    } catch (e) {
      state = state.copyWith(isLoading: false, error: e.toString());
    }
  }

  /// Syncs with remote and refreshes tasks without showing the loading indicator.
  /// Used for background refresh after the initial local load is displayed.
  Future<void> syncSilently(String orgId, String userId) async {
    _orgId = orgId;
    _userId = userId;
    try {
      await RemoteSyncService.syncTasksForOrg(userId, orgId);
      final tasks = await DatabaseService.getTasksForOrganization(orgId);
      state = state.copyWith(tasks: tasks);
      _scheduleNotificationsForMyTasks(tasks);
    } catch (_) {}
  }

  Future<void> loadPersonalTasks(String userId) {
    throw UnimplementedError('Personal tasks not yet implemented.');
  }

  Future<void> refresh() async {
    if (_orgId != null && _userId != null) {
      await syncAndLoad(_orgId!, _userId!);
    } else if (_orgId != null) {
      await loadTasksForOrg(_orgId!);
    }
  }

  // ── CRUD ─────────────────────────────────────────────────────────────────

  Future<AppTask?> createTask({
    String? organizationId,
    required List<String> assigneeUserIds,
    required DateTime startDateTime,
    DateTime? endDateTime,
    String? repeatFrequency,
    required String note,
    required String toDoAction,
    required String priority,
    bool addToCalendar = false,
  }) async {
    final user = StorageService.currentUser;
    if (user == null) return null;

    final isAdminOrOwner =
        user.orgRole == 'admin' || user.orgRole == 'owner';

    // Regular members can only self-assign.
    if (!isAdminOrOwner &&
        (assigneeUserIds.length != 1 || assigneeUserIds.first != user.id)) {
      return null;
    }

    final task = AppTask(
      id: _uuid.v4(),
      organizationId: organizationId,
      createdByUserId: user.id,
      assigneeUserIds: assigneeUserIds,
      startDateTime: startDateTime,
      endDateTime: endDateTime,
      repeatFrequency: repeatFrequency,
      note: note,
      toDoAction: toDoAction,
      priority: priority,
    );

    await DatabaseService.insertTask(task);
    state = state.copyWith(tasks: [task, ...state.tasks]);

    if (assigneeUserIds.contains(user.id)) {
      NotificationService.scheduleAllTaskNotifications(task, user.id);
    }

    if (addToCalendar) {
      await CalendarService.addTaskToCalendar(task);
    }

    return task;
  }

  Future<void> updateTask(AppTask updated) async {
    final user = StorageService.currentUser;
    if (user == null) return;

    final isAdminOrOwner =
        user.orgRole == 'admin' || user.orgRole == 'owner';
    final original = state.tasks.firstWhere(
      (t) => t.id == updated.id,
      orElse: () => updated,
    );

    // Only admin/owner or the task creator may edit.
    if (!isAdminOrOwner && original.createdByUserId != user.id) return;

    await DatabaseService.updateTask(updated);
    state = state.copyWith(
      tasks: state.tasks.map((t) => t.id == updated.id ? updated : t).toList(),
    );

    if (!updated.isCompleted && updated.assigneeUserIds.contains(user.id)) {
      NotificationService.scheduleAllTaskNotifications(updated, user.id);
    }
  }

  Future<void> completeTask(String id, String completedByUserId) async {
    final user = StorageService.currentUser;
    if (user == null) return;

    final task = state.tasks.firstWhere((t) => t.id == id,
        orElse: () => throw StateError('Task $id not found'));

    final isAdminOrOwner =
        user.orgRole == 'admin' || user.orgRole == 'owner';
    final isCreatorOrAssignee = task.createdByUserId == user.id ||
        task.assigneeUserIds.contains(user.id);

    if (!isAdminOrOwner && !isCreatorOrAssignee) return;

    await DatabaseService.completeTask(id, completedByUserId);
    final updated = task.copyWith(
      isCompleted: true,
      completedByUserId: completedByUserId,
    );
    state = state.copyWith(
      tasks: state.tasks.map((t) => t.id == id ? updated : t).toList(),
    );
    NotificationService.cancelTaskScheduledNotifications(id);
  }

  Future<void> uncompleteTask(String id) async {
    final user = StorageService.currentUser;
    if (user == null) return;

    final task = state.tasks.firstWhere((t) => t.id == id,
        orElse: () => throw StateError('Task $id not found'));

    final isAdminOrOwner =
        user.orgRole == 'admin' || user.orgRole == 'owner';
    final isCreatorOrAssignee = task.createdByUserId == user.id ||
        task.assigneeUserIds.contains(user.id);

    if (!isAdminOrOwner && !isCreatorOrAssignee) return;

    await DatabaseService.uncompleteTask(id);
    final updated = task.copyWith(
      isCompleted: false,
      completedByUserId: null,
    );
    state = state.copyWith(
      tasks: state.tasks.map((t) => t.id == id ? updated : t).toList(),
    );

    if (task.assigneeUserIds.contains(user.id)) {
      NotificationService.scheduleAllTaskNotifications(updated, user.id);
    }
  }

  Future<void> deleteTask(String id) async {
    final user = StorageService.currentUser;
    if (user == null) return;

    final isAdminOrOwner =
        user.orgRole == 'admin' || user.orgRole == 'owner';
    if (!isAdminOrOwner) return;

    await DatabaseService.deleteTask(id);
    state = state.copyWith(
        tasks: state.tasks.where((t) => t.id != id).toList());
    NotificationService.cancelTaskScheduledNotifications(id);
  }

  // ── Helpers ───────────────────────────────────────────────────────────────

  void _scheduleNotificationsForMyTasks(List<AppTask> tasks) {
    final currentUserId = StorageService.currentUserId;
    if (currentUserId.isEmpty) return;
    for (final t in tasks) {
      if (t.isCompleted) continue;
      if (!t.assigneeUserIds.contains(currentUserId)) continue;
      NotificationService.scheduleAllTaskNotifications(t, currentUserId);
    }
  }
}

final tasksProvider =
    StateNotifierProvider<TasksNotifier, TasksState>((ref) {
  return TasksNotifier();
});

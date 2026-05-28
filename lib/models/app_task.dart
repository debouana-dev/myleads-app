/// Organization task entity — mirrors Reminder but targets org members.
///
/// [organizationId] is nullable: null = personal task (future), non-null = org task.
/// The DB table (tasks) supports both modes without schema changes.
class AppTask {
  final String id;

  /// Null for a personal task (future use); non-null for an org task.
  final String? organizationId;

  final String createdByUserId;

  /// One or more org members assigned to this task (v27+).
  final List<String> assigneeUserIds;

  final DateTime startDateTime;
  final DateTime? endDateTime;

  /// Same format as Reminder.repeatFrequency: "30m", "1h", "1d", "1w", "1mo".
  final String? repeatFrequency;

  final String note;

  /// Default quick-action: 'call' | 'sms' | 'whatsapp' | 'email'
  final String toDoAction;

  /// 'normal' | 'important' | 'very_important'
  final String priority;

  bool isCompleted;
  final String? completedByUserId;
  final DateTime createdAt;

  AppTask({
    required this.id,
    this.organizationId,
    required this.createdByUserId,
    required this.assigneeUserIds,
    required this.startDateTime,
    this.endDateTime,
    this.repeatFrequency,
    required this.note,
    this.toDoAction = 'call',
    this.priority = 'normal',
    this.isCompleted = false,
    this.completedByUserId,
    DateTime? createdAt,
  }) : createdAt = createdAt ?? DateTime.now();

  bool get isOverdue {
    if (isCompleted) return false;
    return startDateTime.isBefore(DateTime.now());
  }

  bool get isToday {
    final now = DateTime.now();
    return startDateTime.year == now.year &&
        startDateTime.month == now.month &&
        startDateTime.day == now.day;
  }

  bool get isThisWeek {
    final now = DateTime.now();
    final startOfWeek =
        DateTime(now.year, now.month, now.day - (now.weekday - 1));
    final endOfWeek = startOfWeek
        .add(const Duration(days: 6, hours: 23, minutes: 59, seconds: 59));
    return startDateTime
            .isAfter(startOfWeek.subtract(const Duration(seconds: 1))) &&
        startDateTime.isBefore(endOfWeek.add(const Duration(seconds: 1)));
  }

  bool get isLater {
    final now = DateTime.now();
    final startOfWeek =
        DateTime(now.year, now.month, now.day - (now.weekday - 1));
    final endOfWeek = startOfWeek
        .add(const Duration(days: 6, hours: 23, minutes: 59, seconds: 59));
    return startDateTime.isAfter(endOfWeek);
  }

  bool get isLate {
    if (isCompleted) return false;
    final deadline = endDateTime ?? startDateTime;
    return deadline.isBefore(DateTime.now());
  }

  DateTime get sortKey => endDateTime ?? startDateTime;

  static const _sentinel = Object();

  AppTask copyWith({
    String? id,
    Object? organizationId = _sentinel,
    String? createdByUserId,
    List<String>? assigneeUserIds,
    DateTime? startDateTime,
    Object? endDateTime = _sentinel,
    Object? repeatFrequency = _sentinel,
    String? note,
    String? toDoAction,
    String? priority,
    bool? isCompleted,
    Object? completedByUserId = _sentinel,
  }) {
    return AppTask(
      id: id ?? this.id,
      organizationId: organizationId == _sentinel
          ? this.organizationId
          : organizationId as String?,
      createdByUserId: createdByUserId ?? this.createdByUserId,
      assigneeUserIds: assigneeUserIds ?? this.assigneeUserIds,
      startDateTime: startDateTime ?? this.startDateTime,
      endDateTime:
          endDateTime == _sentinel ? this.endDateTime : endDateTime as DateTime?,
      repeatFrequency: repeatFrequency == _sentinel
          ? this.repeatFrequency
          : repeatFrequency as String?,
      note: note ?? this.note,
      toDoAction: toDoAction ?? this.toDoAction,
      priority: priority ?? this.priority,
      isCompleted: isCompleted ?? this.isCompleted,
      completedByUserId: completedByUserId == _sentinel
          ? this.completedByUserId
          : completedByUserId as String?,
      createdAt: createdAt,
    );
  }
}

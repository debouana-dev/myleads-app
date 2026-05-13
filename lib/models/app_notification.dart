/// In-app notification model stored in the local SQLite database.
///
/// type values:
///   'reminder_upcoming'  — 15 min before reminder start
///   'reminder_overdue'   — reminder 4+ hours past deadline
///   'reminder_repeat'    — recurring notification at the reminder's repeat interval
///   'contact_incomplete' — hot/warm contact with incomplete profile 3+ days old
class AppNotification {
  final String id;
  final String ownerId;
  final String type;
  final String title;
  final String body;

  /// ISO-8601 datetime when this notification should become visible.
  final DateTime scheduledAt;

  /// ISO-8601 datetime when this was created (for deduplication).
  final DateTime createdAt;

  /// Optional foreign-key reference (reminder id or contact id).
  final String? referenceId;

  final bool isRead;

  const AppNotification({
    required this.id,
    required this.ownerId,
    required this.type,
    required this.title,
    required this.body,
    required this.scheduledAt,
    required this.createdAt,
    this.referenceId,
    this.isRead = false,
  });

  AppNotification copyWith({
    String? id,
    String? ownerId,
    String? type,
    String? title,
    String? body,
    DateTime? scheduledAt,
    DateTime? createdAt,
    String? referenceId,
    bool? isRead,
  }) {
    return AppNotification(
      id: id ?? this.id,
      ownerId: ownerId ?? this.ownerId,
      type: type ?? this.type,
      title: title ?? this.title,
      body: body ?? this.body,
      scheduledAt: scheduledAt ?? this.scheduledAt,
      createdAt: createdAt ?? this.createdAt,
      referenceId: referenceId ?? this.referenceId,
      isRead: isRead ?? this.isRead,
    );
  }

  Map<String, dynamic> toRow() => {
        'id': id,
        'owner_id': ownerId,
        'type': type,
        'title': title,
        'body': body,
        'scheduled_at': scheduledAt.toIso8601String(),
        'created_at': createdAt.toIso8601String(),
        'reference_id': referenceId,
        'is_read': isRead ? 1 : 0,
      };

  factory AppNotification.fromRow(Map<String, dynamic> row) =>
      AppNotification(
        id: row['id'] as String,
        ownerId: row['owner_id'] as String,
        type: row['type'] as String,
        title: row['title'] as String,
        body: row['body'] as String,
        scheduledAt: DateTime.parse(row['scheduled_at'] as String),
        createdAt: DateTime.parse(row['created_at'] as String),
        referenceId: row['reference_id'] as String?,
        isRead: (row['is_read'] as int? ?? 0) == 1,
      );
}

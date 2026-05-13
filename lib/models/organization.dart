/// An organization that groups multiple user accounts under a single admin.
class Organization {
  final String id;
  final String name;
  final String ownerId; // admin's user id
  final String inviteCode; // 8-char alphanumeric code for joining
  final DateTime createdAt;
  final int
      licenseCount; // number of Business licenses purchased (includes admin)
  final DateTime? orgPlanExpiresAt; // when org licenses expire
  final String orgStatus; // 'active' | 'suspended'
  final DateTime?
      orgSuspendedAt; // when org was suspended (for 6-month deletion timer)

  Organization({
    required this.id,
    required this.name,
    required this.ownerId,
    required this.inviteCode,
    DateTime? createdAt,
    this.licenseCount = 1,
    this.orgPlanExpiresAt,
    this.orgStatus = 'active',
    this.orgSuspendedAt,
  }) : createdAt = createdAt ?? DateTime.now();

  bool get isExpired =>
      orgPlanExpiresAt != null && orgPlanExpiresAt!.isBefore(DateTime.now());

  bool get isSuspended => orgStatus == 'suspended';

  // True when the org has been suspended for ≥ 6 months without renewal →
  // the cloud data is eligible for permanent deletion.
  bool get isPastDeletionWindow =>
      isSuspended &&
      orgSuspendedAt != null &&
      DateTime.now().difference(orgSuspendedAt!) >= const Duration(days: 180);

  Organization copyWith({
    String? id,
    String? name,
    String? ownerId,
    String? inviteCode,
    DateTime? createdAt,
    int? licenseCount,
    DateTime? orgPlanExpiresAt,
    String? orgStatus,
    DateTime? orgSuspendedAt,
    bool clearOrgSuspendedAt = false,
  }) {
    return Organization(
      id: id ?? this.id,
      name: name ?? this.name,
      ownerId: ownerId ?? this.ownerId,
      inviteCode: inviteCode ?? this.inviteCode,
      createdAt: createdAt ?? this.createdAt,
      licenseCount: licenseCount ?? this.licenseCount,
      orgPlanExpiresAt: orgPlanExpiresAt ?? this.orgPlanExpiresAt,
      orgStatus: orgStatus ?? this.orgStatus,
      orgSuspendedAt:
          clearOrgSuspendedAt ? null : (orgSuspendedAt ?? this.orgSuspendedAt),
    );
  }
}

/// A member of an [Organization], with denormalized user fields for display.
class OrgMember {
  final String id; // organization_members row id
  final String organizationId;
  final String userId;
  final String role; // 'admin' | 'member'
  final String status; // 'active' | 'suspended'
  final DateTime joinedAt;
  // Denormalized user info (populated at load time).
  final String firstName;
  final String lastName;
  final String? email;
  final String? nickname;
  final String? company;
  final String? biography;
  final String? photoPath;
  final int contactCount;
  final bool canEdit; // may edit any org contact (admin always true)
  final bool canCreate; // may create new contacts (admin always true)
  final bool
      canViewReminders; // may view reminders on shared contacts (admin always true)
  final bool
      canViewHistory; // may view history records authored by other members (admin always true)
  final bool
      canExportContacts; // may export shared org contacts (admin always true)

  OrgMember({
    required this.id,
    required this.organizationId,
    required this.userId,
    required this.role,
    this.status = 'active',
    DateTime? joinedAt,
    required this.firstName,
    required this.lastName,
    this.email,
    this.nickname,
    this.company,
    this.biography,
    this.photoPath,
    this.contactCount = 0,
    this.canEdit = false,
    this.canCreate = true,
    this.canViewReminders = false,
    this.canViewHistory = false,
    this.canExportContacts = false,
  }) : joinedAt = joinedAt ?? DateTime.now();

  String get fullName => '$firstName $lastName'.trim();

  OrgMember copyWith({
    String? id,
    String? organizationId,
    String? userId,
    String? role,
    String? status,
    DateTime? joinedAt,
    String? firstName,
    String? lastName,
    String? email,
    String? nickname,
    String? company,
    String? biography,
    String? photoPath,
    int? contactCount,
    bool? canEdit,
    bool? canCreate,
    bool? canViewReminders,
    bool? canViewHistory,
    bool? canExportContacts,
  }) {
    return OrgMember(
      id: id ?? this.id,
      organizationId: organizationId ?? this.organizationId,
      userId: userId ?? this.userId,
      role: role ?? this.role,
      status: status ?? this.status,
      joinedAt: joinedAt ?? this.joinedAt,
      firstName: firstName ?? this.firstName,
      lastName: lastName ?? this.lastName,
      email: email ?? this.email,
      nickname: nickname ?? this.nickname,
      company: company ?? this.company,
      biography: biography ?? this.biography,
      photoPath: photoPath ?? this.photoPath,
      contactCount: contactCount ?? this.contactCount,
      canEdit: canEdit ?? this.canEdit,
      canCreate: canCreate ?? this.canCreate,
      canViewReminders: canViewReminders ?? this.canViewReminders,
      canViewHistory: canViewHistory ?? this.canViewHistory,
      canExportContacts: canExportContacts ?? this.canExportContacts,
    );
  }
}

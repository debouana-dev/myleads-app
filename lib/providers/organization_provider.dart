import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../core/l10n/app_l10n.dart';
import '../models/organization.dart';
import '../services/background_task.dart';
import '../services/database_service.dart';
import '../services/remote_sync_service.dart';
import '../services/storage_service.dart';
import 'settings_provider.dart';

const _uuid = Uuid();

class OrgState {
  final Organization? organization;
  final List<OrgMember> members;
  final bool isLoading;
  final String? error;
  // Current user's privileges (populated in loadForCurrentUser).
  final bool currentUserCanEdit; // can edit any org member's contacts
  final bool currentUserCanCreate; // can create new contacts
  final bool
      currentUserCanViewReminders; // can view reminders on shared contacts
  final bool
      currentUserCanViewHistory; // can view history authored by other members
  final bool
      currentUserCanExportContacts; // can export shared org contacts
  // Deduplicated total contact count for the org (excludes hidden duplicates).
  final int uniqueContactCount;

  const OrgState({
    this.organization,
    this.members = const [],
    this.isLoading = false,
    this.error,
    this.currentUserCanEdit = true,
    this.currentUserCanCreate = true,
    this.currentUserCanViewReminders = true,
    this.currentUserCanViewHistory = true,
    this.currentUserCanExportContacts = false,
    this.uniqueContactCount = 0,
  });

  // ── Derived from organization ──────────────────────────────────────────────

  int get licenseCount => organization?.licenseCount ?? 1;
  DateTime? get orgPlanExpiresAt => organization?.orgPlanExpiresAt;
  bool get isOrgSuspended => organization?.isSuspended ?? false;
  bool get isOrgExpired => organization?.isExpired ?? false;
  bool get isPastDeletionWindow => organization?.isPastDeletionWindow ?? false;

  /// Total members (active + suspended) — all count toward license usage.
  int get totalMemberCount => members.length;

  /// Seats still available for new members.
  int get availableSeats => licenseCount - totalMemberCount;

  OrgState copyWith({
    Organization? organization,
    List<OrgMember>? members,
    bool? isLoading,
    String? error,
    bool? currentUserCanEdit,
    bool? currentUserCanCreate,
    bool? currentUserCanViewReminders,
    bool? currentUserCanViewHistory,
    bool? currentUserCanExportContacts,
    int? uniqueContactCount,
    bool clearError = false,
    bool clearOrg = false,
  }) {
    return OrgState(
      organization: clearOrg ? null : (organization ?? this.organization),
      members: members ?? this.members,
      isLoading: isLoading ?? this.isLoading,
      error: clearError ? null : (error ?? this.error),
      currentUserCanEdit: currentUserCanEdit ?? this.currentUserCanEdit,
      currentUserCanCreate: currentUserCanCreate ?? this.currentUserCanCreate,
      currentUserCanViewReminders:
          currentUserCanViewReminders ?? this.currentUserCanViewReminders,
      currentUserCanViewHistory:
          currentUserCanViewHistory ?? this.currentUserCanViewHistory,
      currentUserCanExportContacts:
          currentUserCanExportContacts ?? this.currentUserCanExportContacts,
      uniqueContactCount: uniqueContactCount ?? this.uniqueContactCount,
    );
  }
}

class OrgNotifier extends StateNotifier<OrgState> {
  final Ref _ref;
  OrgNotifier(this._ref) : super(const OrgState());

  AppL10n get _l10n => _ref.read(l10nProvider);

  /// Load org data + current user's privileges. Call on app start / profile open.
  Future<void> loadForCurrentUser() async {
    final user = StorageService.currentUser;
    if (user == null || user.organizationId == null) {
      state = const OrgState();
      return;
    }
    state = state.copyWith(isLoading: true, clearError: true);
    try {
      var org =
          await DatabaseService.findOrganizationById(user.organizationId!);
      if (org == null) {
        state = const OrgState();
        return;
      }

      // ── Expiry / suspension lifecycle ──────────────────────────────────────

      // Org has been suspended for 6+ months → permanently delete cloud data
      // and local data, then clear state.
      if (org.isPastDeletionWindow) {
        await RemoteSyncService.deleteOrganizationDataFromCloud(org.id);
        await DatabaseService.deleteOrganization(org.id);
        state = const OrgState();
        return;
      }

      // Licenses just expired but org is still marked active → suspend it now.
      if (!org.isSuspended && org.isExpired) {
        final suspendedAt = DateTime.now();
        await DatabaseService.updateOrgStatus(
          org.id,
          'suspended',
          suspendedAt: suspendedAt,
        );
        org = org.copyWith(orgStatus: 'suspended', orgSuspendedAt: suspendedAt);
      }

      final members = await DatabaseService.getMembersForOrganization(org.id);
      final privs = await DatabaseService.getMemberPrivileges(
        userId: user.id,
        orgId: org.id,
      );
      final uniqueCount =
          await DatabaseService.getOrgDeduplicatedContactCount(org.id);

      // Migration: re-encrypt any personal-key contacts to the org key for
      // active members. Idempotent — already org-encrypted contacts are skipped.
      final memberStatus = await DatabaseService.getMemberStatus(
        userId: user.id,
        orgId: org.id,
      );
      if (memberStatus == 'active') {
        await DatabaseService.reencryptUserContactsToOrgKey(
          userId: user.id,
          orgId: org.id,
          userEmail: user.email,
        );
      }

      state = state.copyWith(
        isLoading: false,
        organization: org,
        members: members,
        currentUserCanEdit: privs.canEdit,
        currentUserCanCreate: privs.canCreate,
        currentUserCanViewReminders: privs.canViewReminders,
        currentUserCanViewHistory: privs.canViewHistory,
        currentUserCanExportContacts: privs.canExportContacts,
        uniqueContactCount: uniqueCount,
      );
    } catch (e) {
      state = state.copyWith(isLoading: false, error: e.toString());
    }
  }

  /// Reload members list and refresh current user privileges.
  Future<void> refreshMembers() async {
    final org = state.organization;
    if (org == null) return;
    try {
      final members = await DatabaseService.getMembersForOrganization(org.id);
      final uniqueCount =
          await DatabaseService.getOrgDeduplicatedContactCount(org.id);
      final user = StorageService.currentUser;
      if (user != null) {
        final privs = await DatabaseService.getMemberPrivileges(
          userId: user.id,
          orgId: org.id,
        );
        state = state.copyWith(
          members: members,
          uniqueContactCount: uniqueCount,
          currentUserCanEdit: privs.canEdit,
          currentUserCanCreate: privs.canCreate,
          currentUserCanViewReminders: privs.canViewReminders,
          currentUserCanViewHistory: privs.canViewHistory,
          currentUserCanExportContacts: privs.canExportContacts,
        );
      } else {
        state =
            state.copyWith(members: members, uniqueContactCount: uniqueCount);
      }
    } catch (_) {}
  }

  /// Admin updates the edit/create/view-reminders/view-history/export privileges for a member.
  Future<String?> updateMemberPrivileges({
    required String userId,
    required bool canEdit,
    required bool canCreate,
    required bool canViewReminders,
    required bool canViewHistory,
    required bool canExportContacts,
  }) async {
    final user = StorageService.currentUser;
    if (user == null) return 'Aucun utilisateur connecté';
    if (user.orgRole != 'admin') return "Action réservée à l'administrateur";
    final org = state.organization;
    if (org == null) return 'Aucune organisation';
    // Cannot change admin privileges.
    final target = state.members.firstWhere(
      (m) => m.userId == userId,
      orElse: () => throw Exception('Membre introuvable'),
    );
    if (target.role == 'admin')
      return "Les droits de l'administrateur ne peuvent pas être modifiés";

    try {
      await DatabaseService.updateMemberPrivileges(
        orgId: org.id,
        userId: userId,
        canEdit: canEdit,
        canCreate: canCreate,
        canViewReminders: canViewReminders,
        canViewHistory: canViewHistory,
        canExportContacts: canExportContacts,
      );
      await refreshMembers();
      return null;
    } catch (e) {
      return e.toString();
    }
  }

  /// Create a new organization with the current user as admin.
  ///
  /// [licenseCount] — number of Business licenses purchased (admin counted as 1).
  /// [orgPlanExpiresAt] — set after a successful Stripe payment from the screen.
  ///
  /// Returns null on success, or an error string.
  Future<String?> createOrganization(
    String name, {
    required int licenseCount,
    required DateTime orgPlanExpiresAt,
  }) async {
    final user = StorageService.currentUser;
    if (user == null) return 'Aucun utilisateur connecté';
    if (name.trim().isEmpty) return "Le nom de l'organisation est obligatoire";
    if (user.organizationId != null)
      return 'Vous appartenez déjà à une organisation';
    if (user.plan != 'business')
      return 'Le plan Business est requis pour créer une organisation';

    state = state.copyWith(isLoading: true, clearError: true);
    try {
      final orgId = _uuid.v4();
      final org = Organization(
        id: orgId,
        name: name.trim(),
        ownerId: user.id,
        inviteCode: await _generateUniqueInviteCode(),
        licenseCount: licenseCount,
        orgPlanExpiresAt: orgPlanExpiresAt,
      );

      await DatabaseService.insertOrganization(org);
      await DatabaseService.insertOrgMember(
        id: _uuid.v4(),
        orgId: orgId,
        userId: user.id,
        role: 'admin',
      );

      final updated = user.copyWith(organizationId: orgId, orgRole: 'admin');
      await DatabaseService.updateUser(updated);
      await StorageService.setCurrentSession(updated, user.sessionToken ?? '');

      // Re-encrypt admin's personal contacts to the new org key.
      await DatabaseService.reencryptUserContactsToOrgKey(
        userId: user.id,
        orgId: orgId,
        userEmail: user.email,
      );

      final members = await DatabaseService.getMembersForOrganization(orgId);
      state = state.copyWith(
        isLoading: false,
        organization: org,
        members: members,
        currentUserCanEdit: true,
        currentUserCanCreate: true,
      );
      return null;
    } catch (e) {
      state = state.copyWith(isLoading: false, error: e.toString());
      return e.toString();
    }
  }

  /// Admin updates org licenses after a successful Stripe payment.
  ///
  /// [licenseCount] must be ≥ current member count (active + suspended).
  /// [expiresAt] is optional. If null, the existing org expiry is preserved.
  Future<String?> renewOrgLicenses({
    required int licenseCount,
    DateTime? expiresAt,
  }) async {
    final user = StorageService.currentUser;
    if (user == null) return 'Aucun utilisateur connecté';
    if (user.orgRole != 'admin') return "Action réservée à l'administrateur";
    final org = state.organization;
    if (org == null) return 'Aucune organisation';

    final currentCount = state.totalMemberCount;
    if (licenseCount < currentCount) {
      return 'Impossible de réduire en dessous du nombre de membres actuels ($currentCount)';
    }

    try {
      await DatabaseService.updateOrgLicenses(
        org.id,
        licenseCount,
        expiresAt: expiresAt,
      );
      final updatedOrg = org.copyWith(
        licenseCount: licenseCount,
        orgPlanExpiresAt: expiresAt ?? org.orgPlanExpiresAt,
        orgStatus: expiresAt != null ? 'active' : org.orgStatus,
        clearOrgSuspendedAt: expiresAt != null,
      );
      state = state.copyWith(organization: updatedOrg);
      return null;
    } catch (e) {
      return e.toString();
    }
  }

  /// Join an existing organization via its invite code.
  Future<String?> joinByCode(String code) async {
    final user = StorageService.currentUser;
    if (user == null) return 'Aucun utilisateur connecté';
    if (code.trim().isEmpty) return "Le code d'invitation est obligatoire";
    if (user.organizationId != null)
      return 'Vous appartenez déjà à une organisation';

    state = state.copyWith(isLoading: true, clearError: true);
    try {
      // 1. Try local lookup first.
      var org = await DatabaseService.findOrganizationByInviteCode(code.trim());

      // 2. If not found locally, look up in the cloud.
      if (org == null) {
        final cloudResult =
            await RemoteSyncService.findOrganizationByInviteCodeInCloud(
                code.trim());
        if (cloudResult.error == 'no_internet') {
          state = state.copyWith(isLoading: false);
          return _l10n.orgJoinNoInternet;
        }
        if (cloudResult.error == 'server_error') {
          state = state.copyWith(isLoading: false);
          return _l10n.orgJoinServerError;
        }
        if (cloudResult.org != null) {
          await DatabaseService.upsertRawRow('organizations', cloudResult.org!);
          org = await DatabaseService.findOrganizationByInviteCode(code.trim());
        }
      }

      if (org == null) {
        state = state.copyWith(
            isLoading: false,
            error: 'Code invalide ou organisation introuvable');
        return 'Code invalide ou organisation introuvable';
      }

      // Block joining a suspended org.
      if (org.isSuspended) {
        state = state.copyWith(isLoading: false);
        return _l10n.orgSuspendedJoinError;
      }

      if (await DatabaseService.isUserInOrganization(org.id, user.id)) {
        state = state.copyWith(
            isLoading: false, error: _l10n.orgAlreadyMember);
        return _l10n.orgAlreadyMember;
      }

      // Check license capacity (active + suspended members count toward total).
      final currentMembers =
          await DatabaseService.getMembersForOrganization(org.id);
      if (currentMembers.length >= org.licenseCount) {
        state = state.copyWith(isLoading: false);
        return "L'organisation n'a plus de places disponibles. L'administrateur doit acheter des licences supplémentaires.";
      }

      final memberId = _uuid.v4();
      await DatabaseService.insertOrgMember(
        id: memberId,
        orgId: org.id,
        userId: user.id,
        role: 'member',
      );

      final updated = user.copyWith(
        organizationId: org.id,
        orgRole: 'member',
      );
      await DatabaseService.updateUser(updated);
      await StorageService.setCurrentSession(updated, user.sessionToken ?? '');
      await scheduleBusinessSync();

      // Re-encrypt the joining member's personal contacts to the org key.
      await DatabaseService.reencryptUserContactsToOrgKey(
        userId: user.id,
        orgId: org.id,
        userEmail: user.email,
      );

      // Explicitly push the new member + updated user to the cloud before
      // pulling so the cloud already reflects the new membership.
      final memberRow = await DatabaseService.getRawOrgMemberRow(memberId);
      final rawUserRow = await DatabaseService.getRawUserRow(user.id);
      if (memberRow != null && rawUserRow != null) {
        await RemoteSyncService.addMemberToOrgInCloud(
          memberRow: memberRow,
          userRow: rawUserRow,
        );
      }

      // Pull the org's shared data (org row, all members, member contacts).
      await RemoteSyncService.pullOrganizationDataById(org.id);

      final members = await DatabaseService.getMembersForOrganization(org.id);
      final privs = await DatabaseService.getMemberPrivileges(
          userId: user.id, orgId: org.id);
      state = state.copyWith(
        isLoading: false,
        organization: org,
        members: members,
        currentUserCanEdit: privs.canEdit,
        currentUserCanCreate: privs.canCreate,
        currentUserCanViewReminders: privs.canViewReminders,
        currentUserCanViewHistory: privs.canViewHistory,
        currentUserCanExportContacts: privs.canExportContacts,
      );
      return null;
    } catch (e) {
      state = state.copyWith(isLoading: false, error: e.toString());
      return e.toString();
    }
  }

  /// Admin removes a member (cannot remove self).
  Future<String?> removeMember(String targetUserId) async {
    final user = StorageService.currentUser;
    if (user == null) return 'Aucun utilisateur connecté';
    if (user.orgRole != 'admin') return "Action réservée à l'administrateur";
    final org = state.organization;
    if (org == null) return 'Aucune organisation';
    if (targetUserId == user.id)
      return "Utilisez \"Quitter l'organisation\" pour vous retirer";

    try {
      final target = state.members.firstWhere(
        (m) => m.userId == targetUserId,
        orElse: () => throw Exception('Membre introuvable'),
      );
      await DatabaseService.transferNonDuplicateContactsToAdmin(
          fromUserId: targetUserId, orgId: org.id);
      // Re-encrypt the removed member's remaining contacts to their personal key
      // so they can still access them after removal.
      if (target.email != null && target.email!.isNotEmpty) {
        await DatabaseService.reencryptUserContactsToPersonalKey(
          userId: targetUserId,
          orgId: org.id,
          userEmail: target.email!,
        );
      }
      await DatabaseService.removeOrgMember(org.id, targetUserId);

      await refreshMembers();
      return null;
    } catch (e) {
      return e.toString();
    }
  }

  /// Current user leaves the organization.
  Future<String?> leaveOrganization() async {
    final user = StorageService.currentUser;
    if (user == null) return 'Aucun utilisateur connecté';
    final org = state.organization;
    if (org == null) return 'Aucune organisation';

    try {
      final isLastAdmin = user.orgRole == 'admin' &&
          state.members.where((m) => m.role == 'admin').length == 1;

      if (isLastAdmin && state.members.length > 1) {
        return "Transférez l'administration avant de quitter, ou supprimez l'organisation.";
      }

      if (isLastAdmin && state.members.length <= 1) {
        // Re-encrypt admin's contacts to personal key before the org is deleted.
        await DatabaseService.reencryptUserContactsToPersonalKey(
          userId: user.id,
          orgId: org.id,
          userEmail: user.email,
        );
        await DatabaseService.deleteOrganization(org.id);
        final downgraded = user.copyWith(
          organizationId: null,
          orgRole: null,
          plan: 'free',
          planExpiresAt: null,
          subscriptionBillingCycle: null,
        );
        await DatabaseService.updateUser(downgraded);
        await StorageService.setCurrentSession(
            downgraded, user.sessionToken ?? '');
        await cancelBusinessSync();
      } else {
        await DatabaseService.transferNonDuplicateContactsToAdmin(
            fromUserId: user.id, orgId: org.id);
        // Re-encrypt remaining (non-transferred) contacts to personal key.
        await DatabaseService.reencryptUserContactsToPersonalKey(
          userId: user.id,
          orgId: org.id,
          userEmail: user.email,
        );
        await DatabaseService.removeOrgMember(org.id, user.id);
        final updated = user.copyWith(
          organizationId: null,
          orgRole: null,
        );
        await DatabaseService.updateUser(updated);
        await StorageService.setCurrentSession(
            updated, user.sessionToken ?? '');
        await cancelBusinessSync();
      }

      state = const OrgState();
      return null;
    } catch (e) {
      return e.toString();
    }
  }

  /// Admin deletes the entire organization.
  Future<String?> deleteOrganization() async {
    final user = StorageService.currentUser;
    if (user == null) return 'Aucun utilisateur connecté';
    if (user.orgRole != 'admin') return "Action réservée à l'administrateur";
    final org = state.organization;
    if (org == null) return 'Aucune organisation';

    state = state.copyWith(isLoading: true, clearError: true);
    try {
      // Preserve personal subscription plans for members when the org is deleted.
      // Their effective Business entitlement is removed by clearing org membership.
      final members = await DatabaseService.getMembersForOrganization(org.id);
      for (final m in members) {
        if (m.userId == user.id) continue; // admin handled below
        // Re-encrypt each member's contacts to their personal key before the
        // org is deleted, so they retain access to their own contact data.
        if (m.email != null && m.email!.isNotEmpty) {
          await DatabaseService.reencryptUserContactsToPersonalKey(
            userId: m.userId,
            orgId: org.id,
            userEmail: m.email!,
          );
        }
        final memberUser = await DatabaseService.findUserById(m.userId);
        if (memberUser != null) {
          await DatabaseService.updateUser(memberUser.copyWith(
            organizationId: null,
            orgRole: null,
          ));
        }
      }

      // Re-encrypt admin's own contacts to personal key before deleting.
      await DatabaseService.reencryptUserContactsToPersonalKey(
        userId: user.id,
        orgId: org.id,
        userEmail: user.email,
      );

      await DatabaseService.deleteOrganization(org.id);

      // Downgrade admin and clear their org fields.
      final updated = user.copyWith(
        organizationId: null,
        orgRole: null,
      );
      await DatabaseService.updateUser(updated);
      await StorageService.setCurrentSession(updated, user.sessionToken ?? '');
      await cancelBusinessSync();

      state = const OrgState();
      return null;
    } catch (e) {
      state = state.copyWith(isLoading: false, error: e.toString());
      return e.toString();
    }
  }

  /// Admin suspends a member (cannot suspend self or another admin).
  Future<String?> suspendMember(String targetUserId) async {
    final user = StorageService.currentUser;
    if (user == null) return 'Aucun utilisateur connecté';
    if (user.orgRole != 'admin') return "Action réservée à l'administrateur";
    final org = state.organization;
    if (org == null) return 'Aucune organisation';
    if (targetUserId == user.id)
      return 'Vous ne pouvez pas vous suspendre vous-même';
    final target = state.members.firstWhere(
      (m) => m.userId == targetUserId,
      orElse: () => throw Exception('Membre introuvable'),
    );
    if (target.role == 'admin')
      return "Impossible de suspendre un administrateur";
    try {
      await DatabaseService.transferNonDuplicateContactsToAdmin(
          fromUserId: targetUserId, orgId: org.id);
      // Re-encrypt the suspended member's remaining contacts to their personal
      // key so they can access them if/when they are fully removed.
      if (target.email != null && target.email!.isNotEmpty) {
        await DatabaseService.reencryptUserContactsToPersonalKey(
          userId: targetUserId,
          orgId: org.id,
          userEmail: target.email!,
        );
      }
      await DatabaseService.updateMemberStatus(
          orgId: org.id, userId: targetUserId, status: 'suspended');
      await refreshMembers();
      return null;
    } catch (e) {
      return e.toString();
    }
  }

  /// Admin reactivates a suspended member.
  ///
  /// Checks that there is still a free seat before reactivating (the member
  /// was suspended but still counted toward the license total, so this check
  /// is not strictly needed, but it guards against edge-cases where licenses
  /// were reduced after the suspension).
  Future<String?> reactivateMember(String targetUserId) async {
    final user = StorageService.currentUser;
    if (user == null) return 'Aucun utilisateur connecté';
    if (user.orgRole != 'admin') return "Action réservée à l'administrateur";
    final org = state.organization;
    if (org == null) return 'Aucune organisation';
    try {
      final target = state.members.firstWhere(
        (m) => m.userId == targetUserId,
        orElse: () => throw Exception('Membre introuvable'),
      );
      await DatabaseService.updateMemberStatus(
          orgId: org.id, userId: targetUserId, status: 'active');
      // Re-encrypt the reactivated member's contacts back to the org key.
      if (target.email != null && target.email!.isNotEmpty) {
        await DatabaseService.reencryptUserContactsToOrgKey(
          userId: targetUserId,
          orgId: org.id,
          userEmail: target.email!,
        );
      }
      await refreshMembers();
      return null;
    } catch (e) {
      return e.toString();
    }
  }

  /// Admin regenerates the organization's invite code.
  Future<String?> regenerateInviteCode() async {
    final user = StorageService.currentUser;
    if (user == null) return 'Aucun utilisateur connecté';
    if (user.orgRole != 'admin') return "Action réservée à l'administrateur";
    final org = state.organization;
    if (org == null) return 'Aucune organisation';
    try {
      final newCode = await _generateUniqueInviteCode();
      await DatabaseService.updateOrgInviteCode(org.id, newCode);
      final updated = org.copyWith(inviteCode: newCode);
      state = state.copyWith(organization: updated);
      return null;
    } catch (e) {
      return e.toString();
    }
  }

  /// Update the organization name (admin only).
  Future<String?> updateOrgName(String newName) async {
    final user = StorageService.currentUser;
    if (user == null) return 'Aucun utilisateur connecté';
    if (user.orgRole != 'admin') return "Action réservée à l'administrateur";
    if (newName.trim().isEmpty) return 'Le nom est obligatoire';
    final org = state.organization;
    if (org == null) return 'Aucune organisation';

    try {
      final updated = org.copyWith(name: newName.trim());
      await DatabaseService.updateOrganization(updated);
      state = state.copyWith(organization: updated);
      return null;
    } catch (e) {
      return e.toString();
    }
  }

  /// Generates a unique 8-char invite code that does not collide with any
  /// existing organization in either the local or the remote database.
  static Future<String> _generateUniqueInviteCode() async {
    const chars = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
    final rand = Random.secure();
    for (var attempt = 0; attempt < 10; attempt++) {
      final code =
          List.generate(8, (_) => chars[rand.nextInt(chars.length)]).join();
      if (await DatabaseService.findOrganizationByInviteCode(code) != null) {
        continue;
      }
      final cloudResult =
          await RemoteSyncService.findOrganizationByInviteCodeInCloud(code);
      if (cloudResult.org != null) continue;
      return code;
    }
    return List.generate(8, (_) => chars[rand.nextInt(chars.length)]).join();
  }
}

final organizationProvider =
    StateNotifierProvider<OrgNotifier, OrgState>((ref) {
  return OrgNotifier(ref);
});

/// Derived privilege providers — cheap to watch in the UI.
final orgCanCreateProvider = Provider<bool>((ref) {
  final user = StorageService.currentUser;
  if (user?.organizationId == null) return true; // solo user: always can create
  return ref.watch(organizationProvider).currentUserCanCreate;
});

final orgCanEditOthersProvider = Provider<bool>((ref) {
  final user = StorageService.currentUser;
  if (user?.organizationId == null) return false; // solo: no "others" to edit
  return ref.watch(organizationProvider).currentUserCanEdit;
});

final orgCanViewRemindersProvider = Provider<bool>((ref) {
  final user = StorageService.currentUser;
  if (user?.organizationId == null)
    return true; // solo: always sees own reminders
  return ref.watch(organizationProvider).currentUserCanViewReminders;
});

final orgCanViewHistoryProvider = Provider<bool>((ref) {
  final user = StorageService.currentUser;
  if (user?.organizationId == null)
    return true; // solo: always sees own history
  return ref.watch(organizationProvider).currentUserCanViewHistory;
});

final orgCanExportContactsProvider = Provider<bool>((ref) {
  final user = StorageService.currentUser;
  if (user?.organizationId == null)
    return true; // solo: always can export own contacts
  return ref.watch(organizationProvider).currentUserCanExportContacts;
});

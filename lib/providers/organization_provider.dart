import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../models/organization.dart';
import '../services/database_service.dart';
import '../services/storage_service.dart';

const _uuid = Uuid();

class OrgState {
  final Organization? organization;
  final List<OrgMember> members;
  final bool isLoading;
  final String? error;
  // Current user's privileges (populated in loadForCurrentUser).
  final bool currentUserCanEdit;         // can edit any org member's contacts
  final bool currentUserCanCreate;       // can create new contacts
  final bool currentUserCanViewReminders; // can view reminders on shared contacts
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
    this.uniqueContactCount = 0,
  });

  OrgState copyWith({
    Organization? organization,
    List<OrgMember>? members,
    bool? isLoading,
    String? error,
    bool? currentUserCanEdit,
    bool? currentUserCanCreate,
    bool? currentUserCanViewReminders,
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
      uniqueContactCount: uniqueContactCount ?? this.uniqueContactCount,
    );
  }
}

class OrgNotifier extends StateNotifier<OrgState> {
  OrgNotifier() : super(const OrgState());

  /// Load org data + current user's privileges. Call on app start / profile open.
  Future<void> loadForCurrentUser() async {
    final user = StorageService.currentUser;
    if (user == null || user.organizationId == null) {
      state = const OrgState();
      return;
    }
    state = state.copyWith(isLoading: true, clearError: true);
    try {
      final org = await DatabaseService.findOrganizationById(user.organizationId!);
      if (org == null) {
        state = const OrgState();
        return;
      }
      final members = await DatabaseService.getMembersForOrganization(org.id);
      final privs = await DatabaseService.getMemberPrivileges(
        userId: user.id,
        orgId: org.id,
      );
      final uniqueCount =
          await DatabaseService.getOrgDeduplicatedContactCount(org.id);
      state = state.copyWith(
        isLoading: false,
        organization: org,
        members: members,
        currentUserCanEdit: privs.canEdit,
        currentUserCanCreate: privs.canCreate,
        currentUserCanViewReminders: privs.canViewReminders,
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
        );
      } else {
        state = state.copyWith(members: members, uniqueContactCount: uniqueCount);
      }
    } catch (_) {}
  }

  /// Admin updates the edit/create/view-reminders privileges for a member.
  Future<String?> updateMemberPrivileges({
    required String userId,
    required bool canEdit,
    required bool canCreate,
    required bool canViewReminders,
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
    if (target.role == 'admin') return "Les droits de l'administrateur ne peuvent pas être modifiés";

    try {
      await DatabaseService.updateMemberPrivileges(
        orgId: org.id,
        userId: userId,
        canEdit: canEdit,
        canCreate: canCreate,
        canViewReminders: canViewReminders,
      );
      // Refresh members so UI reflects the change.
      await refreshMembers();
      return null;
    } catch (e) {
      return e.toString();
    }
  }

  /// Create a new organization with the current user as admin.
  Future<String?> createOrganization(String name) async {
    final user = StorageService.currentUser;
    if (user == null) return 'Aucun utilisateur connecté';
    if (name.trim().isEmpty) return "Le nom de l'organisation est obligatoire";
    if (user.organizationId != null) return 'Vous appartenez déjà à une organisation';

    state = state.copyWith(isLoading: true, clearError: true);
    try {
      final orgId = _uuid.v4();
      final org = Organization(
        id: orgId,
        name: name.trim(),
        ownerId: user.id,
        inviteCode: _generateInviteCode(),
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

  /// Join an existing organization via its invite code.
  Future<String?> joinByCode(String code) async {
    final user = StorageService.currentUser;
    if (user == null) return 'Aucun utilisateur connecté';
    if (code.trim().isEmpty) return "Le code d'invitation est obligatoire";
    if (user.organizationId != null) return 'Vous appartenez déjà à une organisation';

    state = state.copyWith(isLoading: true, clearError: true);
    try {
      final org = await DatabaseService.findOrganizationByInviteCode(code.trim());
      if (org == null) {
        state = state.copyWith(isLoading: false, error: 'Code invalide ou organisation introuvable');
        return 'Code invalide ou organisation introuvable';
      }

      if (await DatabaseService.isUserInOrganization(org.id, user.id)) {
        state = state.copyWith(isLoading: false, error: 'Vous êtes déjà membre de cette organisation');
        return 'Vous êtes déjà membre de cette organisation';
      }

      await DatabaseService.insertOrgMember(
        id: _uuid.v4(),
        orgId: org.id,
        userId: user.id,
        role: 'member',
      );

      final updated = user.copyWith(organizationId: org.id, orgRole: 'member');
      await DatabaseService.updateUser(updated);
      await StorageService.setCurrentSession(updated, user.sessionToken ?? '');

      final members = await DatabaseService.getMembersForOrganization(org.id);
      final privs = await DatabaseService.getMemberPrivileges(userId: user.id, orgId: org.id);
      state = state.copyWith(
        isLoading: false,
        organization: org,
        members: members,
        currentUserCanEdit: privs.canEdit,
        currentUserCanCreate: privs.canCreate,
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
    if (targetUserId == user.id) return "Utilisez \"Quitter l'organisation\" pour vous retirer";

    try {
      // Only transfer non-duplicate contacts to admin. Duplicate contacts
      // (same phone/email as another active member's contact) stay with the
      // removed member so they can still see them as a solo user.
      await DatabaseService.transferNonDuplicateContactsToAdmin(
          fromUserId: targetUserId, orgId: org.id);
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
      final isLastAdmin =
          user.orgRole == 'admin' && state.members.where((m) => m.role == 'admin').length == 1;

      if (isLastAdmin && state.members.length > 1) {
        return "Transférez l'administration avant de quitter, ou supprimez l'organisation.";
      }

      if (isLastAdmin && state.members.length <= 1) {
        await DatabaseService.deleteOrganization(org.id);
        final refreshed = await DatabaseService.findUserById(user.id);
        if (refreshed != null) {
          await StorageService.setCurrentSession(refreshed, refreshed.sessionToken ?? '');
        }
      } else {
        // Only transfer non-duplicate contacts to admin before leaving so they
        // remain visible in the org workspace. Duplicate contacts stay with
        // the departing member for their personal record.
        await DatabaseService.transferNonDuplicateContactsToAdmin(
            fromUserId: user.id, orgId: org.id);
        await DatabaseService.removeOrgMember(org.id, user.id);
        final updated = user.copyWith(organizationId: null, orgRole: null);
        await DatabaseService.updateUser(updated);
        await StorageService.setCurrentSession(updated, user.sessionToken ?? '');
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
      await DatabaseService.deleteOrganization(org.id);
      final refreshed = await DatabaseService.findUserById(user.id);
      if (refreshed != null) {
        await StorageService.setCurrentSession(refreshed, refreshed.sessionToken ?? '');
      }
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
    if (targetUserId == user.id) return 'Vous ne pouvez pas vous suspendre vous-même';
    final target = state.members.firstWhere(
      (m) => m.userId == targetUserId,
      orElse: () => throw Exception('Membre introuvable'),
    );
    if (target.role == 'admin') return "Impossible de suspendre un administrateur";
    try {
      // Only transfer non-duplicate contacts to admin. Contacts that are
      // duplicates of an existing active member's contact stay with the
      // suspended member so they can see them while suspended.
      await DatabaseService.transferNonDuplicateContactsToAdmin(
          fromUserId: targetUserId, orgId: org.id);
      await DatabaseService.updateMemberStatus(
          orgId: org.id, userId: targetUserId, status: 'suspended');
      await refreshMembers();
      return null;
    } catch (e) {
      return e.toString();
    }
  }

  /// Admin reactivates a suspended member.
  Future<String?> reactivateMember(String targetUserId) async {
    final user = StorageService.currentUser;
    if (user == null) return 'Aucun utilisateur connecté';
    if (user.orgRole != 'admin') return "Action réservée à l'administrateur";
    final org = state.organization;
    if (org == null) return 'Aucune organisation';
    try {
      await DatabaseService.updateMemberStatus(
          orgId: org.id, userId: targetUserId, status: 'active');
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
      final newCode = _generateInviteCode();
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

  static String _generateInviteCode() {
    const chars = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
    final rand = Random.secure();
    return List.generate(8, (_) => chars[rand.nextInt(chars.length)]).join();
  }
}

final organizationProvider = StateNotifierProvider<OrgNotifier, OrgState>((ref) {
  return OrgNotifier();
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
  if (user?.organizationId == null) return true; // solo: always sees own reminders
  return ref.watch(organizationProvider).currentUserCanViewReminders;
});

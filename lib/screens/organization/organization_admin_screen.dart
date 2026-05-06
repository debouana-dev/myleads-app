import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../core/l10n/app_l10n.dart';
import '../../core/theme/app_colors.dart';
import '../../models/organization.dart';
import '../../providers/organization_provider.dart';
import '../../services/photo_storage_service.dart';
import '../../services/storage_service.dart';

class OrganizationAdminScreen extends ConsumerStatefulWidget {
  const OrganizationAdminScreen({super.key});

  @override
  ConsumerState<OrganizationAdminScreen> createState() =>
      _OrganizationAdminScreenState();
}

class _OrganizationAdminScreenState
    extends ConsumerState<OrganizationAdminScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(organizationProvider.notifier).loadForCurrentUser();
    });
  }

  // ─── Helpers ─────────────────────────────────────────────────────────────

  void _showSnack(String msg, {bool error = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      backgroundColor: error ? AppColors.hot : AppColors.success,
      duration: const Duration(seconds: 2),
    ));
  }

  Future<bool?> _confirm({
    required String title,
    required String body,
    required String confirmLabel,
    Color confirmColor = AppColors.hot,
  }) {
    final l10n = ref.read(l10nProvider);
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surfaceColor(context),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text(title,
            style: TextStyle(
                color: AppColors.onSurface(context),
                fontWeight: FontWeight.w700,
                fontSize: 17)),
        content: Text(body,
            style: TextStyle(color: AppColors.secondary(context))),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(l10n.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(confirmLabel,
                style: TextStyle(color: confirmColor, fontWeight: FontWeight.w700)),
          ),
        ],
      ),
    );
  }

  // ─── Individual actions ───────────────────────────────────────────────────

  Future<void> _copyCode(String code) async {
    await Clipboard.setData(ClipboardData(text: code));
    _showSnack(ref.read(l10nProvider).codeCopied, error: false);
  }

  Future<void> _doRegenerateCode() async {
    final l10n = ref.read(l10nProvider);
    final ok = await _confirm(
      title: l10n.regenerateCodeTitle,
      body: l10n.regenerateCodeConfirm,
      confirmLabel: l10n.regenerateCode,
      confirmColor: AppColors.warm,
    );
    if (ok != true || !mounted) return;
    final err =
        await ref.read(organizationProvider.notifier).regenerateInviteCode();
    if (!mounted) return;
    if (err != null) {
      _showSnack(err, error: true);
    } else {
      _showSnack(l10n.codeRegenerated);
    }
  }

  Future<void> _doRename(Organization org) async {
    final l10n = ref.read(l10nProvider);
    final ctrl = TextEditingController(text: org.name);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surfaceColor(context),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text(l10n.orgSettingsTitle,
            style: TextStyle(
                color: AppColors.onSurface(context),
                fontWeight: FontWeight.w700)),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          cursorColor: AppColors.primary,
          style: TextStyle(color: AppColors.onSurface(context)),
          decoration: InputDecoration(hintText: l10n.orgNameHint),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: Text(l10n.cancel)),
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: Text(l10n.saveButton,
                  style: const TextStyle(
                      color: AppColors.primary, fontWeight: FontWeight.w700))),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final err =
        await ref.read(organizationProvider.notifier).updateOrgName(ctrl.text);
    if (!mounted) return;
    if (err != null) {
      _showSnack(err, error: true);
    } else {
      _showSnack(l10n.orgNameUpdated);
    }
  }

  Future<void> _doDeleteOrg() async {
    final l10n = ref.read(l10nProvider);
    final ok = await _confirm(
      title: l10n.deleteOrgTitle,
      body: l10n.deleteOrgConfirm,
      confirmLabel: l10n.deleteOrg,
    );
    if (ok != true || !mounted) return;
    final err =
        await ref.read(organizationProvider.notifier).deleteOrganization();
    if (!mounted) return;
    if (err != null) {
      _showSnack(err, error: true);
    } else {
      _showSnack(l10n.orgDeletedSuccess);
      context.pop();
    }
  }

  Future<void> _doLeaveOrg() async {
    final l10n = ref.read(l10nProvider);
    final ok = await _confirm(
      title: l10n.leaveOrgTitle,
      body: l10n.leaveOrgConfirm,
      confirmLabel: l10n.leaveOrg,
    );
    if (ok != true || !mounted) return;
    final err =
        await ref.read(organizationProvider.notifier).leaveOrganization();
    if (!mounted) return;
    if (err != null) {
      _showSnack(err, error: true);
    } else {
      _showSnack(l10n.orgLeftSuccess);
      context.pop();
    }
  }

  // ─── Member management sheet ──────────────────────────────────────────────

  void _openMemberSheet(OrgMember member) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.surfaceColor(context),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (_) => _MemberManagementSheet(
        member: member,
        onToggleEdit: (val) => _updatePrivileges(member,
            canEdit: val,
            canCreate: member.canCreate,
            canViewReminders: member.canViewReminders),
        onToggleCreate: (val) => _updatePrivileges(member,
            canEdit: member.canEdit,
            canCreate: val,
            canViewReminders: member.canViewReminders),
        onToggleViewReminders: (val) => _updatePrivileges(member,
            canEdit: member.canEdit,
            canCreate: member.canCreate,
            canViewReminders: val),
        onSuspend: member.status == 'active'
            ? () => _doSuspend(member)
            : () => _doReactivate(member),
        onRemove: () => _doRemove(member),
      ),
    );
  }

  Future<void> _updatePrivileges(OrgMember member,
      {required bool canEdit,
      required bool canCreate,
      required bool canViewReminders}) async {
    final l10n = ref.read(l10nProvider);
    final err = await ref
        .read(organizationProvider.notifier)
        .updateMemberPrivileges(
          userId: member.userId,
          canEdit: canEdit,
          canCreate: canCreate,
          canViewReminders: canViewReminders,
        );
    if (!mounted) return;
    if (err != null) {
      _showSnack(err, error: true);
    } else {
      _showSnack(l10n.privilegeUpdated);
    }
  }

  Future<void> _doSuspend(OrgMember member) async {
    Navigator.of(context).pop(); // close sheet first
    final l10n = ref.read(l10nProvider);
    final ok = await _confirm(
      title: l10n.suspendMemberTitle,
      body: l10n.suspendMemberConfirm(member.fullName),
      confirmLabel: l10n.suspendMember,
    );
    if (ok != true || !mounted) return;
    final err =
        await ref.read(organizationProvider.notifier).suspendMember(member.userId);
    if (!mounted) return;
    if (err != null) {
      _showSnack(err, error: true);
    } else {
      _showSnack(l10n.memberSuspendedSuccess);
    }
  }

  Future<void> _doReactivate(OrgMember member) async {
    Navigator.of(context).pop();
    final l10n = ref.read(l10nProvider);
    final ok = await _confirm(
      title: l10n.reactivateMemberTitle,
      body: l10n.reactivateMemberConfirm(member.fullName),
      confirmLabel: l10n.reactivateMember,
      confirmColor: AppColors.success,
    );
    if (ok != true || !mounted) return;
    final err = await ref
        .read(organizationProvider.notifier)
        .reactivateMember(member.userId);
    if (!mounted) return;
    if (err != null) {
      _showSnack(err, error: true);
    } else {
      _showSnack(l10n.memberReactivatedSuccess);
    }
  }

  Future<void> _doRemove(OrgMember member) async {
    Navigator.of(context).pop();
    final l10n = ref.read(l10nProvider);
    final ok = await _confirm(
      title: l10n.removeMemberTitle,
      body: l10n.removeMemberConfirm(member.fullName),
      confirmLabel: l10n.removeMember,
    );
    if (ok != true || !mounted) return;
    final err = await ref
        .read(organizationProvider.notifier)
        .removeMember(member.userId);
    if (!mounted) return;
    if (err != null) {
      _showSnack(err, error: true);
    } else {
      _showSnack(l10n.memberRemovedSuccess);
    }
  }

  // ─── Build ────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final l10n = ref.watch(l10nProvider);
    final orgState = ref.watch(organizationProvider);
    final currentUserId = StorageService.currentUser?.id ?? '';
    final currentUserRole = StorageService.currentUser?.orgRole ?? 'member';
    final isAdmin = currentUserRole == 'admin';

    if (orgState.isLoading) {
      return Scaffold(
        backgroundColor: AppColors.bg(context),
        appBar: _appBar(l10n, null, isAdmin: false),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    final org = orgState.organization;
    if (org == null) {
      return Scaffold(
        backgroundColor: AppColors.bg(context),
        appBar: _appBar(l10n, null, isAdmin: false),
        body: Center(
          child: Text(l10n.noOrgMembers,
              style: TextStyle(color: AppColors.secondary(context))),
        ),
      );
    }

    final members = orgState.members;
    final activeCount = members.where((m) => m.status == 'active').length;
    final totalContacts = orgState.uniqueContactCount;

    return Scaffold(
      backgroundColor: AppColors.bg(context),
      appBar: _appBar(l10n, org, isAdmin: isAdmin),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
        children: [
          // ── Org stats card ────────────────────────────────────────────────
          _OrgStatsCard(
            orgName: org.name,
            createdAt: org.createdAt,
            activeMembers: activeCount,
            totalContacts: totalContacts,
            l10n: l10n,
          ),
          const SizedBox(height: 20),

          // ── Invite code card (admin only) ─────────────────────────────────
          if (isAdmin) ...[
            _SectionLabel(l10n.inviteCodeLabel),
            const SizedBox(height: 10),
            _InviteCodeCard(
              code: org.inviteCode,
              onCopy: () => _copyCode(org.inviteCode),
              onRegenerate: _doRegenerateCode,
              l10n: l10n,
            ),
            const SizedBox(height: 24),
          ],

          // ── Members list ──────────────────────────────────────────────────
          _SectionLabel('${l10n.orgMembersTitle} (${members.length})'),
          const SizedBox(height: 10),
          if (members.isEmpty)
            Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 24),
                child: Text(l10n.noOrgMembers,
                    style:
                        TextStyle(color: AppColors.secondary(context))),
              ),
            )
          else
            ...members.map(
              (m) => _MemberCard(
                member: m,
                isCurrentUser: m.userId == currentUserId,
                isAdmin: isAdmin,
                l10n: l10n,
                onTap: isAdmin && m.userId != currentUserId && m.role != 'admin'
                    ? () => _openMemberSheet(m)
                    : null,
              ),
            ),

          const SizedBox(height: 24),

          // ── Leave / danger zone ───────────────────────────────────────────
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              style: OutlinedButton.styleFrom(
                foregroundColor: AppColors.hot,
                side: const BorderSide(color: AppColors.hot),
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12)),
              ),
              onPressed: _doLeaveOrg,
              icon: const Icon(Icons.logout_rounded, size: 18),
              label: Text(l10n.leaveOrg),
            ),
          ),
        ],
      ),
    );
  }

  AppBar _appBar(AppL10n l10n, Organization? org, {required bool isAdmin}) {
    return AppBar(
      backgroundColor: AppColors.primary,
      foregroundColor: Colors.white,
      title: Text(
        org?.name ?? l10n.orgAdminMenuTitle,
        style:
            const TextStyle(color: Colors.white, fontWeight: FontWeight.w700),
      ),
      leading: IconButton(
        icon: const Icon(Icons.arrow_back_rounded),
        onPressed: () => context.pop(),
      ),
      actions: isAdmin && org != null
          ? [
              PopupMenuButton<String>(
                icon: const Icon(Icons.more_vert_rounded, color: Colors.white),
                onSelected: (v) {
                  if (v == 'rename') _doRename(org);
                  if (v == 'regen') _doRegenerateCode();
                  if (v == 'delete') _doDeleteOrg();
                },
                itemBuilder: (_) => [
                  PopupMenuItem(
                    value: 'rename',
                    child: Row(children: [
                      const Icon(Icons.edit_rounded, size: 18),
                      const SizedBox(width: 10),
                      Text(l10n.orgSettingsTitle),
                    ]),
                  ),
                  PopupMenuItem(
                    value: 'regen',
                    child: Row(children: [
                      const Icon(Icons.refresh_rounded,
                          size: 18, color: AppColors.warm),
                      const SizedBox(width: 10),
                      Text(l10n.regenerateCode,
                          style: const TextStyle(color: AppColors.warm)),
                    ]),
                  ),
                  const PopupMenuDivider(),
                  PopupMenuItem(
                    value: 'delete',
                    child: Row(children: [
                      const Icon(Icons.delete_outline_rounded,
                          size: 18, color: AppColors.hot),
                      const SizedBox(width: 10),
                      Text(l10n.deleteOrg,
                          style: const TextStyle(color: AppColors.hot)),
                    ]),
                  ),
                ],
              ),
            ]
          : null,
    );
  }
}

// ─── Org stats card ───────────────────────────────────────────────────────────

class _OrgStatsCard extends StatelessWidget {
  const _OrgStatsCard({
    required this.orgName,
    required this.createdAt,
    required this.activeMembers,
    required this.totalContacts,
    required this.l10n,
  });

  final String orgName;
  final DateTime createdAt;
  final int activeMembers;
  final int totalContacts;
  final AppL10n l10n;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: AppColors.primaryGradient,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Icon(Icons.corporate_fare_rounded,
                    color: Colors.white, size: 22),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      orgName,
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 18,
                          fontWeight: FontWeight.w800),
                      overflow: TextOverflow.ellipsis,
                    ),
                    Text(
                      DateFormat('dd MMM yyyy').format(createdAt),
                      style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.65),
                          fontSize: 12),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: _StatChip(
                  icon: Icons.people_rounded,
                  label: l10n.orgActiveMembers(activeMembers),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _StatChip(
                  icon: Icons.contacts_rounded,
                  label: l10n.orgTotalContacts(totalContacts),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _StatChip extends StatelessWidget {
  const _StatChip({required this.icon, required this.label});
  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          Icon(icon, color: Colors.white, size: 14),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              label,
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 12,
                  fontWeight: FontWeight.w600),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Invite code card ─────────────────────────────────────────────────────────

class _InviteCodeCard extends StatelessWidget {
  const _InviteCodeCard({
    required this.code,
    required this.onCopy,
    required this.onRegenerate,
    required this.l10n,
  });

  final String code;
  final VoidCallback onCopy;
  final VoidCallback onRegenerate;
  final AppL10n l10n;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surfaceColor(context),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.borderColor(context)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(l10n.inviteInfo,
              style: TextStyle(
                  fontSize: 12, color: AppColors.secondary(context))),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: Container(
                  padding: const EdgeInsets.symmetric(
                      vertical: 14, horizontal: 16),
                  decoration: BoxDecoration(
                    color: AppColors.inputBackground(context),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    code,
                    style: const TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 6,
                      color: AppColors.primary,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              GestureDetector(
                onTap: onCopy,
                child: Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    gradient: AppColors.primaryGradient,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Icon(Icons.copy_rounded,
                      color: Colors.white, size: 20),
                ),
              ),
              const SizedBox(width: 8),
              GestureDetector(
                onTap: onRegenerate,
                child: Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: AppColors.warm.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Icon(Icons.refresh_rounded,
                      color: AppColors.warm, size: 20),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// ─── Section label ────────────────────────────────────────────────────────────

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text.toUpperCase(),
      style: TextStyle(
        fontSize: 11,
        fontWeight: FontWeight.w700,
        color: AppColors.hint(context),
        letterSpacing: 1,
      ),
    );
  }
}

// ─── Member card ──────────────────────────────────────────────────────────────

class _MemberCard extends StatelessWidget {
  const _MemberCard({
    required this.member,
    required this.isCurrentUser,
    required this.isAdmin,
    required this.l10n,
    this.onTap,
  });

  final OrgMember member;
  final bool isCurrentUser;
  final bool isAdmin;
  final AppL10n l10n;
  final VoidCallback? onTap;

  String _initials(String name) {
    final parts = name.trim().split(' ').where((p) => p.isNotEmpty).toList();
    if (parts.isEmpty) return '?';
    if (parts.length == 1) return parts.first[0].toUpperCase();
    return (parts.first[0] + parts.last[0]).toUpperCase();
  }

  @override
  Widget build(BuildContext context) {
    final isAdminMember = member.role == 'admin';
    final isSuspended = member.status == 'suspended';

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: GestureDetector(
        onTap: onTap,
        child: Opacity(
          opacity: isSuspended ? 0.55 : 1.0,
          child: Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: AppColors.surfaceColor(context),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: AppColors.borderColor(context)),
            ),
            child: Row(
              children: [
                // Avatar
                Container(
                  width: 46,
                  height: 46,
                  decoration: BoxDecoration(
                    gradient: isAdminMember
                        ? AppColors.primaryGradient
                        : AppColors.accentGradient,
                    borderRadius: BorderRadius.circular(14),
                    image: member.photoPath != null && !kIsWeb
                        ? DecorationImage(
                            image: FileImage(File(PhotoStorageService.resolveAbsolutePath(member.photoPath)!)),
                            fit: BoxFit.cover,
                          )
                        : null,
                  ),
                  child: member.photoPath == null || kIsWeb
                      ? Center(
                          child: Text(
                            _initials(member.fullName),
                            style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.w800,
                              fontSize: 16,
                            ),
                          ),
                        )
                      : null,
                ),
                const SizedBox(width: 12),

                // Info
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              member.fullName +
                                  (isCurrentUser
                                      ? ' ${l10n.youLabel}'
                                      : ''),
                              style: TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w700,
                                color: AppColors.onSurface(context),
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          const SizedBox(width: 6),
                          if (isSuspended)
                            _Badge(
                                label: l10n.suspendedBadge,
                                color: AppColors.cold)
                          else
                            _Badge(
                              label: isAdminMember
                                  ? l10n.orgAdminBadge
                                  : l10n.orgMemberBadge,
                              color: isAdminMember
                                  ? AppColors.primary
                                  : AppColors.warm,
                            ),
                        ],
                      ),
                      const SizedBox(height: 2),
                      Text(
                        member.email,
                        style: TextStyle(
                            fontSize: 12,
                            color: AppColors.secondary(context)),
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '${l10n.orgContactsCount(member.contactCount)}  •  '
                        '${l10n.memberSince} '
                        '${DateFormat('dd/MM/yyyy').format(member.joinedAt)}',
                        style: TextStyle(
                            fontSize: 11, color: AppColors.hint(context)),
                      ),
                    ],
                  ),
                ),

                // Manage chevron (admin only, not self, not another admin)
                if (onTap != null) ...[
                  const SizedBox(width: 8),
                  Icon(Icons.chevron_right_rounded,
                      color: AppColors.hint(context), size: 20),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ─── Member management bottom sheet ──────────────────────────────────────────

class _MemberManagementSheet extends ConsumerWidget {
  const _MemberManagementSheet({
    required this.member,
    required this.onToggleEdit,
    required this.onToggleCreate,
    required this.onToggleViewReminders,
    required this.onSuspend,
    required this.onRemove,
  });

  final OrgMember member;
  final void Function(bool) onToggleEdit;
  final void Function(bool) onToggleCreate;
  final void Function(bool) onToggleViewReminders;
  final VoidCallback onSuspend;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = ref.watch(l10nProvider);
    final isSuspended = member.status == 'suspended';

    // Track live member state so toggles reflect latest refreshed values.
    final liveMembers = ref.watch(organizationProvider).members;
    final live = liveMembers.firstWhere(
      (m) => m.userId == member.userId,
      orElse: () => member,
    );

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Drag handle
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: AppColors.borderColor(context),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 20),

            // Member header
            Row(
              children: [
                Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    gradient: AppColors.accentGradient,
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Center(
                    child: Text(
                      _initials(member.fullName),
                      style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w800,
                          fontSize: 18),
                    ),
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(member.fullName,
                          style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w700,
                              color: AppColors.onSurface(context))),
                      Text(member.email,
                          style: TextStyle(
                              fontSize: 12,
                              color: AppColors.secondary(context))),
                    ],
                  ),
                ),
                if (isSuspended)
                  _Badge(label: l10n.suspendedBadge, color: AppColors.cold)
                else
                  _Badge(label: l10n.orgMemberBadge, color: AppColors.warm),
              ],
            ),

            const SizedBox(height: 20),
            Divider(color: AppColors.borderColor(context)),
            const SizedBox(height: 8),

            // Privilege toggles
            _SheetLabel(l10n.privileges, context),
            const SizedBox(height: 8),
            _PrivilegeRow(
              label: l10n.editPrivilege,
              value: live.canEdit,
              onChanged: onToggleEdit,
            ),
            _PrivilegeRow(
              label: l10n.createPrivilege,
              value: live.canCreate,
              onChanged: onToggleCreate,
            ),
            _PrivilegeRow(
              label: l10n.viewRemindersPrivilege,
              value: live.canViewReminders,
              onChanged: onToggleViewReminders,
            ),

            const SizedBox(height: 12),
            Divider(color: AppColors.borderColor(context)),
            const SizedBox(height: 8),

            // Suspend / Reactivate
            _SheetAction(
              icon: isSuspended
                  ? Icons.play_circle_outline_rounded
                  : Icons.pause_circle_outline_rounded,
              label: isSuspended ? l10n.reactivateMember : l10n.suspendMember,
              color: isSuspended ? AppColors.success : AppColors.warm,
              onTap: onSuspend,
            ),

            // Remove member
            _SheetAction(
              icon: Icons.person_remove_rounded,
              label: l10n.removeMember,
              color: AppColors.hot,
              onTap: onRemove,
            ),
          ],
        ),
      ),
    );
  }

  String _initials(String name) {
    final parts = name.trim().split(' ').where((p) => p.isNotEmpty).toList();
    if (parts.isEmpty) return '?';
    if (parts.length == 1) return parts.first[0].toUpperCase();
    return (parts.first[0] + parts.last[0]).toUpperCase();
  }
}

// ─── Small reusable widgets ───────────────────────────────────────────────────

class _Badge extends StatelessWidget {
  const _Badge({required this.label, required this.color});
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        label,
        style: TextStyle(
            fontSize: 10,
            fontWeight: FontWeight.w700,
            color: color,
            letterSpacing: 0.5),
      ),
    );
  }
}

class _PrivilegeRow extends StatelessWidget {
  const _PrivilegeRow({
    required this.label,
    required this.value,
    required this.onChanged,
  });

  final String label;
  final bool value;
  final void Function(bool) onChanged;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Text(label,
              style: TextStyle(
                  fontSize: 13, color: AppColors.secondary(context))),
        ),
        Switch(
          value: value,
          onChanged: onChanged,
          activeThumbColor: AppColors.primary,
          materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
      ],
    );
  }
}

class _SheetLabel extends StatelessWidget {
  const _SheetLabel(this.text, this.ctx);
  final String text;
  final BuildContext ctx;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: Text(
        text.toUpperCase(),
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w700,
          color: AppColors.hint(ctx),
          letterSpacing: 1,
        ),
      ),
    );
  }
}

class _SheetAction extends StatelessWidget {
  const _SheetAction({
    required this.icon,
    required this.label,
    required this.color,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 4),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.10),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(icon, color: color, size: 18),
            ),
            const SizedBox(width: 14),
            Text(label,
                style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: color)),
          ],
        ),
      ),
    );
  }
}

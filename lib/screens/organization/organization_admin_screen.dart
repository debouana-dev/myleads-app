import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:uuid/uuid.dart';

import '../../config/app_config.dart';
import '../../core/l10n/app_l10n.dart';
import '../../core/theme/app_colors.dart';
import '../../models/organization.dart';
import '../../models/user_account.dart';
import '../../providers/organization_provider.dart';
import '../../services/database_service.dart';
import '../../services/photo_storage_service.dart';
import '../../services/revenue_cat_service.dart';
import '../../services/storage_service.dart';
import '../../services/stripe_service.dart';
import '../../services/subscription_service.dart';

const _renewalUuid = Uuid();

// Unit prices in EUR per license (matches StripeService price map).
const _unitMonthly = 7.19;
const _unitYearly = 71.88;

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
        content:
            Text(body, style: TextStyle(color: AppColors.secondary(context))),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(l10n.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(confirmLabel,
                style: TextStyle(
                    color: confirmColor, fontWeight: FontWeight.w700)),
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

  Future<void> _doTransferOwnershipAndLeave() async {
    final l10n = ref.read(l10nProvider);
    final orgState = ref.read(organizationProvider);

    final admins = orgState.members
        .where((m) => m.role == 'admin' && m.status == 'active')
        .toList();

    if (admins.isEmpty) {
      _showSnack(l10n.transferOwnershipNoAdmins, error: true);
      return;
    }

    final chosen = await showDialog<OrgMember>(
      context: context,
      builder: (ctx) {
        final l10nInner = ref.read(l10nProvider);
        return AlertDialog(
          backgroundColor: AppColors.surfaceColor(context),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          title: Text(
            l10nInner.transferOwnershipPickTitle,
            style: TextStyle(
                color: AppColors.onSurface(context),
                fontWeight: FontWeight.w700,
                fontSize: 17),
          ),
          content: SizedBox(
            width: double.maxFinite,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  l10nInner.transferOwnershipPickSubtitle,
                  style: TextStyle(
                      color: AppColors.secondary(context), fontSize: 13),
                ),
                const SizedBox(height: 12),
                ...admins.map((admin) => ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: CircleAvatar(
                        backgroundColor:
                            AppColors.primary.withOpacity(0.15),
                        child: Text(
                          _initials(admin.firstName, admin.lastName),
                          style: const TextStyle(
                              color: AppColors.primary,
                              fontWeight: FontWeight.w700,
                              fontSize: 14),
                        ),
                      ),
                      title: Text(
                        admin.fullName,
                        style: TextStyle(
                            color: AppColors.onSurface(context),
                            fontWeight: FontWeight.w600),
                      ),
                      subtitle: (admin.email != null &&
                              admin.email!.isNotEmpty)
                          ? Text(
                              admin.email!,
                              style: TextStyle(
                                  color: AppColors.secondary(context),
                                  fontSize: 12),
                            )
                          : null,
                      onTap: () => Navigator.of(ctx).pop(admin),
                    )),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(null),
              child: Text(l10nInner.cancel),
            ),
          ],
        );
      },
    );

    if (chosen == null || !mounted) return;

    final confirmed = await _confirm(
      title: l10n.transferOwnershipConfirmTitle,
      body: l10n.transferOwnershipConfirmBody(chosen.fullName),
      confirmLabel: l10n.transferOwnershipConfirm,
    );
    if (confirmed != true || !mounted) return;

    final err = await ref
        .read(organizationProvider.notifier)
        .transferOwnershipAndLeave(chosen.userId);
    if (!mounted) return;
    if (err != null) {
      _showSnack(err, error: true);
    } else {
      _showSnack(l10n.transferOwnershipSuccess);
      context.pop();
    }
  }

  static String _initials(String first, String last) {
    final a = first.trim();
    final b = last.trim();
    if (a.isNotEmpty && b.isNotEmpty) {
      return '${a[0]}${b[0]}'.toUpperCase();
    }
    return a.isNotEmpty ? a[0].toUpperCase() : '?';
  }

  // ─── Member management sheet ──────────────────────────────────────────────

  void _openMemberSheet(OrgMember member, {required bool isOwner}) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.surfaceColor(context),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (_) => _MemberManagementSheet(
        member: member,
        isCurrentUserOwner: isOwner,
        onUpdatePrivileges: (canEdit, canCreate, canViewReminders,
                canViewHistory, canExportContacts) =>
            _updatePrivileges(member,
                canEdit: canEdit,
                canCreate: canCreate,
                canViewReminders: canViewReminders,
                canViewHistory: canViewHistory,
                canExportContacts: canExportContacts),
        onSuspend: member.status == 'active'
            ? () => _doSuspend(member)
            : () => _doReactivate(member),
        onRemove: () => _doRemove(member),
        onAssignAdmin:
            isOwner && member.role == 'member' ? () => _doAssignAdmin(member) : null,
        onRevokeAdmin:
            isOwner && member.role == 'admin' ? () => _doRevokeAdmin(member) : null,
      ),
    );
  }

  Future<void> _doAssignAdmin(OrgMember member) async {
    Navigator.of(context).pop();
    final l10n = ref.read(l10nProvider);
    final ok = await _confirm(
      title: l10n.assignAdminTitle,
      body: l10n.assignAdminConfirm(member.fullName),
      confirmLabel: l10n.assignAdminRole,
      confirmColor: AppColors.primary,
    );
    if (ok != true || !mounted) return;
    final err =
        await ref.read(organizationProvider.notifier).assignAdminRole(member.userId);
    if (!mounted) return;
    if (err != null) {
      _showSnack(err, error: true);
    } else {
      _showSnack(l10n.adminAssignedSuccess);
    }
  }

  Future<void> _doRevokeAdmin(OrgMember member) async {
    Navigator.of(context).pop();
    final l10n = ref.read(l10nProvider);
    final ok = await _confirm(
      title: l10n.revokeAdminTitle,
      body: l10n.revokeAdminConfirm(member.fullName),
      confirmLabel: l10n.revokeAdminRole,
      confirmColor: AppColors.warm,
    );
    if (ok != true || !mounted) return;
    final err =
        await ref.read(organizationProvider.notifier).revokeAdminRole(member.userId);
    if (!mounted) return;
    if (err != null) {
      _showSnack(err, error: true);
    } else {
      _showSnack(l10n.adminRevokedSuccess);
    }
  }

  Future<void> _updatePrivileges(OrgMember member,
      {required bool canEdit,
      required bool canCreate,
      required bool canViewReminders,
      required bool canViewHistory,
      required bool canExportContacts}) async {
    final l10n = ref.read(l10nProvider);
    final err =
        await ref.read(organizationProvider.notifier).updateMemberPrivileges(
              userId: member.userId,
              canEdit: canEdit,
              canCreate: canCreate,
              canViewReminders: canViewReminders,
              canViewHistory: canViewHistory,
              canExportContacts: canExportContacts,
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
    final err = await ref
        .read(organizationProvider.notifier)
        .suspendMember(member.userId);
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

  Future<String?> _fetchOrgBillingCycle() async {
    final userId = StorageService.currentUserId;
    final history = await DatabaseService.getPaymentHistory(userId);
    for (final record in history) {
      if (record.plan == 'business' && record.status == 'succeeded') {
        return record.billingCycle;
      }
    }
    return null;
  }

  int _calculateOrgLicensePaymentAmountInCents({
    required int currentLicenseCount,
    required int requestedLicenseCount,
    required String billingCycle,
    required DateTime? expiresAt,
  }) {
    final unitAmountCents = billingCycle == 'yearly'
        ? (_unitYearly * 100).round()
        : (_unitMonthly * 100).round();
    final addedSeats = requestedLicenseCount - currentLicenseCount;
    if (addedSeats <= 0) {
      return unitAmountCents * requestedLicenseCount;
    }

    if (expiresAt == null) {
      return unitAmountCents * addedSeats;
    }

    final remainingDays = expiresAt.difference(DateTime.now()).inDays;
    if (remainingDays <= 0) {
      return unitAmountCents * addedSeats;
    }

    final totalDays = billingCycle == 'yearly' ? 365 : 30;
    final prorated = unitAmountCents * addedSeats * remainingDays / totalDays;
    return prorated.round().clamp(1, double.maxFinite).toInt();
  }

  // ─── License renewal ─────────────────────────────────────────────────────

  /// Shows a bottom sheet where the admin selects billing cycle and confirms
  /// the renewal payment. The license count is fixed to the current member
  /// count (active + suspended) so the admin always pays for all accounts.
  Future<void> _doRenewLicenses() async {
    final l10n = ref.read(l10nProvider);
    final orgState = ref.read(organizationProvider);
    final org = orgState.organization;
    if (org == null) return;

    // Must pay for at least the current member count.
    final minLicenses = orgState.totalMemberCount;

    final existingBillingCycle = await _fetchOrgBillingCycle();
    if (!mounted) return;

    String? billingCycle = existingBillingCycle ?? 'monthly';
    int licenseCount = minLicenses < 1 ? 1 : minLicenses;

    final confirmed = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.surfaceColor(context),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => _RenewalSheet(
        initialLicenses: licenseCount,
        minLicenses: minLicenses,
        initialBillingCycle: billingCycle!,
        allowedBillingCycle: existingBillingCycle,
        onConfirm: (cycle, count) {
          billingCycle = cycle;
          licenseCount = count;
          Navigator.of(ctx).pop(true);
        },
        l10n: l10n,
      ),
    );

    if (confirmed != true || !mounted) return;

    final user = StorageService.currentUser;
    if (user == null) return;

    final isRenewal = licenseCount == org.licenseCount;
    final isInRenewalWindow = SubscriptionService.isInRenewalWindow(
      org.orgPlanExpiresAt,
      billingCycle,
    );

    if (isRenewal && !isInRenewalWindow) {
      final renewalStart = SubscriptionService.renewalWindowStart(
          org.orgPlanExpiresAt, billingCycle);
      if (renewalStart != null) {
        final formattedDate =
            '${renewalStart.day.toString().padLeft(2, '0')}/${renewalStart.month.toString().padLeft(2, '0')}/${renewalStart.year}';
        _showSnack(l10n.orgRenewalWindowNotOpen(formattedDate), error: true);
      } else {
        _showSnack(l10n.orgRenewalWindowNotOpenGeneric, error: true);
      }
      return;
    }

    if (Platform.isAndroid && !AppConfig.stripePublishableKey.isNotEmpty) {
      _showSnack('Stripe not configured', error: true);
      return;
    }

    final amountToPayCents = _calculateOrgLicensePaymentAmountInCents(
      currentLicenseCount: org.licenseCount,
      requestedLicenseCount: licenseCount,
      billingCycle: billingCycle!,
      expiresAt: org.orgPlanExpiresAt,
    );

    setState(() {});
    
    bool success = false;
    String? transactionId;
    String? errorCode;

    if (Platform.isIOS) {
      // Use RevenueCat on iOS. Note: Dynamic license pricing usually requires 
      // specific setup in RevenueCat (e.g. multi-seat offerings).
      // Here we fall back to the standard business plan purchase.
      final rcResult = await RevenueCatService.purchasePlan('business', billingCycle!);
      success = rcResult.success;
      transactionId = rcResult.customerId;
      errorCode = rcResult.errorCode;
    } else {
      // Use Stripe on Android.
      final result = await StripeService.startCheckout(
        plan: 'business',
        billingCycle: billingCycle!,
        userEmail: user.email,
        licenseCount: licenseCount,
        amount: amountToPayCents.toDouble(),
      );
      success = result.success;
      transactionId = result.paymentIntentId;
      errorCode = result.errorCode;
    }

    if (!mounted) return;

    if (!success) {
      final msg = errorCode == 'cancelled'
          ? l10n.paymentCancelled
          : l10n.paymentFailed;
      _showSnack(msg, error: true);
      return;
    }

    // Record payment for the org license pool, including the admin seat.
    final record = PaymentRecord(
      id: transactionId?.isNotEmpty == true
          ? transactionId!
          : _renewalUuid.v4(),
      transactionId: PaymentRecord.generateId(),
      userId: user.id,
      plan: 'business',
      billingCycle: billingCycle!,
      amount: amountToPayCents / 100,
      currency: 'EUR',
      status: 'succeeded',
      stripePaymentIntentId: transactionId ?? '',
      accountType: 'organization',
      createdAt: DateTime.now().toIso8601String(),
    );
    await DatabaseService.insertPaymentRecord(record);

    final shouldRenewExpiry = isRenewal;
    final expiresAt = shouldRenewExpiry
        ? (billingCycle == 'yearly'
            ? DateTime.now().add(const Duration(days: 365))
            : DateTime.now().add(const Duration(days: 30)))
        : org.orgPlanExpiresAt;

    final err = await ref.read(organizationProvider.notifier).renewOrgLicenses(
          licenseCount: licenseCount,
          expiresAt: expiresAt,
        );

    if (!mounted) return;
    if (err != null) {
      _showSnack(err, error: true);
    } else {
      _showSnack(l10n.orgLicensesRenewed);
    }
  }

  // ─── Build ────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final l10n = ref.watch(l10nProvider);
    final orgState = ref.watch(organizationProvider);
    final currentUserId = StorageService.currentUser?.id ?? '';
    final currentUserRole = StorageService.currentUser?.orgRole ?? 'member';
    final isOwner = currentUserRole == 'owner';
    final isAdmin = isOwner || currentUserRole == 'admin';

    if (orgState.isLoading) {
      return Scaffold(
        backgroundColor: AppColors.bg(context),
        appBar: _appBar(l10n, null, isAdmin: false, isOwner: false),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    final org = orgState.organization;
    if (org == null) {
      return Scaffold(
        backgroundColor: AppColors.bg(context),
        appBar: _appBar(l10n, null, isAdmin: false, isOwner: false),
        body: Center(
          child: Text(l10n.noOrgMembers,
              style: TextStyle(color: AppColors.secondary(context))),
        ),
      );
    }

    final members = orgState.members;
    final activeCount = members.where((m) => m.status == 'active').length;
    final totalContacts = orgState.uniqueContactCount;
    final isSuspended = orgState.isOrgSuspended;
    final expiresAt = orgState.orgPlanExpiresAt;

    return Scaffold(
      backgroundColor: AppColors.bg(context),
      appBar: _appBar(l10n, org, isAdmin: isAdmin, isOwner: isOwner),
      body: RefreshIndicator(
        onRefresh: () => ref.read(organizationProvider.notifier).refreshFromCloud(),
        color: AppColors.primary,
        backgroundColor: AppColors.surfaceColor(context),
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
          children: [
            // ── Suspension / expiry banner ────────────────────────────────────
            if (isSuspended) ...[
              _SuspensionBanner(
                org: org,
                isAdmin: isAdmin,
                onRenew: _doRenewLicenses,
                l10n: l10n,
              ),
              const SizedBox(height: 16),
            ],

            // ── Org stats card ────────────────────────────────────────────────
            _OrgStatsCard(
              orgName: org.name,
              createdAt: org.createdAt,
              activeMembers: activeCount,
              totalContacts: totalContacts,
              l10n: l10n,
            ),
            const SizedBox(height: 16),

            // ── License info card (admin + owner) ────────────────────────────
            // Owners see the full card with renewal button.
            // Admins see read-only (seat count + expiry, no renew button).
            if (isAdmin) ...[
              _LicenseInfoCard(
                licenseCount: org.licenseCount,
                usedSeats: members.length,
                expiresAt: expiresAt,
                isSuspended: isSuspended,
                onRenew: isOwner ? _doRenewLicenses : null,
                l10n: l10n,
              ),
              const SizedBox(height: 16),
            ],

            // ── Invite code card (admin only) ─────────────────────────────────
            if (isAdmin && !isSuspended) ...[
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
            _SectionLabel(
                '${l10n.orgMembersTitle} (${members.length}/${org.licenseCount})'),
            const SizedBox(height: 10),
            if (members.isEmpty)
              Center(
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 24),
                  child: Text(l10n.noOrgMembers,
                      style: TextStyle(color: AppColors.secondary(context))),
                ),
              )
            else
              ...members.map(
                (m) => _MemberCard(
                  member: m,
                  isCurrentUser: m.userId == currentUserId,
                  isAdmin: isAdmin,
                  l10n: l10n,
                  onTap: isAdmin &&
                          m.userId != currentUserId &&
                          (isOwner || m.role == 'member')
                      ? () => _openMemberSheet(m, isOwner: isOwner)
                      : null,
                ),
              ),

            const SizedBox(height: 24),

            // ── Leave / danger zone ───────────────────────────────────────────
            if (!isOwner)
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
            if (isOwner)
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
                  onPressed: _doTransferOwnershipAndLeave,
                  icon: const Icon(Icons.swap_horiz_rounded, size: 18),
                  label: Text(l10n.transferOwnershipAndLeave),
                ),
              ),
          ],
        ),
      ),
    );
  }

  AppBar _appBar(AppL10n l10n, Organization? org,
      {required bool isAdmin, bool isOwner = false}) {
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
      actions: org == null
          ? null
          : [
              IconButton(
                icon: const Icon(Icons.refresh_rounded, color: Colors.white),
                onPressed: () =>
                    ref.read(organizationProvider.notifier).refreshFromCloud(),
              ),
              if (isAdmin)
                PopupMenuButton<String>(
                  icon:
                      const Icon(Icons.more_vert_rounded, color: Colors.white),
                  onSelected: (v) {
                    if (v == 'rename') _doRename(org);
                    if (v == 'regen') _doRegenerateCode();
                    if (v == 'delete') _doDeleteOrg();
                  },
                  itemBuilder: (_) => [
                    if (isOwner)
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
                    if (isOwner) ...[
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
                  ],
                ),
            ],
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
              style:
                  TextStyle(fontSize: 12, color: AppColors.secondary(context))),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(vertical: 14, horizontal: 16),
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
    final isOwnerMember = member.role == 'owner';
    final isAdminMember = member.role == 'admin' || member.role == 'owner';
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
                            image: FileImage(File(
                                PhotoStorageService.resolveAbsolutePath(
                                    member.photoPath)!)),
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
                                  (isCurrentUser ? ' ${l10n.youLabel}' : ''),
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
                          else if (isOwnerMember)
                            _Badge(
                                label: l10n.orgOwnerBadge,
                                color: AppColors.accent)
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
                        member.email ?? '',
                        style: TextStyle(
                            fontSize: 12, color: AppColors.secondary(context)),
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        isAdmin || isCurrentUser
                            ? '${l10n.orgContactsCount(member.contactCount)}  •  '
                                '${l10n.memberSince} '
                                '${DateFormat('dd/MM/yyyy').format(member.joinedAt)}'
                            : '${l10n.memberSince} '
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
    required this.isCurrentUserOwner,
    required this.onUpdatePrivileges,
    required this.onSuspend,
    required this.onRemove,
    this.onAssignAdmin,
    this.onRevokeAdmin,
  });

  final OrgMember member;
  final bool isCurrentUserOwner;
  final void Function(bool canEdit, bool canCreate, bool canViewReminders,
      bool canViewHistory, bool canExportContacts) onUpdatePrivileges;
  final VoidCallback onSuspend;
  final VoidCallback onRemove;
  final VoidCallback? onAssignAdmin;
  final VoidCallback? onRevokeAdmin;

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
                    image: member.photoPath != null && !kIsWeb
                        ? DecorationImage(
                            image: FileImage(File(
                                PhotoStorageService.resolveAbsolutePath(
                                    member.photoPath)!)),
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
                      Text(member.email ?? '',
                          style: TextStyle(
                              fontSize: 12,
                              color: AppColors.secondary(context))),
                    ],
                  ),
                ),
                if (isSuspended)
                  _Badge(label: l10n.suspendedBadge, color: AppColors.cold)
                else if (member.role == 'owner')
                  _Badge(label: l10n.orgOwnerBadge, color: AppColors.accent)
                else if (member.role == 'admin')
                  _Badge(label: l10n.orgAdminBadge, color: AppColors.primary)
                else
                  _Badge(label: l10n.orgMemberBadge, color: AppColors.warm),
              ],
            ),

            const SizedBox(height: 20),
            Divider(color: AppColors.borderColor(context)),
            const SizedBox(height: 8),

            // Privilege toggles — hidden for admin/owner (always full access)
            _SheetLabel(l10n.privileges, context),
            const SizedBox(height: 8),
            if (live.isAdminOrAbove) ...[
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text(
                  l10n.adminPrivilegesNote,
                  style: TextStyle(
                      fontSize: 13, color: AppColors.secondary(context)),
                ),
              ),
            ] else ...[
              _PrivilegeRow(
                label: l10n.editPrivilege,
                value: live.canEdit,
                onChanged: (val) => onUpdatePrivileges(
                    val,
                    live.canCreate,
                    live.canViewReminders,
                    live.canViewHistory,
                    live.canExportContacts),
              ),
              _PrivilegeRow(
                label: l10n.createPrivilege,
                value: live.canCreate,
                onChanged: (val) => onUpdatePrivileges(
                    live.canEdit,
                    val,
                    live.canViewReminders,
                    live.canViewHistory,
                    live.canExportContacts),
              ),
              _PrivilegeRow(
                label: l10n.viewRemindersPrivilege,
                value: live.canViewReminders,
                onChanged: (val) => onUpdatePrivileges(
                    live.canEdit,
                    live.canCreate,
                    val,
                    live.canViewHistory,
                    live.canExportContacts),
              ),
              _PrivilegeRow(
                label: l10n.viewHistoryPrivilege,
                value: live.canViewHistory,
                onChanged: (val) => onUpdatePrivileges(
                    live.canEdit,
                    live.canCreate,
                    live.canViewReminders,
                    val,
                    live.canExportContacts),
              ),
              _PrivilegeRow(
                label: l10n.exportPrivilege,
                value: live.canExportContacts,
                onChanged: (val) => onUpdatePrivileges(
                    live.canEdit,
                    live.canCreate,
                    live.canViewReminders,
                    live.canViewHistory,
                    val),
              ),
            ],

            const SizedBox(height: 12),
            Divider(color: AppColors.borderColor(context)),
            const SizedBox(height: 8),

            // Assign / Revoke admin role (owner only)
            if (onAssignAdmin != null)
              _SheetAction(
                icon: Icons.admin_panel_settings_rounded,
                label: l10n.assignAdminRole,
                color: AppColors.primary,
                onTap: onAssignAdmin!,
              ),
            if (onRevokeAdmin != null)
              _SheetAction(
                icon: Icons.remove_moderator_rounded,
                label: l10n.revokeAdminRole,
                color: AppColors.warm,
                onTap: onRevokeAdmin!,
              ),

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
              style:
                  TextStyle(fontSize: 13, color: AppColors.secondary(context))),
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
                    fontSize: 14, fontWeight: FontWeight.w600, color: color)),
          ],
        ),
      ),
    );
  }
}

// ─── Suspension banner ────────────────────────────────────────────────────────

class _SuspensionBanner extends StatelessWidget {
  const _SuspensionBanner({
    required this.org,
    required this.isAdmin,
    required this.onRenew,
    required this.l10n,
  });

  final Organization org;
  final bool isAdmin;
  final VoidCallback? onRenew;
  final AppL10n l10n;

  @override
  Widget build(BuildContext context) {
    // Compute days until permanent deletion.
    int? daysLeft;
    if (org.orgSuspendedAt != null) {
      final deleteAt = org.orgSuspendedAt!.add(const Duration(days: 180));
      daysLeft = deleteAt.difference(DateTime.now()).inDays.clamp(0, 180);
    }

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.hot.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.hot.withValues(alpha: 0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.warning_amber_rounded,
                  color: AppColors.hot, size: 20),
              const SizedBox(width: 8),
              Text(
                l10n.orgSuspendedBanner,
                style: const TextStyle(
                  color: AppColors.hot,
                  fontWeight: FontWeight.w700,
                  fontSize: 14,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            l10n.orgSuspendedDesc,
            style: TextStyle(color: AppColors.secondary(context), fontSize: 13),
          ),
          if (daysLeft != null && daysLeft < 60) ...[
            const SizedBox(height: 8),
            Text(
              l10n.orgDeletionWarning(daysLeft),
              style: const TextStyle(
                  color: AppColors.hot,
                  fontSize: 12,
                  fontWeight: FontWeight.w600),
            ),
          ],
          if (isAdmin && onRenew != null) ...[
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: onRenew,
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.hot,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10)),
                ),
                icon: const Icon(Icons.refresh_rounded, size: 18),
                label: Text(l10n.renewOrgLicenses),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

// ─── License info card ────────────────────────────────────────────────────────

class _LicenseInfoCard extends StatelessWidget {
  const _LicenseInfoCard({
    required this.licenseCount,
    required this.usedSeats,
    required this.expiresAt,
    required this.isSuspended,
    required this.onRenew,
    required this.l10n,
  });

  final int licenseCount;
  final int usedSeats;
  final DateTime? expiresAt;
  final bool isSuspended;
  final VoidCallback? onRenew;
  final AppL10n l10n;

  @override
  Widget build(BuildContext context) {
    String? expiryText;
    if (expiresAt != null) {
      final d = expiresAt!;
      expiryText = l10n.orgExpiresOn(
          '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year}');
    }

    // Determine seat usage colour.
    final available = licenseCount - usedSeats;
    final seatColor = available <= 0
        ? AppColors.hot
        : available == 1
            ? AppColors.warm
            : AppColors.success;

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
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: AppColors.primary.withValues(alpha: 0.10),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Icon(Icons.verified_user_rounded,
                    color: AppColors.primary, size: 18),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  l10n.orgLicensesTitle,
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    color: AppColors.onSurface(context),
                  ),
                ),
              ),
              if (!isSuspended && onRenew != null)
                GestureDetector(
                  onTap: onRenew,
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    decoration: BoxDecoration(
                      color: AppColors.primary,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      l10n.renewOrgLicenses,
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 12,
                          fontWeight: FontWeight.w600),
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: _InfoChip(
                  icon: Icons.people_alt_rounded,
                  label: l10n.orgSeatsUsed(usedSeats, licenseCount),
                  color: seatColor,
                ),
              ),
              if (expiryText != null) ...[
                const SizedBox(width: 8),
                Expanded(
                  child: _InfoChip(
                    icon: Icons.calendar_today_rounded,
                    label: expiryText,
                    color: isSuspended ? AppColors.hot : AppColors.info,
                  ),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

class _InfoChip extends StatelessWidget {
  const _InfoChip({
    required this.icon,
    required this.label,
    required this.color,
  });

  final IconData icon;
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          Icon(icon, color: color, size: 13),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              label,
              style: TextStyle(
                  fontSize: 11, fontWeight: FontWeight.w600, color: color),
              maxLines: 2,
              overflow: TextOverflow.visible,
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Renewal bottom sheet ─────────────────────────────────────────────────────

class _RenewalSheet extends StatefulWidget {
  const _RenewalSheet({
    required this.initialLicenses,
    required this.minLicenses,
    required this.initialBillingCycle,
    this.allowedBillingCycle,
    required this.onConfirm,
    required this.l10n,
  });

  final int initialLicenses;
  final int minLicenses;
  final String initialBillingCycle;
  final String? allowedBillingCycle;
  final void Function(String billingCycle, int licenseCount) onConfirm;
  final AppL10n l10n;

  @override
  State<_RenewalSheet> createState() => _RenewalSheetState();
}

class _RenewalSheetState extends State<_RenewalSheet> {
  late int _licenseCount;
  late String _billingCycle;

  double get _unitPrice =>
      _billingCycle == 'yearly' ? _unitYearly : _unitMonthly;
  double get _total => _unitPrice * _licenseCount;

  @override
  void initState() {
    super.initState();
    _licenseCount = widget.initialLicenses < 1 ? 1 : widget.initialLicenses;
    _billingCycle = widget.initialBillingCycle;
  }

  String _fmt(double v) => '${v.toStringAsFixed(2).replaceAll('.', ',')} €';

  @override
  Widget build(BuildContext context) {
    final l10n = widget.l10n;
    return Padding(
      padding: EdgeInsets.only(
        left: 24,
        right: 24,
        top: 24,
        bottom: MediaQuery.of(context).viewInsets.bottom + 32,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Center(
            child: Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: AppColors.cold,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          const SizedBox(height: 20),
          Text(
            l10n.renewOrgLicenses,
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w800,
              color: AppColors.onSurface(context),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            l10n.orgCannotReduceBelow,
            style: TextStyle(fontSize: 12, color: AppColors.hint(context)),
          ),
          const SizedBox(height: 20),

          // Billing cycle
          Text(l10n.orgBillingCycle,
              style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  color: AppColors.hint(context),
                  letterSpacing: 1)),
          const SizedBox(height: 8),
          Container(
            decoration: BoxDecoration(
              color: AppColors.inputBackground(context),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: AppColors.borderColor(context)),
            ),
            child: Row(
              children: [
                _CyclePill(
                  label: l10n.orgMonthly,
                  selected: _billingCycle == 'monthly',
                  onTap: widget.allowedBillingCycle == null ||
                          _licenseCount == widget.initialLicenses ||
                          widget.allowedBillingCycle == 'monthly'
                      ? () => setState(() => _billingCycle = 'monthly')
                      : null,
                  disabled: widget.allowedBillingCycle != null &&
                      _licenseCount > widget.initialLicenses &&
                      widget.allowedBillingCycle != 'monthly',
                ),
                _CyclePill(
                  label: l10n.orgYearly,
                  selected: _billingCycle == 'yearly',
                  onTap: widget.allowedBillingCycle == null ||
                          _licenseCount == widget.initialLicenses ||
                          widget.allowedBillingCycle == 'yearly'
                      ? () => setState(() => _billingCycle = 'yearly')
                      : null,
                  disabled: widget.allowedBillingCycle != null &&
                      _licenseCount > widget.initialLicenses &&
                      widget.allowedBillingCycle != 'yearly',
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),

          // License count
          Text(l10n.orgSelectLicenses,
              style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  color: AppColors.hint(context),
                  letterSpacing: 1)),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              IconButton(
                onPressed: _licenseCount > widget.minLicenses
                    ? () => setState(() => _licenseCount--)
                    : null,
                icon: Icon(
                  Icons.remove_circle_outline_rounded,
                  color: _licenseCount > widget.minLicenses
                      ? AppColors.primary
                      : AppColors.cold,
                  size: 28,
                ),
              ),
              Text(
                '$_licenseCount',
                style: const TextStyle(
                  fontSize: 32,
                  fontWeight: FontWeight.w800,
                  color: AppColors.primary,
                ),
              ),
              IconButton(
                onPressed: () {
                  setState(() {
                    _licenseCount++;
                    if (widget.allowedBillingCycle != null &&
                        _licenseCount > widget.initialLicenses &&
                        _billingCycle != widget.allowedBillingCycle) {
                      _billingCycle = widget.allowedBillingCycle!;
                    }
                  });
                },
                icon: const Icon(
                  Icons.add_circle_outline_rounded,
                  color: AppColors.primary,
                  size: 28,
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),

          // Total price
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: AppColors.primary.withValues(alpha: 0.06),
              borderRadius: BorderRadius.circular(12),
              border:
                  Border.all(color: AppColors.primary.withValues(alpha: 0.18)),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text(
                  'TOTAL',
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    color: AppColors.primary,
                    fontSize: 12,
                    letterSpacing: 1,
                  ),
                ),
                Text(
                  _fmt(_total),
                  style: const TextStyle(
                    fontWeight: FontWeight.w800,
                    color: AppColors.primary,
                    fontSize: 20,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),

          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: () => widget.onConfirm(_billingCycle, _licenseCount),
              icon: const Icon(Icons.payment_rounded),
              label: Text(l10n.renewOrgLicenses),
              style: ElevatedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 14),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _CyclePill extends StatelessWidget {
  const _CyclePill({
    required this.label,
    required this.selected,
    this.onTap,
    this.disabled = false,
  });

  final String label;
  final bool selected;
  final VoidCallback? onTap;
  final bool disabled;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: GestureDetector(
        onTap: disabled ? null : onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          margin: const EdgeInsets.all(4),
          padding: const EdgeInsets.symmetric(vertical: 9),
          decoration: BoxDecoration(
            color: selected
                ? AppColors.primary
                : disabled
                    ? AppColors.borderColor(context)
                    : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Text(
            label,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: selected
                  ? Colors.white
                  : disabled
                      ? AppColors.hint(context)
                      : AppColors.secondary(context),
            ),
          ),
        ),
      ),
    );
  }
}

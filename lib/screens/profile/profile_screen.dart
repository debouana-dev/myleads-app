import 'dart:io';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../core/l10n/app_l10n.dart';
import '../../core/theme/app_colors.dart';
import '../../providers/auth_provider.dart';
import '../../providers/contacts_provider.dart';
import '../../providers/organization_provider.dart';
import '../../providers/reminders_provider.dart';
import '../../services/remote_sync_service.dart';
import '../../services/ftp_photo_service.dart';
import '../../services/photo_storage_service.dart';
import '../../services/storage_service.dart';

class ProfileScreen extends ConsumerStatefulWidget {
  const ProfileScreen({super.key});

  @override
  ConsumerState<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends ConsumerState<ProfileScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(organizationProvider.notifier).loadForCurrentUser();
    });
  }

  Future<void> _pickPhoto(BuildContext context) async {
    if (kIsWeb) return;
    try {
      final image = await ImagePicker().pickImage(
        source: ImageSource.gallery,
        imageQuality: 80,
        maxWidth: 512,
      );
      if (image != null) {
        final savedPath =
            await PhotoStorageService.saveProfilePhoto(image.path);
        if (savedPath != null) {
          // Upload to FTP immediately (fire-and-forget) for premium/business users
          // so the photo is available when user logs in on another device
          final user = StorageService.currentUser;
          if (user != null && (user.plan == 'business')) {
            FtpPhotoService.uploadPhoto(savedPath).ignore();
          }

          await ref.read(authProvider.notifier).updatePhoto(savedPath);
        }
      }
    } on PhotoFileTooLargeException {
      if (context.mounted) {
        final l10n = ref.read(l10nProvider);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Row(
              children: [
                const Icon(Icons.error_outline, color: Colors.white, size: 20),
                const SizedBox(width: 10),
                Expanded(child: Text(l10n.photoTooLarge)),
              ],
            ),
            backgroundColor: AppColors.hot,
            behavior: SnackBarBehavior.floating,
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          ),
        );
      }
    } catch (_) {}
  }

  String _initialsFor(String name) {
    final parts =
        name.trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
    if (parts.isEmpty) return '?';
    if (parts.length == 1) return parts.first.characters.first.toUpperCase();
    return (parts.first.characters.first + parts.last.characters.first)
        .toUpperCase();
  }

  Future<void> _handleRefresh() async {
    final userId = StorageService.currentUserId;
    if (userId.isEmpty) return;

    // Download everything for this user from the cloud.
    // This includes the users row (plan/subscription) and organization data.
    await RemoteSyncService.pull(userId);

    // Refresh providers from the updated local database.
    ref.read(authProvider.notifier).refreshFromStorage();
    await ref.read(organizationProvider.notifier).loadForCurrentUser();
    await ref.read(contactsProvider.notifier).reload();
    await ref.read(remindersProvider.notifier).reload();
  }

  Future<void> _launchPrivacyPolicy() async {
    final url = Uri.parse('https://www.me2leads.com/privacy');
    try {
      if (await canLaunchUrl(url)) {
        await launchUrl(url, mode: LaunchMode.externalApplication);
      }
    } catch (e) {
      debugPrint('Could not launch $url: $e');
    }
  }

  Future<void> _launchTermsOfUse() async {
    final url = Uri.parse('https://me2leads.com/terms');
    try {
      if (await canLaunchUrl(url)) {
        await launchUrl(url, mode: LaunchMode.externalApplication);
      }
    } catch (e) {
      debugPrint('Could not launch $url: $e');
    }
  }

  Future<void> _launchContactUs() async {
    final url = Uri.parse('https://me2leads.com/contact');
    try {
      if (await canLaunchUrl(url)) {
        await launchUrl(url, mode: LaunchMode.externalApplication);
      }
    } catch (e) {
      debugPrint('Could not launch $url: $e');
    }
  }

  Future<void> _launchRefundPolicy() async {
    final url = Uri.parse('https://www.me2leads.com/refund');
    try {
      if (await canLaunchUrl(url)) {
        await launchUrl(url, mode: LaunchMode.externalApplication);
      }
    } catch (e) {
      debugPrint('Could not launch $url: $e');
    }
  }

  void _showHelpBottomSheet() {
    final l10n = ref.read(l10nProvider);
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (context) => Container(
        decoration: BoxDecoration(
          color: AppColors.surfaceColor(context),
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        ),
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: AppColors.borderColor(context),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 24),
            Text(
              l10n.helpLabel,
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w800,
                color: AppColors.onSurface(context),
              ),
            ),
            const SizedBox(height: 24),
            _menuItem(
              context,
              Icons.contact_support_rounded,
              l10n.contactUs,
              l10n.contactUsDesc,
              AppColors.accent.withOpacity(0.1),
              AppColors.accent,
              () {
                Navigator.pop(context);
                _launchContactUs();
              },
            ),
            _menuItem(
              context,
              Icons.privacy_tip_rounded,
              l10n.privacyPolicyLink.substring(0, 1).toUpperCase() +
                  l10n.privacyPolicyLink.substring(1),
              l10n.privacyPolicyDesc,
              const Color(0xFF607D8B).withOpacity(0.1),
              const Color(0xFF607D8B),
              () {
                Navigator.pop(context);
                _launchPrivacyPolicy();
              },
            ),
            _menuItem(
              context,
              Icons.gavel_rounded,
              l10n.termsOfUseLink.substring(0, 1).toUpperCase() +
                  l10n.termsOfUseLink.substring(1),
              l10n.termsOfUseDesc,
              const Color(0xFF9E9E9E).withOpacity(0.1),
              const Color(0xFF9E9E9E),
              () {
                Navigator.pop(context);
                _launchTermsOfUse();
              },
            ),
            _menuItem(
              context,
              Icons.receipt_long_rounded,
              l10n.refundPolicy,
              l10n.refundPolicyDesc,
              AppColors.warm.withOpacity(0.1),
              AppColors.warm,
              () {
                Navigator.pop(context);
                _launchRefundPolicy();
              },
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = ref.watch(l10nProvider);
    final auth = ref.watch(authProvider);
    final effectivePlan = ref.watch(effectivePlanProvider).maybeWhen(
          data: (plan) => plan,
          orElse: () => auth.plan,
        );
    final contacts = ref.watch(contactsProvider);
    final orgState = ref.watch(organizationProvider);
    final hasOrg = orgState.organization != null;
    final orgRole = StorageService.currentUser?.orgRole;
    final displayName = auth.userName.isEmpty
        ? (l10n.isEnglish ? 'User' : 'Utilisateur')
        : auth.userName;
    final displayEmail = auth.userEmail.isEmpty ? '—' : auth.userEmail;
    final displayInitials = _initialsFor(displayName);

    return Scaffold(
      backgroundColor: AppColors.bg(context),
      body: RefreshIndicator(
        onRefresh: _handleRefresh,
        color: AppColors.accent,
        backgroundColor: AppColors.surfaceColor(context),
        child: SingleChildScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          child: Column(
            children: [
              // Header
              Container(
                padding: EdgeInsets.only(
                  top: MediaQuery.of(context).padding.top + 10,
                  bottom: 32,
                ),
                decoration: const BoxDecoration(
                  gradient: AppColors.primaryGradient,
                  borderRadius: BorderRadius.only(
                    bottomLeft: Radius.circular(32),
                    bottomRight: Radius.circular(32),
                  ),
                ),
                child: Column(
                  children: [
                    Text(
                      l10n.accountLabel.toUpperCase(),
                      style: TextStyle(
                        color: Colors.white.withOpacity(0.55),
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 1.5,
                      ),
                    ),
                    const SizedBox(height: 16),
                    GestureDetector(
                      onTap: () => _pickPhoto(context),
                      child: Stack(
                        children: [
                          Container(
                            width: 90,
                            height: 90,
                            decoration: BoxDecoration(
                              gradient: AppColors.accentGradient,
                              borderRadius: BorderRadius.circular(28),
                              border: Border.all(
                                color: Colors.white.withOpacity(0.2),
                                width: 4,
                              ),
                              image: auth.userPhotoPath != null && !kIsWeb
                                  ? DecorationImage(
                                      image: FileImage(File(PhotoStorageService
                                          .resolveAbsolutePath(
                                              auth.userPhotoPath)!)),
                                      fit: BoxFit.cover,
                                    )
                                  : null,
                            ),
                            child: auth.userPhotoPath == null || kIsWeb
                                ? Center(
                                    child: Text(
                                      displayInitials,
                                      style: const TextStyle(
                                        color: AppColors.primary,
                                        fontSize: 36,
                                        fontWeight: FontWeight.w800,
                                      ),
                                    ),
                                  )
                                : null,
                          ),
                          Positioned(
                            bottom: 0,
                            right: 0,
                            child: Container(
                              width: 28,
                              height: 28,
                              decoration: BoxDecoration(
                                color: AppColors.accent,
                                shape: BoxShape.circle,
                                border:
                                    Border.all(color: Colors.white, width: 2),
                              ),
                              child: const Icon(Icons.camera_alt,
                                  size: 14, color: AppColors.primary),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 14),
                    Text(
                      displayName,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 22,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      displayEmail,
                      style: TextStyle(
                        color: Colors.white.withOpacity(0.5),
                        fontSize: 13,
                      ),
                    ),
                    const SizedBox(height: 20),
                    Row(
                      children: [
                        _statItem('${contacts.totalContacts}', 'Contacts'),
                        Container(
                            width: 1,
                            height: 30,
                            color: Colors.white.withOpacity(0.1)),
                        _statItem('${contacts.hotLeads}', 'Hot Leads'),
                        Container(
                            width: 1,
                            height: 30,
                            color: Colors.white.withOpacity(0.1)),
                        _statItem('${contacts.warmLeads}', 'Warm'),
                      ],
                    ),
                  ],
                ),
              ),

              // Menu
              Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  children: [
                    _menuItem(
                      context,
                      Icons.person_rounded,
                      l10n.myProfile,
                      l10n.myProfileDesc,
                      AppColors.primary.withOpacity(0.08),
                      AppColors.primary,
                      () => context.push('/my-profile'),
                    ),
                    _menuItem(
                      context,
                      Icons.security_rounded,
                      l10n.accountSecurity,
                      l10n.accountSecurityDesc,
                      AppColors.warm.withOpacity(0.1),
                      AppColors.warm,
                      () => context.push('/account-security'),
                    ),
                    _menuItem(
                      context,
                      Icons.notifications_rounded,
                      l10n.notificationsTitle,
                      l10n.notificationsDesc,
                      AppColors.accent.withOpacity(0.1),
                      AppColors.accent,
                      () => context.push('/notifications'),
                    ),
                    _menuItem(
                      context,
                      Icons.star_rounded,
                      l10n.subscriptionLabel,
                      l10n.subscriptionDesc,
                      AppColors.warm.withOpacity(0.1),
                      AppColors.warm,
                      () => context.push('/pricing'),
                    ),
                    _menuItem(
                      context,
                      Icons.cloud_upload_rounded,
                      l10n.syncLabel,
                      effectivePlan == 'free'
                          ? l10n.syncLockedDesc
                          : l10n.syncDesc,
                      AppColors.success.withOpacity(0.1),
                      AppColors.success,
                      () => effectivePlan == 'free'
                          ? context.push('/pricing')
                          : context.push('/sync'),
                    ),
                    _menuItem(
                      context,
                      Icons.download_rounded,
                      l10n.exportLabel,
                      l10n.exportDesc,
                      const Color(0xFF34495E).withOpacity(0.08),
                      const Color(0xFF34495E),
                      () => context.push('/import-export'),
                    ),
                    _menuItem(
                      context,
                      Icons.settings_rounded,
                      l10n.settingsLabel,
                      l10n.settingsDesc,
                      AppColors.cold.withOpacity(0.15),
                      AppColors.cold,
                      () => context.push('/settings'),
                    ),
                    // ── Organization section ──────────────────────────────
                    if (hasOrg)
                      _menuItem(
                        context,
                        Icons.corporate_fare_rounded,
                        l10n.orgAdminMenuTitle,
                        orgRole == 'admin'
                            ? l10n.orgAdminMenuDesc
                            : l10n.orgMemberMenuDesc,
                        AppColors.primary.withValues(alpha: 0.08),
                        AppColors.primary,
                        () async {
                          final l10nRead = ref.read(l10nProvider);
                          final connectivity =
                              await Connectivity().checkConnectivity();
                          if (!context.mounted) return;
                          if (connectivity.contains(ConnectivityResult.none)) {
                            ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                              content:
                                  Text(l10nRead.orgScreenRequiresInternet),
                              backgroundColor: AppColors.hot,
                              duration: const Duration(seconds: 2),
                            ));
                            return;
                          }
                          context.push('/organization');
                        },
                      )
                    else ...[
                      _menuItem(
                        context,
                        Icons.corporate_fare_rounded,
                        l10n.createOrgTitle,
                        l10n.createOrgDesc,
                        AppColors.primary.withValues(alpha: 0.08),
                        AppColors.primary,
                        () => context.push('/organization/create'),
                      ),
                      _menuItem(
                        context,
                        Icons.group_add_rounded,
                        l10n.joinOrgTitle,
                        l10n.joinOrgDesc,
                        AppColors.accent.withValues(alpha: 0.1),
                        AppColors.accent,
                        () => context.push('/organization/join'),
                      ),
                    ],
                    _menuItem(
                      context,
                      Icons.help_outline_rounded,
                      l10n.helpLabel,
                      l10n.helpDesc,
                      const Color(0xFF607D8B).withOpacity(0.1),
                      const Color(0xFF607D8B),
                      _showHelpBottomSheet,
                    ),
                    const SizedBox(height: 8),
                    _menuItem(
                      context,
                      Icons.logout_rounded,
                      l10n.logoutLabel,
                      l10n.logoutDesc,
                      AppColors.hot.withOpacity(0.1),
                      AppColors.hot,
                      () async {
                        await ref.read(authProvider.notifier).logout();
                        await ref.read(contactsProvider.notifier).reload();
                        await ref.read(remindersProvider.notifier).reload();
                        if (context.mounted) context.go('/login');
                      },
                      isLogout: true,
                    ),
                    const SizedBox(height: 20),
                    Text(
                      'Me2Leads v1.0.0',
                      style: TextStyle(
                        fontSize: 12,
                        color: AppColors.hint(context),
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'De Bouana - ${l10n.slogan}',
                      style: TextStyle(
                        fontSize: 11,
                        color: AppColors.hint(context).withOpacity(0.6),
                      ),
                    ),
                    const SizedBox(height: 100),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _statItem(String value, String label) {
    return Expanded(
      child: Column(
        children: [
          Text(
            value,
            style: const TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.w800,
              color: AppColors.accent,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            label.toUpperCase(),
            style: TextStyle(
              fontSize: 10,
              color: Colors.white.withOpacity(0.4),
              letterSpacing: 0.5,
            ),
          ),
        ],
      ),
    );
  }

  Widget _menuItem(
    BuildContext context,
    IconData icon,
    String title,
    String subtitle,
    Color bgColor,
    Color iconColor,
    VoidCallback onTap, {
    bool isLogout = false,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: AppColors.surfaceColor(context),
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(12),
          child: Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: AppColors.borderColor(context)),
            ),
            child: Row(
              children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: bgColor,
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Icon(icon, color: iconColor, size: 20),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                          color: isLogout
                              ? AppColors.hot
                              : AppColors.onSurface(context),
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        subtitle,
                        style: TextStyle(
                          fontSize: 12,
                          color: AppColors.secondary(context),
                        ),
                      ),
                    ],
                  ),
                ),
                Icon(Icons.chevron_right_rounded,
                    color: AppColors.hint(context), size: 20),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

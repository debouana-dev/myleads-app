import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../core/l10n/app_l10n.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_theme.dart';
import '../../providers/auth_provider.dart';
import '../../providers/contacts_provider.dart';
import '../../providers/organization_provider.dart';
import '../../providers/reminders_provider.dart';
import '../../services/database_service.dart';
import '../../services/ftp_photo_service.dart';
import '../../services/remote_sync_service.dart';
import '../../services/storage_service.dart';

enum _SyncState { idle, loading, success, error }

class SyncScreen extends ConsumerStatefulWidget {
  const SyncScreen({super.key});

  @override
  ConsumerState<SyncScreen> createState() => _SyncScreenState();
}

class _SyncScreenState extends ConsumerState<SyncScreen> {
  _SyncState _state = _SyncState.idle;
  SyncResult? _lastResult;
  String? _lastSyncAt;
  _SyncState _ftpState = _SyncState.idle;
  String? _ftpErrorCode;

  @override
  void initState() {
    super.initState();
    _loadLastSync();
  }

  Future<void> _loadLastSync() async {
    final userId = StorageService.currentUserId;
    if (userId.isEmpty) return;
    final ts = await DatabaseService.getUserLastSync(userId);
    if (mounted) setState(() => _lastSyncAt = ts);
  }

  String _formatTs(String iso, AppL10n l10n) {
    try {
      final dt = DateTime.parse(iso).toLocal();
      return DateFormat('dd MMM yyyy – HH:mm').format(dt);
    } catch (_) {
      return iso;
    }
  }

  String _errorMessage(String? code, AppL10n l10n) {
    switch (code) {
      case 'no_connection':
        return l10n.syncErrNoConnection;
      case 'auth_failed':
        return l10n.syncErrAuthFailed;
      default:
        return l10n.syncErrUnknown;
    }
  }

  String _ftpErrorMessage(String? code, AppL10n l10n) {
    if (code == 'no_connection') return l10n.syncErrNoConnection;
    return l10n.ftpTestFailed;
  }

  Future<void> _runPush() async {
    final userId = StorageService.currentUserId;
    if (userId.isEmpty) return;
    setState(() {
      _state = _SyncState.loading;
      _lastResult = null;
    });
    final result = await RemoteSyncService.push(userId);
    await _loadLastSync();
    if (mounted) {
      setState(() {
        _state = result.success ? _SyncState.success : _SyncState.error;
        _lastResult = result;
      });
    }
  }

  Future<void> _runPull() async {
    final l10n = ref.read(l10nProvider);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text(l10n.syncConfirmPullTitle,
            style: const TextStyle(fontWeight: FontWeight.w700)),
        content: Text(l10n.syncConfirmPullBody,
            style: TextStyle(color: AppColors.secondary(context))),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(l10n.cancel)),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.primary,
              foregroundColor: Colors.white,
            ),
            child: Text(l10n.syncDownloadTitle),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    final userId = StorageService.currentUserId;
    if (userId.isEmpty) return;
    setState(() {
      _state = _SyncState.loading;
      _lastResult = null;
    });
    final result = await RemoteSyncService.pull(userId);
    if (result.success && mounted) {
      await ref.read(organizationProvider.notifier).loadForCurrentUser();
      await ref.read(contactsProvider.notifier).reload();
      await ref.read(remindersProvider.notifier).reload();
    }
    await _loadLastSync();
    if (mounted) {
      setState(() {
        _state = result.success ? _SyncState.success : _SyncState.error;
        _lastResult = result;
      });
    }
  }

  Future<void> _runFtpTest() async {
    setState(() {
      _ftpState = _SyncState.loading;
      _ftpErrorCode = null;
    });
    final error = await FtpPhotoService.testFtpConnection();
    if (mounted) {
      setState(() {
        _ftpState = error == null ? _SyncState.success : _SyncState.error;
        _ftpErrorCode = error;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = ref.watch(l10nProvider);
    final effectivePlan = ref.watch(effectivePlanProvider);
    final locked = effectivePlan.maybeWhen(
        data: (plan) => plan == 'free', orElse: () => true);

    return Scaffold(
      backgroundColor: AppColors.bg(context),
      body: Column(
        children: [
          // ── Header ──────────────────────────────────────────────────────
          Container(
            padding: EdgeInsets.only(
              top: MediaQuery.of(context).padding.top + 10,
              left: 20,
              right: 20,
              bottom: 24,
            ),
            decoration: const BoxDecoration(
              gradient: AppColors.primaryGradient,
              borderRadius: BorderRadius.only(
                bottomLeft: Radius.circular(28),
                bottomRight: Radius.circular(28),
              ),
            ),
            child: Row(
              children: [
                GestureDetector(
                  onTap: () => Navigator.pop(context),
                  child: Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Icon(Icons.arrow_back,
                        color: Colors.white, size: 20),
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Text(
                    l10n.syncScreenTitle,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 20,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: const Icon(Icons.cloud_sync_rounded,
                      color: Colors.white, size: 22),
                ),
              ],
            ),
          ),

          // ── Body ────────────────────────────────────────────────────────
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(20),
              child: Column(
                children: [
                  // Last sync card
                  _card(
                    context,
                    child: Row(
                      children: [
                        Container(
                          width: 40,
                          height: 40,
                          decoration: BoxDecoration(
                            color: AppColors.primary.withValues(alpha: 0.1),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: const Icon(Icons.history_rounded,
                              color: AppColors.primary, size: 20),
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                l10n.syncLastSyncLabel,
                                style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                  color: AppColors.hint(context),
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                _lastSyncAt != null
                                    ? _formatTs(_lastSyncAt!, l10n)
                                    : l10n.syncNever,
                                style: TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w700,
                                  color: AppColors.onSurface(context),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),

                  // Result / loading card
                  if (_state == _SyncState.loading)
                    _card(
                      context,
                      child: Row(
                        children: [
                          const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(
                              strokeWidth: 2.5,
                              valueColor:
                                  AlwaysStoppedAnimation(AppColors.primary),
                            ),
                          ),
                          const SizedBox(width: 14),
                          Text(l10n.syncInProgress,
                              style: TextStyle(
                                  fontSize: 14,
                                  color: AppColors.onSurface(context))),
                        ],
                      ),
                    ),

                  if (_state == _SyncState.success && _lastResult != null)
                    _card(
                      context,
                      child: Row(
                        children: [
                          Container(
                            width: 40,
                            height: 40,
                            decoration: BoxDecoration(
                              color: AppColors.success.withValues(alpha: 0.12),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: const Icon(Icons.check_circle_rounded,
                                color: AppColors.success, size: 22),
                          ),
                          const SizedBox(width: 14),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(l10n.syncSuccess,
                                    style: const TextStyle(
                                        fontSize: 14,
                                        fontWeight: FontWeight.w700)),
                                const SizedBox(height: 2),
                                Text(
                                  l10n.syncResultLabel(
                                    _lastResult!.contactCount,
                                    _lastResult!.reminderCount,
                                  ),
                                  style: TextStyle(
                                      fontSize: 12,
                                      color: AppColors.secondary(context)),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),

                  if (_state == _SyncState.error && _lastResult != null)
                    _card(
                      context,
                      child: Row(
                        children: [
                          Container(
                            width: 40,
                            height: 40,
                            decoration: BoxDecoration(
                              color: AppColors.hot.withValues(alpha: 0.1),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: const Icon(Icons.error_outline_rounded,
                                color: AppColors.hot, size: 22),
                          ),
                          const SizedBox(width: 14),
                          Expanded(
                            child: Text(
                              _errorMessage(_lastResult!.errorCode, l10n),
                              style: TextStyle(
                                  fontSize: 14,
                                  color: AppColors.onSurface(context)),
                            ),
                          ),
                        ],
                      ),
                    ),

                  if (_state != _SyncState.idle) const SizedBox(height: 12),

                  if (locked) ...[
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(20),
                      decoration: BoxDecoration(
                        gradient: const LinearGradient(
                          colors: [AppColors.accent, AppColors.accentLight],
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                        ),
                        borderRadius: BorderRadius.circular(16),
                        boxShadow: AppTheme.accentShadow,
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Container(
                                width: 44,
                                height: 44,
                                decoration: BoxDecoration(
                                  color: Colors.white.withValues(alpha: 0.25),
                                  borderRadius: BorderRadius.circular(14),
                                ),
                                child: const Icon(Icons.lock_rounded,
                                    color: AppColors.primary, size: 22),
                              ),
                              const SizedBox(width: 14),
                              Expanded(
                                child: Text(
                                  l10n.syncPlanGateTitle,
                                  style: const TextStyle(
                                    fontSize: 15,
                                    fontWeight: FontWeight.w800,
                                    color: AppColors.primary,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 12),
                          Text(
                            l10n.syncPlanGateBody,
                            style: TextStyle(
                              fontSize: 13,
                              color: AppColors.primary.withValues(alpha: 0.8),
                              height: 1.4,
                            ),
                          ),
                          const SizedBox(height: 16),
                          SizedBox(
                            width: double.infinity,
                            child: ElevatedButton(
                              onPressed: () => context.push('/pricing'),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: AppColors.primary,
                                foregroundColor: Colors.white,
                                padding:
                                    const EdgeInsets.symmetric(vertical: 14),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                elevation: 0,
                              ),
                              child: Text(
                                l10n.upgradeNow,
                                style: const TextStyle(
                                  fontWeight: FontWeight.w700,
                                  fontSize: 14,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ] else ...[
                    // Upload button
                    _actionTile(
                      context,
                      icon: Icons.cloud_upload_rounded,
                      iconColor: AppColors.success,
                      title: l10n.syncUploadTitle,
                      subtitle: l10n.syncUploadDesc,
                      onTap: _state == _SyncState.loading ? null : _runPush,
                    ),
                    const SizedBox(height: 8),

                    // Download button
                    _actionTile(
                      context,
                      icon: Icons.cloud_download_rounded,
                      iconColor: AppColors.primary,
                      title: l10n.syncDownloadTitle,
                      subtitle: l10n.syncDownloadDesc,
                      onTap: _state == _SyncState.loading ? null : _runPull,
                    ),
                  ],
                  const SizedBox(height: 40),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _card(BuildContext context, {required Widget child}) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surfaceColor(context),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.borderColor(context)),
      ),
      child: child,
    );
  }

  Widget _actionTile(
    BuildContext context, {
    required IconData icon,
    required Color iconColor,
    required String title,
    required String subtitle,
    required VoidCallback? onTap,
  }) {
    final disabled = onTap == null;
    return Material(
      color: AppColors.surfaceColor(context),
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: AppColors.borderColor(context)),
          ),
          child: Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: disabled
                      ? AppColors.hint(context).withValues(alpha: 0.08)
                      : iconColor.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Icon(
                  icon,
                  color: disabled ? AppColors.hint(context) : iconColor,
                  size: 22,
                ),
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
                        color: disabled
                            ? AppColors.hint(context)
                            : AppColors.onSurface(context),
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: TextStyle(
                          fontSize: 12, color: AppColors.secondary(context)),
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
    );
  }
}

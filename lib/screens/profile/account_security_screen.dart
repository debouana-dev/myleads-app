import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../core/theme/app_colors.dart';
import '../../core/l10n/app_l10n.dart';
import '../../providers/auth_provider.dart';
import '../../providers/contacts_provider.dart';
import '../../providers/reminders_provider.dart';

class AccountSecurityScreen extends ConsumerStatefulWidget {
  const AccountSecurityScreen({super.key});

  @override
  ConsumerState<AccountSecurityScreen> createState() =>
      _AccountSecurityScreenState();
}

class _AccountSecurityScreenState
    extends ConsumerState<AccountSecurityScreen> {
  final _formKey = GlobalKey<FormState>();

  final _currentPwdCtrl = TextEditingController();
  final _newPwdCtrl = TextEditingController();
  final _confirmPwdCtrl = TextEditingController();

  bool _showCurrentPwd = false;
  bool _showNewPwd = false;
  bool _showConfirmPwd = false;
  bool _isChanging = false;
  String? _changeError;

  // Email change state
  final _emailFormKey = GlobalKey<FormState>();
  final _emailCurrentPwdCtrl = TextEditingController();
  final _newEmailCtrl = TextEditingController();
  final _verificationCodeCtrl = TextEditingController();
  bool _codeSent = false;
  bool _isSendingCode = false;
  bool _isConfirmingEmail = false;
  String? _emailChangeError;
  bool _isDeletingAccount = false;

  // Password regex: 8-15 chars, at least 1 letter, 1 digit, 1 symbol, no spaces
  static final _pwdRegex =
      RegExp(r'^(?=.*[A-Za-z])(?=.*\d)(?=.*[!@#\$%^&*()_+\-=\[\]{};:\\|,.<>\/?])[^\s]{8,15}$');

  @override
  void dispose() {
    _currentPwdCtrl.dispose();
    _newPwdCtrl.dispose();
    _confirmPwdCtrl.dispose();
    _emailCurrentPwdCtrl.dispose();
    _newEmailCtrl.dispose();
    _verificationCodeCtrl.dispose();
    super.dispose();
  }

  Future<void> _onChangePassword(AppL10n l10n) async {
    if (!(_formKey.currentState?.validate() ?? false)) return;

    setState(() {
      _isChanging = true;
      _changeError = null;
    });

    final error = await ref.read(authProvider.notifier).changePassword(
          _currentPwdCtrl.text,
          _newPwdCtrl.text,
        );

    if (!mounted) return;

    if (error != null) {
      setState(() {
        _isChanging = false;
        _changeError = error;
      });
      return;
    }

    // Success: show toast, logout, navigate to /login
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            const Icon(Icons.check_circle, color: Colors.white, size: 18),
            const SizedBox(width: 8),
            Expanded(child: Text(l10n.passwordChanged)),
          ],
        ),
        backgroundColor: AppColors.success,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        margin: const EdgeInsets.all(16),
        duration: const Duration(seconds: 2),
      ),
    );

    await Future.delayed(const Duration(seconds: 2));
    if (!mounted) return;

    await ref.read(authProvider.notifier).logout();
    await ref.read(contactsProvider.notifier).reload();
    await ref.read(remindersProvider.notifier).reload();
    if (mounted) context.go('/login');
  }

  Future<void> _onSendVerificationCode() async {
    if (!(_emailFormKey.currentState?.validate() ?? false)) return;
    setState(() {
      _isSendingCode = true;
      _emailChangeError = null;
    });
    final error = await ref
        .read(authProvider.notifier)
        .initiateEmailChange(_newEmailCtrl.text.trim());
    if (!mounted) return;
    if (error != null) {
      setState(() {
        _isSendingCode = false;
        _emailChangeError = error;
      });
      return;
    }
    setState(() {
      _codeSent = true;
      _isSendingCode = false;
    });
  }

  Future<void> _onConfirmEmailChange(AppL10n l10n) async {
    setState(() {
      _isConfirmingEmail = true;
      _emailChangeError = null;
    });

    final error = await ref.read(authProvider.notifier).changeEmail(
          _newEmailCtrl.text.trim(),
          _verificationCodeCtrl.text.trim(),
          _emailCurrentPwdCtrl.text,
        );

    if (!mounted) return;

    if (error != null) {
      setState(() {
        _isConfirmingEmail = false;
        _emailChangeError = error;
      });
      return;
    }

    // Success: toast, logout, navigate to /login
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            const Icon(Icons.check_circle, color: Colors.white, size: 18),
            const SizedBox(width: 8),
            Expanded(child: Text(l10n.emailChangedSuccess)),
          ],
        ),
        backgroundColor: AppColors.success,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        margin: const EdgeInsets.all(16),
        duration: const Duration(seconds: 2),
      ),
    );

    await Future.delayed(const Duration(seconds: 2));
    if (!mounted) return;

    await ref.read(authProvider.notifier).logout();
    await ref.read(contactsProvider.notifier).reload();
    await ref.read(remindersProvider.notifier).reload();
    if (mounted) context.go('/login');
  }

  Future<void> _onDeleteAccount(AppL10n l10n) async {
    final confirmed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (dialogCtx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Row(
          children: [
            const Icon(Icons.warning_amber_rounded, color: AppColors.error),
            const SizedBox(width: 10),
            Text(
              l10n.deleteAccountConfirmTitle,
              style: TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w800,
                color: AppColors.onSurface(context),
              ),
            ),
          ],
        ),
        content: Text(
          l10n.deleteAccountConfirmMessage,
          style: TextStyle(
            fontSize: 14,
            color: AppColors.secondary(context),
            height: 1.5,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogCtx, false),
            child: Text(
              l10n.cancel,
              style: TextStyle(
                color: AppColors.secondary(context),
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(dialogCtx, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.error,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
              ),
            ),
            child: Text(
              l10n.delete,
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;

    setState(() => _isDeletingAccount = true);
    final error = await ref.read(authProvider.notifier).deleteAccount();
    if (!mounted) return;

    if (error != null) {
      setState(() => _isDeletingAccount = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(error),
          backgroundColor: AppColors.error,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10)),
          margin: const EdgeInsets.all(16),
        ),
      );
      return;
    }

    await ref.read(contactsProvider.notifier).reload();
    await ref.read(remindersProvider.notifier).reload();
    if (!mounted) return;
    context.go('/login');
  }

  @override
  Widget build(BuildContext context) {
    final l10n = ref.watch(l10nProvider);

    return Scaffold(
      backgroundColor: AppColors.bg(context),
      body: Column(
        children: [
          // ── Gradient Header ──────────────────────────────────────
          Container(
            padding: EdgeInsets.only(
              top: MediaQuery.of(context).padding.top + 8,
              bottom: 28,
              left: 16,
              right: 16,
            ),
            decoration: const BoxDecoration(
              gradient: AppColors.primaryGradient,
              borderRadius: BorderRadius.only(
                bottomLeft: Radius.circular(32),
                bottomRight: Radius.circular(32),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Back button row
                Row(
                  children: [
                    GestureDetector(
                      onTap: () => context.pop(),
                      child: Container(
                        width: 40,
                        height: 40,
                        decoration: BoxDecoration(
                          color: Colors.white.withOpacity(0.12),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: const Icon(
                          Icons.arrow_back_ios_new_rounded,
                          color: Colors.white,
                          size: 20,
                        ),
                      ),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            l10n.accountSecurity,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 18,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            l10n.accountSecuritySubtitle,
                            style: TextStyle(
                              color: Colors.white.withOpacity(0.55),
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    ),
                    Container(
                      width: 44,
                      height: 44,
                      decoration: BoxDecoration(
                        color: Colors.white.withOpacity(0.12),
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: const Icon(
                        Icons.security_rounded,
                        color: AppColors.accent,
                        size: 22,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),

          // ── Scrollable Body ──────────────────────────────────────
          Expanded(
            child: SingleChildScrollView(
              padding:
                  const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
              child: Form(
                key: _formKey,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // ── Section 1: Change Password ──────────────────
                    _sectionHeader(
                      context: context,
                      icon: Icons.lock_reset_rounded,
                      title: l10n.changePassword,
                      color: AppColors.primary,
                    ),
                    const SizedBox(height: 12),
                    Container(
                      decoration: BoxDecoration(
                        color: AppColors.surfaceColor(context),
                        borderRadius: BorderRadius.circular(16),
                        boxShadow: [
                          BoxShadow(
                            color: AppColors.primary.withOpacity(0.07),
                            blurRadius: 20,
                            offset: const Offset(0, 4),
                          ),
                        ],
                      ),
                      padding: const EdgeInsets.all(20),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // Current password
                          _passwordField(
                            context: context,
                            label: l10n.currentPassword,
                            controller: _currentPwdCtrl,
                            obscure: !_showCurrentPwd,
                            onToggle: () => setState(
                                () => _showCurrentPwd = !_showCurrentPwd),
                            validator: (v) {
                              if (v == null || v.isEmpty) {
                                return l10n.currentPasswordRequired;
                              }
                              return null;
                            },
                          ),
                          const SizedBox(height: 16),

                          // New password
                          _passwordField(
                            context: context,
                            label: l10n.newPasswordLabel,
                            controller: _newPwdCtrl,
                            obscure: !_showNewPwd,
                            onToggle: () =>
                                setState(() => _showNewPwd = !_showNewPwd),
                            validator: (v) {
                              if (v == null || v.isEmpty) {
                                return l10n.newPasswordRequired;
                              }
                              if (!_pwdRegex.hasMatch(v)) {
                                return l10n.passwordInvalidFormat;
                              }
                              return null;
                            },
                          ),
                          const SizedBox(height: 16),

                          // Confirm password
                          _passwordField(
                            context: context,
                            label: l10n.confirmPasswordSec,
                            controller: _confirmPwdCtrl,
                            obscure: !_showConfirmPwd,
                            onToggle: () => setState(
                                () => _showConfirmPwd = !_showConfirmPwd),
                            validator: (v) {
                              if (v == null || v.isEmpty) {
                                return l10n.confirmRequired;
                              }
                              if (v != _newPwdCtrl.text) {
                                return l10n.passwordsNotMatch;
                              }
                              return null;
                            },
                          ),
                          const SizedBox(height: 14),

                          // Password rules hint
                          Container(
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: AppColors.primary.withOpacity(0.05),
                              borderRadius: BorderRadius.circular(10),
                              border: Border.all(
                                  color: AppColors.borderColor(context)),
                            ),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Icon(
                                  Icons.info_outline_rounded,
                                  size: 15,
                                  color: AppColors.secondary(context),
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    l10n.passwordRules,
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: AppColors.secondary(context),
                                      height: 1.4,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),

                          // Error display
                          if (_changeError != null) ...[
                            const SizedBox(height: 14),
                            Container(
                              padding: const EdgeInsets.all(12),
                              decoration: BoxDecoration(
                                color: AppColors.error.withOpacity(0.08),
                                borderRadius: BorderRadius.circular(10),
                                border: Border.all(
                                    color: AppColors.error.withOpacity(0.3)),
                              ),
                              child: Row(
                                children: [
                                  const Icon(Icons.error_outline,
                                      size: 16, color: AppColors.error),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Text(
                                      _changeError!,
                                      style: const TextStyle(
                                        fontSize: 13,
                                        color: AppColors.error,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],

                          const SizedBox(height: 20),

                          // Change password button
                          SizedBox(
                            width: double.infinity,
                            height: 50,
                            child: ElevatedButton(
                              onPressed: _isChanging ? null : () => _onChangePassword(l10n),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: AppColors.accent,
                                foregroundColor: AppColors.primary,
                                disabledBackgroundColor:
                                    AppColors.accent.withOpacity(0.5),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                elevation: 0,
                              ),
                              child: _isChanging
                                  ? const SizedBox(
                                      width: 22,
                                      height: 22,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2.5,
                                        color: AppColors.primary,
                                      ),
                                    )
                                  : Text(
                                      l10n.changePassword,
                                      style: const TextStyle(
                                        fontSize: 15,
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                            ),
                          ),
                        ],
                      ),
                    ),

                    // ── Section 2: Change Email ───────────────
                    _sectionHeader(
                      context: context,
                      icon: Icons.email_rounded,
                      title: l10n.changeEmail,
                      color: AppColors.primary,
                    ),
                    const SizedBox(height: 12),
                    Form(
                      key: _emailFormKey,
                      child: Container(
                        decoration: BoxDecoration(
                          color: AppColors.surfaceColor(context),
                          borderRadius: BorderRadius.circular(16),
                          boxShadow: [
                            BoxShadow(
                              color: AppColors.primary.withOpacity(0.07),
                              blurRadius: 20,
                              offset: const Offset(0, 4),
                            ),
                          ],
                        ),
                        padding: const EdgeInsets.all(20),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            _passwordField(
                              context: context,
                              label: l10n.currentPassword,
                              controller: _emailCurrentPwdCtrl,
                              obscure: true,
                              onToggle: () {},
                              validator: (v) {
                                if (v == null || v.isEmpty) {
                                  return l10n.currentPasswordRequired;
                                }
                                return null;
                              },
                            ),
                            const SizedBox(height: 16),
                            Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  l10n.newEmail,
                                  style: TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600,
                                    color: AppColors.secondary(context),
                                    letterSpacing: 0.3,
                                  ),
                                ),
                                const SizedBox(height: 6),
                                TextFormField(
                                  controller: _newEmailCtrl,
                                  keyboardType: TextInputType.emailAddress,
                                  enabled: !_codeSent,
                                  validator: (v) {
                                    if (v == null || v.trim().isEmpty) {
                                      return l10n.emailRequired;
                                    }
                                    if (!v.contains('@')) {
                                      return l10n.emailInvalid;
                                    }
                                    return null;
                                  },
                                  style: TextStyle(
                                    fontSize: 14,
                                    fontWeight: FontWeight.w600,
                                    color: AppColors.onSurface(context),
                                  ),
                                  decoration: InputDecoration(
                                    hintText: 'nouvel@email.com',
                                    filled: true,
                                    fillColor: AppColors.bg(context),
                                    contentPadding: const EdgeInsets.symmetric(
                                        horizontal: 14, vertical: 14),
                                    border: OutlineInputBorder(
                                      borderRadius: BorderRadius.circular(10),
                                      borderSide: BorderSide.none,
                                    ),
                                    enabledBorder: OutlineInputBorder(
                                      borderRadius: BorderRadius.circular(10),
                                      borderSide: BorderSide(
                                          color: AppColors.borderColor(context)),
                                    ),
                                    focusedBorder: OutlineInputBorder(
                                      borderRadius: BorderRadius.circular(10),
                                      borderSide: const BorderSide(
                                          color: AppColors.accent, width: 1.5),
                                    ),
                                    errorBorder: OutlineInputBorder(
                                      borderRadius: BorderRadius.circular(10),
                                      borderSide: const BorderSide(
                                          color: AppColors.error),
                                    ),
                                    focusedErrorBorder: OutlineInputBorder(
                                      borderRadius: BorderRadius.circular(10),
                                      borderSide: const BorderSide(
                                          color: AppColors.error, width: 1.5),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            if (_codeSent) ...[
                              const SizedBox(height: 16),
                              Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    l10n.verificationCodeLabel,
                                    style: TextStyle(
                                      fontSize: 12,
                                      fontWeight: FontWeight.w600,
                                      color: AppColors.secondary(context),
                                      letterSpacing: 0.3,
                                    ),
                                  ),
                                  const SizedBox(height: 6),
                                  TextFormField(
                                    controller: _verificationCodeCtrl,
                                    keyboardType: TextInputType.number,
                                    maxLength: 6,
                                    style: TextStyle(
                                      fontSize: 14,
                                      fontWeight: FontWeight.w600,
                                      color: AppColors.onSurface(context),
                                      letterSpacing: 4,
                                    ),
                                    decoration: InputDecoration(
                                      hintText: '0000000',
                                      counterText: '',
                                      filled: true,
                                      fillColor: AppColors.bg(context),
                                      contentPadding:
                                          const EdgeInsets.symmetric(
                                              horizontal: 14, vertical: 14),
                                      border: OutlineInputBorder(
                                        borderRadius: BorderRadius.circular(10),
                                        borderSide: BorderSide.none,
                                      ),
                                      enabledBorder: OutlineInputBorder(
                                        borderRadius: BorderRadius.circular(10),
                                        borderSide: BorderSide(
                                            color:
                                                AppColors.borderColor(context)),
                                      ),
                                      focusedBorder: OutlineInputBorder(
                                        borderRadius: BorderRadius.circular(10),
                                        borderSide: const BorderSide(
                                            color: AppColors.accent, width: 1.5),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ],
                            if (_emailChangeError != null) ...[
                              const SizedBox(height: 14),
                              Container(
                                padding: const EdgeInsets.all(12),
                                decoration: BoxDecoration(
                                  color: AppColors.error.withOpacity(0.08),
                                  borderRadius: BorderRadius.circular(10),
                                  border: Border.all(
                                      color: AppColors.error.withOpacity(0.3)),
                                ),
                                child: Row(
                                  children: [
                                    const Icon(Icons.error_outline,
                                        size: 16, color: AppColors.error),
                                    const SizedBox(width: 8),
                                    Expanded(
                                      child: Text(
                                        _emailChangeError!,
                                        style: const TextStyle(
                                            fontSize: 13,
                                            color: AppColors.error),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                            const SizedBox(height: 20),
                            SizedBox(
                              width: double.infinity,
                              height: 50,
                              child: ElevatedButton(
                                onPressed: _isSendingCode || _isConfirmingEmail
                                    ? null
                                    : (_codeSent
                                        ? () => _onConfirmEmailChange(l10n)
                                        : _onSendVerificationCode),
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: AppColors.accent,
                                  foregroundColor: AppColors.primary,
                                  disabledBackgroundColor:
                                      AppColors.accent.withOpacity(0.5),
                                  shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(12)),
                                  elevation: 0,
                                ),
                                child: (_isSendingCode || _isConfirmingEmail)
                                    ? const SizedBox(
                                        width: 22,
                                        height: 22,
                                        child: CircularProgressIndicator(
                                            strokeWidth: 2.5,
                                            color: AppColors.primary),
                                      )
                                    : Text(
                                        _codeSent
                                            ? l10n.saveButton
                                            : l10n.sendVerificationCode,
                                        style: const TextStyle(
                                            fontSize: 15,
                                            fontWeight: FontWeight.w700),
                                      ),
                              ),
                            ),
                            if (_codeSent) ...[
                              const SizedBox(height: 12),
                              Center(
                                child: GestureDetector(
                                  onTap: () => setState(() {
                                    _codeSent = false;
                                    _verificationCodeCtrl.clear();
                                    _emailChangeError = null;
                                  }),
                                  child: Text(
                                    l10n.changeEmailLabel,
                                    style: const TextStyle(
                                        fontSize: 13,
                                        color: AppColors.primary,
                                        fontWeight: FontWeight.w600),
                                  ),
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),

                    const SizedBox(height: 28),

                    const SizedBox(height: 28),

                    // ── Section 3: Delete Account ───────────────────
                    _sectionHeader(
                      context: context,
                      icon: Icons.warning_amber_rounded,
                      title: l10n.deleteAccountTitle,
                      color: AppColors.error,
                    ),
                    const SizedBox(height: 12),
                    Container(
                      decoration: BoxDecoration(
                        color: AppColors.surfaceColor(context),
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(
                            color: AppColors.error.withOpacity(0.2)),
                        boxShadow: [
                          BoxShadow(
                            color: AppColors.error.withOpacity(0.06),
                            blurRadius: 20,
                            offset: const Offset(0, 4),
                          ),
                        ],
                      ),
                      padding: const EdgeInsets.all(20),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // Warning banner
                          Container(
                            padding: const EdgeInsets.all(14),
                            decoration: BoxDecoration(
                              color: AppColors.error.withOpacity(0.07),
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(
                                  color: AppColors.error.withOpacity(0.25)),
                            ),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Icon(
                                  Icons.warning_amber_rounded,
                                  size: 20,
                                  color: AppColors.error,
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Text(
                                    l10n.deleteAccountWarning,
                                    style: const TextStyle(
                                      fontSize: 13,
                                      color: AppColors.error,
                                      fontWeight: FontWeight.w500,
                                      height: 1.4,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 18),

                          // Delete button (outlined red)
                          SizedBox(
                            width: double.infinity,
                            height: 50,
                            child: OutlinedButton(
                              onPressed: _isDeletingAccount
                                  ? null
                                  : () => _onDeleteAccount(l10n),
                              style: OutlinedButton.styleFrom(
                                foregroundColor: AppColors.error,
                                side: BorderSide(
                                  color: _isDeletingAccount
                                      ? AppColors.error.withOpacity(0.4)
                                      : AppColors.error,
                                  width: 1.5,
                                ),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(12),
                                ),
                              ),
                              child: _isDeletingAccount
                                  ? const SizedBox(
                                      width: 20,
                                      height: 20,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                        valueColor:
                                            AlwaysStoppedAnimation<Color>(
                                                AppColors.error),
                                      ),
                                    )
                                  : Text(
                                      l10n.deleteMyAccount,
                                      style: const TextStyle(
                                        fontSize: 15,
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                            ),
                          ),
                        ],
                      ),
                    ),

                    const SizedBox(height: 32),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _sectionHeader({
    required BuildContext context,
    required IconData icon,
    required String title,
    required Color color,
  }) {
    return Row(
      children: [
        Container(
          width: 32,
          height: 32,
          decoration: BoxDecoration(
            color: color.withOpacity(0.1),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(icon, size: 17, color: color),
        ),
        const SizedBox(width: 10),
        Text(
          title,
          style: TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w800,
            color: color == AppColors.error
                ? AppColors.error
                : AppColors.onSurface(context),
          ),
        ),
      ],
    );
  }

  Widget _passwordField({
    required BuildContext context,
    required String label,
    required TextEditingController controller,
    required bool obscure,
    required VoidCallback onToggle,
    String? Function(String?)? validator,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: AppColors.secondary(context),
            letterSpacing: 0.3,
          ),
        ),
        const SizedBox(height: 6),
        TextFormField(
          controller: controller,
          obscureText: obscure,
          validator: validator,
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w600,
            color: AppColors.onSurface(context),
          ),
          decoration: InputDecoration(
            filled: true,
            fillColor: AppColors.bg(context),
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 14,
              vertical: 14,
            ),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: BorderSide.none,
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: BorderSide(color: AppColors.borderColor(context)),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: const BorderSide(color: AppColors.accent, width: 1.5),
            ),
            errorBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: const BorderSide(color: AppColors.error),
            ),
            focusedErrorBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide:
                  const BorderSide(color: AppColors.error, width: 1.5),
            ),
            suffixIcon: IconButton(
              icon: Icon(
                obscure ? Icons.visibility_off_rounded : Icons.visibility_rounded,
                size: 20,
                color: AppColors.hint(context),
              ),
              onPressed: onToggle,
            ),
          ),
        ),
      ],
    );
  }
}

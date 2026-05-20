import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

// import '../../core/constants/app_strings.dart';
import '../../core/l10n/app_l10n.dart';
import '../../core/theme/app_colors.dart';
import '../../providers/auth_provider.dart';
import '../../providers/contacts_provider.dart';
import '../../providers/reminders_provider.dart';

class SignupScreen extends ConsumerStatefulWidget {
  const SignupScreen({super.key});

  @override
  ConsumerState<SignupScreen> createState() => _SignupScreenState();
}

class _SignupScreenState extends ConsumerState<SignupScreen>
    with SingleTickerProviderStateMixin {
  final _formKey = GlobalKey<FormState>();
  final _firstNameController = TextEditingController();
  final _lastNameController = TextEditingController();
  final _emailController = TextEditingController();
  final _phoneController = TextEditingController();
  final _passwordController = TextEditingController();
  final _confirmPasswordController = TextEditingController();
  bool _obscurePassword = true;
  bool _obscureConfirmPassword = true;
  bool _acceptedPrivacyPolicy = false;

  late final AnimationController _animController;
  late final Animation<double> _headerSlide;
  late final Animation<double> _formFade;

  @override
  void initState() {
    super.initState();
    _animController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1000),
    );

    _headerSlide = Tween<double>(begin: -30, end: 0).animate(
      CurvedAnimation(
        parent: _animController,
        curve: const Interval(0.0, 0.5, curve: Curves.easeOutCubic),
      ),
    );

    _formFade = Tween<double>(begin: 0, end: 1).animate(
      CurvedAnimation(
        parent: _animController,
        curve: const Interval(0.3, 0.8, curve: Curves.easeOut),
      ),
    );

    _animController.forward();
  }

  @override
  void dispose() {
    _animController.dispose();
    _firstNameController.dispose();
    _lastNameController.dispose();
    _emailController.dispose();
    _phoneController.dispose();
    _passwordController.dispose();
    _confirmPasswordController.dispose();
    super.dispose();
  }

  Future<void> _handleSignup() async {
    if (!_formKey.currentState!.validate()) return;

    if (!_acceptedPrivacyPolicy) {
      _showPrivacyPolicyError();
      return;
    }

    final success = await ref.read(authProvider.notifier).signup(
          firstName: _firstNameController.text.trim(),
          lastName: _lastNameController.text.trim(),
          email: _emailController.text.trim(),
          password: _passwordController.text,
          phone: _phoneController.text.trim().isEmpty
              ? null
              : _phoneController.text.trim(),
        );

    if (success && mounted) {
      // Log out so the user must verify their email and then login.
      await ref.read(authProvider.notifier).logout();
      if (mounted) {
        // Navigate to email verification — it will redirect to /login on success.
        context.go(
          '/email-verification',
          extra: _emailController.text.trim(),
        );
      }
    }
  }

  Future<void> _handleGoogleSignIn() async {
    if (!_acceptedPrivacyPolicy) {
      _showPrivacyPolicyError();
      return;
    }
    final success = await ref.read(authProvider.notifier).signInWithGoogle();
    if (success && mounted) {
      await ref.read(contactsProvider.notifier).reload();
      await ref.read(remindersProvider.notifier).reload();
      if (mounted) context.go('/main');
    }
  }

  Future<void> _handleAppleSignIn() async {
    if (!_acceptedPrivacyPolicy) {
      _showPrivacyPolicyError();
      return;
    }
    final success = await ref.read(authProvider.notifier).signInWithApple();
    if (success && mounted) {
      await ref.read(contactsProvider.notifier).reload();
      await ref.read(remindersProvider.notifier).reload();
      if (mounted) context.go('/main');
    }
  }

  void _showPrivacyPolicyError() {
    final l10n = ref.read(l10nProvider);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(l10n.privacyPolicyRequired),
        backgroundColor: AppColors.error,
        behavior: SnackBarBehavior.floating,
      ),
    );
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

  @override
  Widget build(BuildContext context) {
    final l10n = ref.watch(l10nProvider);
    final authState = ref.watch(authProvider);

    return Scaffold(
      backgroundColor: AppColors.bg(context),
      body: AnimatedBuilder(
        animation: _animController,
        builder: (context, child) {
          return SingleChildScrollView(
            child: Column(
              children: [
                Transform.translate(
                  offset: Offset(0, _headerSlide.value),
                  child: _buildHeader(l10n),
                ),
                Opacity(
                  opacity: _formFade.value,
                  child: Transform.translate(
                    offset: Offset(0, 20 * (1 - _formFade.value)),
                    child: _buildForm(authState, l10n),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _buildHeader(AppL10n l10n) {
    return Container(
      width: double.infinity,
      height: 250,
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [AppColors.primary, AppColors.primaryLight],
        ),
        borderRadius: BorderRadius.only(
          bottomLeft: Radius.circular(40),
          bottomRight: Radius.circular(40),
        ),
      ),
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const SizedBox(height: 4),
              GestureDetector(
                onTap: () => context.pop(),
                child: Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.12),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Center(
                    child: Icon(
                      Icons.arrow_back_ios_new_rounded,
                      size: 18,
                      color: Colors.white,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Text(
                l10n.signup,
                style: const TextStyle(
                  fontSize: 30,
                  fontWeight: FontWeight.w800,
                  color: Colors.white,
                  letterSpacing: -0.5,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                l10n.signupSubtitle,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                  color: Colors.white.withOpacity(0.7),
                  height: 1.4,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildForm(AuthState authState, AppL10n l10n) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 30, 24, 24),
      child: Form(
        key: _formKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (authState.error != null) ...[
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: AppColors.error.withOpacity(0.08),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: AppColors.error.withOpacity(0.2),
                  ),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.error_outline_rounded,
                        color: AppColors.error, size: 20),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        authState.error!,
                        style: const TextStyle(
                          color: AppColors.error,
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 20),
            ],

            // First name
            _buildInputLabel(l10n.firstName),
            const SizedBox(height: 8),
            TextFormField(
              controller: _firstNameController,
              keyboardType: TextInputType.name,
              textInputAction: TextInputAction.next,
              textCapitalization: TextCapitalization.words,
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: AppColors.onSurface(context),
              ),
              decoration: InputDecoration(
                hintText: l10n.firstNameHint,
                prefixIcon: Icon(
                  Icons.person_outline_rounded,
                  color: AppColors.hint(context).withOpacity(0.7),
                  size: 20,
                ),
              ),
              validator: (value) {
                if (value == null || value.trim().isEmpty) {
                  return l10n.firstNameRequired;
                }
                return null;
              },
            ),

            const SizedBox(height: 16),

            // Last name
            _buildInputLabel(l10n.lastName),
            const SizedBox(height: 8),
            TextFormField(
              controller: _lastNameController,
              keyboardType: TextInputType.name,
              textInputAction: TextInputAction.next,
              textCapitalization: TextCapitalization.words,
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: AppColors.onSurface(context),
              ),
              decoration: InputDecoration(
                hintText: l10n.lastNameHint,
                prefixIcon: Icon(
                  Icons.badge_outlined,
                  color: AppColors.hint(context).withOpacity(0.7),
                  size: 20,
                ),
              ),
              validator: (value) {
                if (value == null || value.trim().isEmpty) {
                  return l10n.lastNameRequired;
                }
                return null;
              },
            ),

            const SizedBox(height: 16),

            // Email
            _buildInputLabel(l10n.emailLabel),
            const SizedBox(height: 8),
            TextFormField(
              controller: _emailController,
              keyboardType: TextInputType.emailAddress,
              textInputAction: TextInputAction.next,
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: AppColors.onSurface(context),
              ),
              decoration: InputDecoration(
                hintText: l10n.emailHint,
                prefixIcon: Icon(
                  Icons.email_outlined,
                  color: AppColors.hint(context).withOpacity(0.7),
                  size: 20,
                ),
              ),
              validator: (value) {
                if (value == null || value.isEmpty) {
                  return l10n.emailRequired;
                }
                if (!value.contains('@') || !value.contains('.')) {
                  return l10n.emailInvalid;
                }
                return null;
              },
            ),

            const SizedBox(height: 16),

            // Phone (optional but enforced unique if provided)
            _buildInputLabel(l10n.phoneOptional),
            const SizedBox(height: 8),
            TextFormField(
              controller: _phoneController,
              keyboardType: TextInputType.phone,
              textInputAction: TextInputAction.next,
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: AppColors.onSurface(context),
              ),
              decoration: InputDecoration(
                hintText: l10n.phoneHintAuth,
                prefixIcon: Icon(
                  Icons.phone_outlined,
                  color: AppColors.hint(context).withOpacity(0.7),
                  size: 20,
                ),
              ),
            ),

            const SizedBox(height: 16),

            // Password
            _buildInputLabel(l10n.passwordLabel),
            const SizedBox(height: 8),
            TextFormField(
              controller: _passwordController,
              obscureText: _obscurePassword,
              textInputAction: TextInputAction.next,
              maxLength: 15,
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: AppColors.onSurface(context),
              ),
              decoration: InputDecoration(
                hintText: l10n.passwordHintAuth,
                prefixIcon: Icon(
                  Icons.lock_outline_rounded,
                  color: AppColors.hint(context).withOpacity(0.7),
                  size: 20,
                ),
                suffixIcon: GestureDetector(
                  onTap: () {
                    setState(() {
                      _obscurePassword = !_obscurePassword;
                    });
                  },
                  child: Icon(
                    _obscurePassword
                        ? Icons.visibility_off_outlined
                        : Icons.visibility_outlined,
                    color: AppColors.hint(context),
                    size: 20,
                  ),
                ),
              ),
              validator: (value) {
                if (value == null || value.isEmpty) {
                  return l10n.passwordRequired;
                }
                if (value.length < 8 || value.length > 15) {
                  return l10n.passwordLengthError;
                }
                if (value.contains(RegExp(r'\s'))) {
                  return l10n.passwordNoSpaces;
                }
                if (!value.contains(RegExp(r'[A-Za-z]'))) {
                  return l10n.passwordNeedsLetter;
                }
                if (!value.contains(RegExp(r'[0-9]'))) {
                  return l10n.passwordNeedsDigit;
                }
                if (!value.contains(
                    RegExp(r'''[!@#\$%^&*(),.?":{}|<>_\-+=\[\]\\/~`;]'''))) {
                  return l10n.passwordNeedsSymbol;
                }
                return null;
              },
            ),

            const SizedBox(height: 8),

            // Confirm password
            _buildInputLabel(l10n.confirmPasswordLabel),
            const SizedBox(height: 8),
            TextFormField(
              controller: _confirmPasswordController,
              obscureText: _obscureConfirmPassword,
              textInputAction: TextInputAction.done,
              maxLength: 15,
              onFieldSubmitted: (_) => _handleSignup(),
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: AppColors.onSurface(context),
              ),
              decoration: InputDecoration(
                hintText: l10n.confirmPasswordHint,
                prefixIcon: Icon(
                  Icons.lock_outline_rounded,
                  color: AppColors.hint(context).withOpacity(0.7),
                  size: 20,
                ),
                suffixIcon: GestureDetector(
                  onTap: () {
                    setState(() {
                      _obscureConfirmPassword = !_obscureConfirmPassword;
                    });
                  },
                  child: Icon(
                    _obscureConfirmPassword
                        ? Icons.visibility_off_outlined
                        : Icons.visibility_outlined,
                    color: AppColors.hint(context),
                    size: 20,
                  ),
                ),
              ),
              validator: (value) {
                if (value == null || value.isEmpty) {
                  return l10n.confirmPasswordRequired;
                }
                if (value != _passwordController.text) {
                  return l10n.passwordsNotMatch;
                }
                return null;
              },
            ),

            const SizedBox(height: 12),

            // Privacy Policy Checkbox
            Row(
              children: [
                SizedBox(
                  height: 24,
                  width: 24,
                  child: Checkbox(
                    value: _acceptedPrivacyPolicy,
                    activeColor: AppColors.accent,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(4),
                    ),
                    side: BorderSide(
                      color: AppColors.hint(context).withOpacity(0.5),
                      width: 1.5,
                    ),
                    onChanged: (value) {
                      setState(() {
                        _acceptedPrivacyPolicy = value ?? false;
                      });
                    },
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: GestureDetector(
                    onTap: () {
                      setState(() {
                        _acceptedPrivacyPolicy = !_acceptedPrivacyPolicy;
                      });
                    },
                    child: Text.rich(
                      TextSpan(
                        text: l10n.privacyPolicyAccept,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                          color: AppColors.secondary(context),
                        ),
                        children: [
                          TextSpan(
                            text: l10n.privacyPolicyLink,
                            recognizer: TapGestureRecognizer()
                              ..onTap = _launchPrivacyPolicy,
                            style: const TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w800,
                              color: AppColors.accent,
                              decoration: TextDecoration.underline,
                              decorationColor: AppColors.accent,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),

            const SizedBox(height: 24),

            _buildAccentButton(
              label: l10n.signup,
              isLoading: authState.isLoading,
              onPressed: _handleSignup,
            ),

            const SizedBox(height: 24),

            _buildOrDivider(l10n),

            const SizedBox(height: 24),

            Row(
              children: [
                Expanded(
                  child: _buildSocialButton(
                    label: 'Google',
                    icon: Icons.g_mobiledata_rounded,
                    onPressed: _handleGoogleSignIn,
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: _buildSocialButton(
                    label: 'Apple',
                    icon: Icons.apple_rounded,
                    onPressed: _handleAppleSignIn,
                  ),
                ),
              ],
            ),

            const SizedBox(height: 28),

            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  '${l10n.hasAccount} ',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                    color: AppColors.secondary(context),
                  ),
                ),
                GestureDetector(
                  onTap: () => context.pop(),
                  child: Text(
                    l10n.login,
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w800,
                      color: AppColors.accent,
                    ),
                  ),
                ),
              ],
            ),

            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }

  Widget _buildInputLabel(String label) {
    return Text(
      label.toUpperCase(),
      style: TextStyle(
        fontSize: 11,
        fontWeight: FontWeight.w800,
        color: AppColors.hint(context),
        letterSpacing: 1.2,
      ),
    );
  }

  Widget _buildAccentButton({
    required String label,
    required bool isLoading,
    required VoidCallback onPressed,
  }) {
    return GestureDetector(
      onTap: isLoading ? null : onPressed,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        width: double.infinity,
        height: 56,
        decoration: BoxDecoration(
          gradient: AppColors.accentGradient,
          borderRadius: BorderRadius.circular(14),
          boxShadow: [
            BoxShadow(
              color: AppColors.accent.withOpacity(0.35),
              blurRadius: 20,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        child: Center(
          child: isLoading
              ? const SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(
                    strokeWidth: 2.5,
                    valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                  ),
                )
              : Text(
                  label,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w800,
                    color: Colors.white,
                    letterSpacing: 0.5,
                  ),
                ),
        ),
      ),
    );
  }

  Widget _buildOrDivider(AppL10n l10n) {
    return Row(
      children: [
        Expanded(
          child: Container(
            height: 1,
            color: AppColors.borderColor(context),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 18),
          child: Text(
            l10n.orContinueWith,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: AppColors.hint(context).withOpacity(0.8),
            ),
          ),
        ),
        Expanded(
          child: Container(
            height: 1,
            color: AppColors.borderColor(context),
          ),
        ),
      ],
    );
  }

  Widget _buildSocialButton({
    required String label,
    required IconData icon,
    required VoidCallback onPressed,
  }) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(14),
        child: Container(
          height: 54,
          decoration: BoxDecoration(
            color: AppColors.surfaceColor(context),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: AppColors.borderColor(context), width: 2),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 24, color: AppColors.onSurface(context)),
              const SizedBox(width: 10),
              Text(
                label,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  color: AppColors.onSurface(context),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

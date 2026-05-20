import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:uuid/uuid.dart';

import '../../config/app_config.dart';
import '../../core/l10n/app_l10n.dart';
import '../../core/theme/app_colors.dart';
import '../../models/user_account.dart';
import '../../providers/auth_provider.dart';
import '../../providers/contacts_provider.dart';
import '../../providers/currency_provider.dart';
import '../../providers/organization_provider.dart';
import '../../providers/reminders_provider.dart';
import '../../providers/settings_provider.dart';
import '../../services/database_service.dart';
import '../../services/revenue_cat_service.dart';
import '../../services/storage_service.dart';
import '../../services/stripe_service.dart';
import '../../services/subscription_service.dart';

class PricingScreen extends ConsumerStatefulWidget {
  const PricingScreen({super.key});

  @override
  ConsumerState<PricingScreen> createState() => _PricingScreenState();
}

class _PricingScreenState extends ConsumerState<PricingScreen>
    with WidgetsBindingObserver {
  String? _loadingPlan;
  String? _selectedPlan;
  bool _recoveringPayment = false;
  static const _uuid = Uuid();

  bool get _stripeReady => AppConfig.stripePublishableKey.isNotEmpty;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance
        .addPostFrameCallback((_) => _recoverPendingPayment());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _recoverPendingPayment();
    }
  }

  Future<void> _recoverPendingPayment() async {
    if (_recoveringPayment || _loadingPlan != null) return;
    _recoveringPayment = true;
    try {
      final recovery = StripeService.consumeStartupRecovery() ??
          await StripeService.checkPendingPayment();
      if (!mounted || recovery == null || !recovery.result.success) return;

      final l10n = ref.read(l10nProvider);
      final amount = _priceAmount(recovery.plan, recovery.billingCycle);
      final piId = recovery.result.paymentIntentId ?? '';
      final record = PaymentRecord(
        id: piId.isNotEmpty ? piId : _uuid.v4(),
        transactionId: PaymentRecord.generateId(),
        userId: StorageService.currentUserId,
        plan: recovery.plan,
        billingCycle: recovery.billingCycle,
        amount: amount,
        currency: 'EUR',
        status: 'succeeded',
        stripePaymentIntentId: piId,
        accountType: 'individual',
        createdAt: DateTime.now().toIso8601String(),
      );
      await DatabaseService.insertPaymentRecord(record);
      await ref
          .read(authProvider.notifier)
          .changePlan(recovery.plan, billingCycle: recovery.billingCycle);
      if (mounted) _showSnack(l10n.paymentSuccess, AppColors.success);
    } finally {
      _recoveringPayment = false;
    }
  }

  double _priceAmount(String planId, [String? cycle]) {
    final c = cycle ?? 'monthly';
    if (planId == 'premium') return c == 'yearly' ? 35.88 : 2.99;
    if (planId == 'business') return c == 'yearly' ? 71.88 : 5.99;
    return 0;
  }

  void _showSnack(String msg, Color color) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), backgroundColor: color),
    );
  }

  int _planLevel(String plan) {
    switch (plan) {
      case 'free':
        return 0;
      case 'premium':
        return 1;
      case 'business':
        return 2;
      default:
        return 0;
    }
  }

  Future<void> _selectPlan(String planId) async {
    final l10n = ref.read(l10nProvider);
    final authState = ref.read(authProvider);
    final currentPlan = authState.plan;
    final planExpiresAt = authState.planExpiresAt;

    // Pour ces tuiles de prix rapides (2.99€ / 5.99€), on utilise le cycle mensuel par défaut
    // sauf si l'utilisateur a déjà un cycle annuel en cours qu'il souhaite renouveler.
    // final billingCycle = authState.subscriptionBillingCycle ?? 'monthly';
    const billingCycle = 'yearly';
    final isInRenewalWindow =
        SubscriptionService.isInRenewalWindow(planExpiresAt, billingCycle);

    // Si on clique sur le plan actuel :
    // - Si on est en période de renouvellement, on laisse passer pour repayer.
    // - Sinon, on s'arrête là car le plan est déjà actif.
    if (currentPlan == planId && !isInRenewalWindow) {
      _showSnack(l10n.currentBadge, AppColors.success);
      return;
    }

    // Check if user is in an organization
    final orgState = ref.read(organizationProvider);
    if (orgState.organization != null) {
      _showSnack(l10n.planChangeDisabledInOrg, AppColors.warning);
      return;
    }

    // Downgrade check
    if (_planLevel(planId) < _planLevel(currentPlan)) {
      final isInRenewalWindow =
          SubscriptionService.isInRenewalWindow(planExpiresAt, billingCycle);
      if (!isInRenewalWindow) {
        _showSnack(l10n.downgradeNotAllowedGeneric, AppColors.warning);
        return;
      }
    }

    if (Platform.isAndroid && !_stripeReady) {
      _showSnack('Stripe not configured', AppColors.warning);
      return;
    }
    setState(() {
      _selectedPlan = planId;
      _loadingPlan = planId;
    });

    bool success = false;
    String? transactionId;
    String? errorCode;

    if (Platform.isIOS) {
      // Use RevenueCat on iOS for App Store compliance.
      final rcResult = await RevenueCatService.purchasePlan(planId, billingCycle);
      success = rcResult.success;
      transactionId = rcResult.customerId;
      errorCode = rcResult.errorCode;
    } else {
      // Use Stripe on Android.
      final result = await StripeService.startCheckout(
        plan: planId,
        billingCycle: billingCycle,
        userEmail: authState.userEmail,
      );
      success = result.success;
      transactionId = result.paymentIntentId;
      errorCode = result.errorCode;
    }

    if (!mounted) return;
    setState(() => _loadingPlan = null);

    if (success) {
      final amount = _priceAmount(planId, billingCycle);
      final record = PaymentRecord(
        id: _uuid.v4(),
        transactionId: PaymentRecord.generateId(),
        userId: StorageService.currentUserId,
        plan: planId,
        billingCycle: billingCycle,
        amount: amount,
        currency: 'EUR',
        status: 'succeeded',
        stripePaymentIntentId: transactionId ?? '',
        accountType: 'individual',
        createdAt: DateTime.now().toIso8601String(),
      );
      await DatabaseService.insertPaymentRecord(record);
      await ref
          .read(authProvider.notifier)
          .changePlan(planId, billingCycle: billingCycle);
      if (mounted) _showSnack(l10n.paymentSuccess, AppColors.success);
    } else {
      final msg = errorCode == 'cancelled'
          ? l10n.paymentCancelled
          : l10n.paymentFailed;
      _showSnack(msg, AppColors.error);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = ref.watch(l10nProvider);
    final currency = ref.watch(settingsProvider).currency;
    final eurToUsd = ref.watch(eurToUsdRateProvider);
    final authState = ref.watch(authProvider);
    final plan = authState.plan;
    final planExpiresAt = authState.planExpiresAt;
    final billingCycle = authState.subscriptionBillingCycle;

    final planName = switch (plan) {
      'premium' => l10n.premiumPlanName,
      'business' => l10n.businessPlanName,
      _ => l10n.freePlanName,
    };
    final planTagline = switch (plan) {
      'premium' => l10n.premiumPlanDesc,
      'business' => l10n.businessPlanDesc,
      _ => l10n.freePlanTagline,
    };
    final isPaid = plan == 'premium' || plan == 'business';

    return Scaffold(
      backgroundColor: AppColors.bg(context),
      body: Column(
        children: [
          // Header
          Container(
            width: double.infinity,
            padding: EdgeInsets.only(
              top: MediaQuery.of(context).padding.top + 10,
              left: 24,
              right: 24,
              bottom: 28,
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
                GestureDetector(
                  onTap: () => context.pop(),
                  child: Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: Colors.white.withOpacity(0.12),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Icon(Icons.arrow_back_rounded,
                        color: Colors.white, size: 20),
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  l10n.subscriptionHubTitle,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 22,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  l10n.subscriptionHubSubtitle,
                  style: TextStyle(
                    color: Colors.white.withOpacity(0.5),
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),

          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: Column(
                children: [
                  // Current plan banner
                  Container(
                    padding: const EdgeInsets.all(20),
                    decoration: BoxDecoration(
                      gradient: AppColors.primaryGradient,
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Row(
                      children: [
                        Container(
                          width: 48,
                          height: 48,
                          decoration: BoxDecoration(
                            color: Colors.white.withOpacity(0.12),
                            borderRadius: BorderRadius.circular(14),
                          ),
                          child: const Icon(Icons.star_rounded,
                              color: AppColors.accent, size: 24),
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                l10n.currentPlanBadge,
                                style: TextStyle(
                                  fontSize: 10,
                                  fontWeight: FontWeight.w700,
                                  color: Colors.white.withOpacity(0.5),
                                  letterSpacing: 1,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                planName,
                                style: const TextStyle(
                                  fontSize: 18,
                                  fontWeight: FontWeight.w800,
                                  color: Colors.white,
                                ),
                              ),
                              Text(
                                planTagline,
                                style: TextStyle(
                                  fontSize: 12,
                                  color: Colors.white.withOpacity(0.5),
                                ),
                              ),
                              if (planExpiresAt != null && isPaid) ...[
                                const SizedBox(height: 4),
                                Builder(builder: (ctx) {
                                  final d = planExpiresAt;
                                  final formatted =
                                      '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year}';
                                  final isExpiring =
                                      SubscriptionService.isInRenewalWindow(
                                          planExpiresAt, billingCycle);
                                  return Row(
                                    children: [
                                      Icon(
                                        Icons.calendar_today_rounded,
                                        size: 11,
                                        color: isExpiring
                                            ? AppColors.warning
                                            : Colors.white.withOpacity(0.5),
                                      ),
                                      const SizedBox(width: 4),
                                      Flexible(
                                        child: Text(
                                          l10n.subscriptionExpiresOn2(
                                              formatted),
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                            fontSize: 11,
                                            fontWeight: FontWeight.w600,
                                            color: isExpiring
                                                ? AppColors.warning
                                                : Colors.white.withOpacity(0.5),
                                          ),
                                        ),
                                      ),
                                    ],
                                  );
                                }),
                              ],
                            ],
                          ),
                        ),
                        Expanded(
                          child: GestureDetector(
                            onTap: () => context.push('/subscription-plan'),
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 14, vertical: 8),
                              decoration: BoxDecoration(
                                color: isPaid
                                    ? Colors.white.withValues(alpha: 0.15)
                                    : AppColors.accent,
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: Text(
                                isPaid ? l10n.managePlan : l10n.upgradeNow,
                                style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w700,
                                  color:
                                      isPaid ? Colors.white : AppColors.primary,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(height: 20),

                  // Navigation cards
                  _NavCard(
                    icon: Icons.workspace_premium_rounded,
                    iconColor: AppColors.accent,
                    title: l10n.subscriptionPlanOption,
                    subtitle: l10n.subscriptionPlanOptionDesc,
                    onTap: () => context.push('/subscription-plan'),
                  ),
                  const SizedBox(height: 12),
                  _NavCard(
                    icon: Icons.receipt_long_rounded,
                    iconColor: AppColors.info,
                    title: l10n.paymentHistoryOption,
                    subtitle: l10n.paymentHistoryOptionDesc,
                    onTap: () => context.push('/payment-history'),
                  ),

                  const SizedBox(height: 24),

                  // Pricing preview
                  Container(
                    padding: const EdgeInsets.all(20),
                    decoration: BoxDecoration(
                      color: AppColors.surfaceColor(context),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: AppColors.borderColor(context)),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          l10n.subscriptionPlanOption.toUpperCase(),
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                            color: AppColors.hint(context),
                            letterSpacing: 1,
                          ),
                        ),
                        const SizedBox(height: 14),
                        Row(
                          children: [
                            _MiniPlanTile(
                              name: l10n.premiumPlanName,
                              price: l10n.premiumPrice(currency,
                                  eurToTargetRate: eurToUsd),
                              period: l10n.premiumYearPeriod(l10n),
                              highlight: true,
                              isSelected: _selectedPlan == 'premium' ||
                                  (plan == 'premium' && _selectedPlan == null),
                              isLoading: _loadingPlan == 'premium',
                              onTap: () => _selectPlan('premium'),
                            ),
                            const SizedBox(width: 10),
                            _MiniPlanTile(
                              name: l10n.businessPlanName,
                              price: l10n.businessPrice(currency,
                                  eurToTargetRate: eurToUsd),
                              period: l10n.businessYearPeriod(l10n),
                              highlight: false,
                              isSelected: _selectedPlan == 'business' ||
                                  (plan == 'business' && _selectedPlan == null),
                              isLoading: _loadingPlan == 'business',
                              onTap: () => _selectPlan('business'),
                            ),
                          ],
                        ),
                        const SizedBox(height: 14),
                        Row(
                          children: [
                            const Icon(Icons.lock_rounded,
                                size: 14, color: AppColors.success),
                            const SizedBox(width: 6),
                            Expanded(
                              child: Text(
                                l10n.secureTransactions,
                                style: TextStyle(
                                  fontSize: 11,
                                  color: AppColors.secondary(context),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 40),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Navigation card ─────────────────────────────────────────────────────────

class _NavCard extends StatelessWidget {
  final IconData icon;
  final Color iconColor;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  const _NavCard({
    required this.icon,
    required this.iconColor,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.surfaceColor(context),
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Container(
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: AppColors.borderColor(context)),
          ),
          child: Row(
            children: [
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: iconColor.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Icon(icon, color: iconColor, size: 22),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        color: AppColors.onSurface(context),
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
                  color: AppColors.hint(context), size: 22),
            ],
          ),
        ),
      ),
    );
  }
}

// ─── Mini plan tile ───────────────────────────────────────────────────────────

class _MiniPlanTile extends StatelessWidget {
  final String name;
  final String price;
  final String period;
  final bool highlight;
  final bool isSelected;
  final bool isLoading;
  final VoidCallback onTap;

  const _MiniPlanTile({
    required this.name,
    required this.price,
    required this.period,
    required this.highlight,
    this.isSelected = false,
    this.isLoading = false,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: GestureDetector(
        onTap: isLoading ? null : onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: isSelected
                ? AppColors.primary.withOpacity(0.08)
                : (highlight
                    ? AppColors.primary.withOpacity(0.06)
                    : AppColors.bg(context)),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: isSelected
                  ? AppColors.accent
                  : (highlight
                      ? AppColors.primary.withOpacity(0.2)
                      : AppColors.borderColor(context)),
              width: isSelected ? 2 : 1,
            ),
          ),
          child: Stack(
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    name,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: AppColors.onSurface(context),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    price,
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w800,
                      color: AppColors.primary,
                    ),
                  ),
                  Text(
                    period,
                    style: TextStyle(
                      fontSize: 10,
                      color: AppColors.secondary(context),
                    ),
                  ),
                ],
              ),
              if (isLoading)
                const Positioned(
                  top: 0,
                  right: 0,
                  child: SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: AppColors.primary,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

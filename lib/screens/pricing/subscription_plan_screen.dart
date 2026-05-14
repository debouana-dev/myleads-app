import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
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
import '../../services/storage_service.dart';
import '../../services/stripe_service.dart';
import '../../services/subscription_service.dart';

class SubscriptionPlanScreen extends ConsumerStatefulWidget {
  const SubscriptionPlanScreen({super.key});

  @override
  ConsumerState<SubscriptionPlanScreen> createState() =>
      _SubscriptionPlanScreenState();
}

class _SubscriptionPlanScreenState extends ConsumerState<SubscriptionPlanScreen>
    with WidgetsBindingObserver {
  String? _loadingPlan;
  String _billingCycle = 'yearly'; // 'monthly' | 'yearly'
  bool _recoveringPayment = false;

  static const _uuid = Uuid();

  bool get _stripeReady => AppConfig.stripePublishableKey.isNotEmpty;

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

  DateTime? _renewalWindowStart(DateTime? planExpiresAt, String? billingCycle) {
    if (planExpiresAt == null) return null;
    final windowDays = billingCycle == 'yearly'
        ? SubscriptionService.yearlyRenewalWindowDays
        : SubscriptionService.monthlyRenewalWindowDays;
    return planExpiresAt.subtract(Duration(days: windowDays));
  }

  @override
  void initState() {
    super.initState();
    // Default to the user's current billing cycle so the toggle matches
    // what they last paid for (convenient for renewal).
    final savedCycle = StorageService.currentUser?.subscriptionBillingCycle;
    if (savedCycle != null) _billingCycle = savedCycle;
    WidgetsBinding.instance.addObserver(this);
    // Check for a payment that completed while the app was backgrounded
    // during a previous Link/redirect session (e.g. cold-start recovery).
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
      // Fired when the user returns from the external browser after a Link
      // payment. presentPaymentSheet() may have been dismissed already; this
      // is the safety-net that checks the real outcome server-side.
      _recoverPendingPayment();
    }
  }

  Future<void> _recoverPendingPayment() async {
    // Skip while _selectPlan() is running to avoid a duplicate payment_history
    // row for the same Stripe payment intent.
    if (_recoveringPayment || _loadingPlan != null) return;
    _recoveringPayment = true;
    try {
      // Cold-start path: main.dart called checkAtStartup() and cached the result
      // before the Riverpod tree was built. Consume that result first (no extra
      // network call). Falls back to a live check for the warm-resume path where
      // the process survived but the PaymentSheet was dismissed mid-redirect.
      final recovery = StripeService.consumeStartupRecovery() ??
          await StripeService.checkPendingPayment();
      if (!mounted || recovery == null || !recovery.result.success) return;

      final l10n = ref.read(l10nProvider);
      final amount = _priceAmount(recovery.plan, recovery.billingCycle);
      // Use the paymentIntentId as the record primary key so that
      // ConflictAlgorithm.ignore in insertPaymentRecord silently skips a
      // duplicate when main.dart already inserted the same record on cold-start.
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

  Future<void> _selectPlan(String planId) async {
    final l10n = ref.read(l10nProvider);
    final authState = ref.read(authProvider);
    final currentPlan = authState.plan;
    final planExpiresAt = authState.planExpiresAt;
    final billingCycle = authState.subscriptionBillingCycle;
    final isInRenewalWindow = currentPlan != 'free' &&
        SubscriptionService.isInRenewalWindow(planExpiresAt, billingCycle);

    // Check if user is in an organization
    final orgState = ref.read(organizationProvider);
    if (orgState.organization != null) {
      _showSnack(l10n.planChangeDisabledInOrg, AppColors.warning);
      return;
    }

    // Check if downgrade and not in renewal window
    if (_planLevel(planId) < _planLevel(currentPlan) && planId != 'free') {
      if (!isInRenewalWindow) {
        final renewalStart = _renewalWindowStart(planExpiresAt, billingCycle);
        if (renewalStart != null) {
          final formattedDate =
              '${renewalStart.day.toString().padLeft(2, '0')}/${renewalStart.month.toString().padLeft(2, '0')}/${renewalStart.year}';
          _showSnack(
              l10n.downgradeNotAllowed(formattedDate), AppColors.warning);
        } else {
          _showSnack(l10n.downgradeNotAllowedGeneric, AppColors.warning);
        }
        return;
      }
    }

    // Confirmation for switching to free (cancellation)
    if (planId == 'free' && currentPlan != 'free') {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(l10n.cancelSubscriptionTitle),
          content: Text(l10n.cancelSubscriptionMessage),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: Text(l10n.cancelAction),
            ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: Text(l10n.confirm),
            ),
          ],
        ),
      );
      if (confirmed != true) return;
    }

    // Free plan — no payment required.
    if (planId == 'free') {
      setState(() => _loadingPlan = planId);
      final err = await ref.read(authProvider.notifier).changePlan(planId);
      if (!mounted) return;
      setState(() => _loadingPlan = null);
      if (err == null) {
        await ref.read(contactsProvider.notifier).reload();
        await ref.read(remindersProvider.notifier).reload();
        await ref.read(organizationProvider.notifier).loadForCurrentUser();
      }
      _showSnack(err == null ? l10n.planChangedSuccess : l10n.planChangeError,
          err == null ? AppColors.success : AppColors.error);
      return;
    }

    // Paid plan — Stripe PaymentSheet.
    if (!_stripeReady) {
      _showSnack(
          'Stripe not configured (set stripePublishableKey in AppConfig)',
          AppColors.warning);
      return;
    }

    final currentUser = ref.read(authProvider);
    setState(() => _loadingPlan = planId);

    final result = await StripeService.startCheckout(
      plan: planId,
      billingCycle: _billingCycle,
      userEmail: currentUser.userEmail,
    );

    if (!mounted) return;
    setState(() => _loadingPlan = null);

    if (result.success) {
      // Persist payment record locally (live-write fires PostgreSQL upsert).
      final amount = _priceAmount(planId);
      final record = PaymentRecord(
        id: _uuid.v4(),
        transactionId: PaymentRecord.generateId(),
        userId: StorageService.currentUserId,
        plan: planId,
        billingCycle: _billingCycle,
        amount: amount,
        currency: 'EUR',
        status: 'succeeded',
        stripePaymentIntentId: result.paymentIntentId ?? '',
        accountType: 'individual',
        createdAt: DateTime.now().toIso8601String(),
      );
      await DatabaseService.insertPaymentRecord(record);

      // Update subscription plan in DB + state (sets expiry + schedules notifs).
      await ref
          .read(authProvider.notifier)
          .changePlan(planId, billingCycle: _billingCycle);

      if (mounted) _showSnack(l10n.paymentSuccess, AppColors.success);
    } else {
      final msg = result.errorCode == 'cancelled'
          ? l10n.paymentCancelled
          : l10n.paymentFailed;
      _showSnack(msg, AppColors.error);
    }
  }

  double _priceAmount(String planId, [String? cycle]) {
    final c = cycle ?? _billingCycle;
    if (planId == 'premium') return c == 'yearly' ? 35.88 : 3.59;
    if (planId == 'business') return c == 'yearly' ? 71.88 : 7.19;
    return 0;
  }

  void _showSnack(String msg, Color color) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        backgroundColor: color,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = ref.watch(l10nProvider);
    final currency = ref.watch(settingsProvider).currency;
    final eurToUsd = ref.watch(eurToUsdRateProvider);
    final authState = ref.watch(authProvider);
    final effectivePlan = ref.watch(effectivePlanProvider).maybeWhen(
          data: (plan) => plan,
          orElse: () => authState.plan,
        );
    final orgState = ref.watch(organizationProvider);
    final currentPlan = effectivePlan;
    final planExpiresAt = authState.planExpiresAt;
    final billingCycle = authState.subscriptionBillingCycle;
    final isYearly = _billingCycle == 'yearly';

    // Renewal window: 5 days for monthly, 7 days for yearly.
    final isInRenewalWindow = currentPlan != 'free' &&
        SubscriptionService.isInRenewalWindow(planExpiresAt, billingCycle);

    // Check if user is in an organization
    final isInOrganization = orgState.organization != null;

    // Format expiry date for display.
    String? expiryText;
    if (planExpiresAt != null && currentPlan != 'free') {
      final d = planExpiresAt;
      final formatted =
          '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year}';
      expiryText = l10n.subscriptionExpiresOn(formatted);
    }

    return Scaffold(
      backgroundColor: AppColors.bg(context),
      body: Column(
        children: [
          // Header
          Container(
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
                  onTap: () => Navigator.of(context).pop(),
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
                  l10n.choosePlan,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 22,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  l10n.pitchShort,
                  style: TextStyle(
                    color: Colors.white.withOpacity(0.5),
                    fontSize: 12,
                    height: 1.5,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),

          // Plans list
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: Column(
                children: [
                  // Billing cycle toggle
                  _BillingToggle(
                    cycle: _billingCycle,
                    yearlySavingsLabel: l10n.yearlySavings,
                    monthlyLabel: l10n.billingCycleMonthly,
                    yearlyLabel: l10n.billingCycleYearly,
                    onChanged: (c) => setState(() => _billingCycle = c),
                  ),
                  const SizedBox(height: 20),

                  // Free
                  _PlanCard(
                    title: l10n.freePlanName,
                    price: l10n.freeLabel,
                    description: l10n.freePlanDesc,
                    features: _freeFeatures(l10n),
                    isPopular: false,
                    isCurrent: currentPlan == 'free',
                    isLoading: _loadingPlan == 'free',
                    onSelect: (currentPlan == 'free' || isInOrganization)
                        ? null
                        : () => _selectPlan('free'),
                    l10n: l10n,
                  ),
                  const SizedBox(height: 16),

                  // Premium
                  _PlanCard(
                    title: l10n.premiumPlanName,
                    price: isYearly
                        ? l10n.premiumYearlyPrice(currency,
                            eurToTargetRate: eurToUsd)
                        : l10n.subPremiumPrice(currency,
                            eurToTargetRate: eurToUsd),
                    period: isYearly
                        ? l10n.premiumYearlyPeriod(l10n)
                        : l10n.premiumPeriod(l10n),
                    description: l10n.premiumPlanDesc,
                    features: _premiumFeatures(l10n),
                    isPopular: true,
                    isCurrent: currentPlan == 'premium',
                    isRenewable: currentPlan == 'premium' && isInRenewalWindow,
                    expiryText: currentPlan == 'premium' ? expiryText : null,
                    isLoading: _loadingPlan == 'premium',
                    onSelect:
                        isInOrganization ? null : () => _selectPlan('premium'),
                    renewLabel: l10n.renewAction,
                    l10n: l10n,
                  ),
                  const SizedBox(height: 16),

                  // Business
                  _PlanCard(
                    title: l10n.businessPlanName,
                    price: isYearly
                        ? l10n.businessYearlyPrice(currency,
                            eurToTargetRate: eurToUsd)
                        : l10n.subBusinessPrice(currency,
                            eurToTargetRate: eurToUsd),
                    period: isYearly
                        ? l10n.businessYearlyPeriod(l10n)
                        : l10n.businessPeriod(l10n),
                    description: l10n.businessPlanDesc,
                    features: _businessFeatures(l10n),
                    isPopular: false,
                    isCurrent: currentPlan == 'business',
                    isRenewable: currentPlan == 'business' && isInRenewalWindow,
                    expiryText: currentPlan == 'business' ? expiryText : null,
                    isLoading: _loadingPlan == 'business',
                    onSelect:
                        isInOrganization ? null : () => _selectPlan('business'),
                    renewLabel: l10n.renewAction,
                    l10n: l10n,
                  ),

                  const SizedBox(height: 24),

                  // Payment methods
                  // Container(
                  //   padding: const EdgeInsets.all(20),
                  //   decoration: BoxDecoration(
                  //     color: AppColors.surfaceColor(context),
                  //     borderRadius: BorderRadius.circular(16),
                  //     border: Border.all(color: AppColors.borderColor(context)),
                  //   ),
                  //   child: Column(
                  //     crossAxisAlignment: CrossAxisAlignment.start,
                  //     children: [
                  //       Text(
                  //         l10n.paymentMethodsTitle,
                  //         style: TextStyle(
                  //           fontSize: 11,
                  //           fontWeight: FontWeight.w700,
                  //           color: AppColors.hint(context),
                  //           letterSpacing: 1,
                  //         ),
                  //       ),
                  //       const SizedBox(height: 12),
                  //       Wrap(
                  //         spacing: 8,
                  //         runSpacing: 8,
                  //         children: [
                  //           _paymentChip(context, l10n.bankCard),
                  //           _paymentChip(context, 'PayPal'),
                  //           _paymentChip(context, 'Apple Pay'),
                  //           _paymentChip(context, 'Google Pay'),
                  //           _paymentChip(context, 'Amazon Pay'),
                  //         ],
                  //       ),
                  //       const SizedBox(height: 12),
                  //       Text(
                  //         l10n.securePayment,
                  //         style: TextStyle(
                  //           fontSize: 11,
                  //           color: AppColors.hint(context),
                  //         ),
                  //       ),
                  //     ],
                  //   ),
                  // ),
                  // const SizedBox(height: 40),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  List<String> _freeFeatures(AppL10n l10n) => l10n.isEnglish
      ? [
          '10 contacts max',
          'Business card scan',
          'Hot · Warm · Cold tags',
          'Encrypted local storage',
        ]
      : [
          '10 contacts max',
          'Scan carte de visite',
          'Tags: Hot · Warm · Cold',
          'Stockage local chiffré',
        ];

  List<String> _premiumFeatures(AppL10n l10n) => l10n.isEnglish
      ? [
          'Unlimited contacts',
          'OCR + QR scan',
          'CSV / CRM export',
          'Cloud sync',
          'Priority support',
        ]
      : [
          'Contacts illimités',
          'Scan OCR + QR',
          'Export CSV / CRM',
          'Synchronisation cloud',
          'Support prioritaire',
        ];

  List<String> _businessFeatures(AppL10n l10n) => l10n.isEnglish
      ? [
          'All Premium included',
          'Multi-user management',
          'Shared team space',
          'Analytics & reports',
          'AI lead scoring',
          'Auto cloud sync',
          'Dedicated onboarding',
        ]
      : [
          'Tout Premium inclus',
          'Gestion multi-utilisateurs',
          'Espace équipe partagé',
          'Analytics & rapports',
          'Notation des leads par l\'IA',
          'Synchronisation cloud automatique',
          'Onboarding dédié',
        ];

  Widget _paymentChip(BuildContext context, String label) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: AppColors.primary.withOpacity(0.06),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        label,
        style: const TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: AppColors.primary,
        ),
      ),
    );
  }
}

// ─── Billing cycle toggle ─────────────────────────────────────────────────────

class _BillingToggle extends StatelessWidget {
  final String cycle;
  final String monthlyLabel;
  final String yearlyLabel;
  final String yearlySavingsLabel;
  final ValueChanged<String> onChanged;

  const _BillingToggle({
    required this.cycle,
    required this.monthlyLabel,
    required this.yearlyLabel,
    required this.yearlySavingsLabel,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: AppColors.surfaceColor(context),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.borderColor(context)),
      ),
      child: Row(
        children: [
          _tab(context, 'monthly', monthlyLabel),
          _tab(context, 'yearly', yearlyLabel, badge: yearlySavingsLabel),
        ],
      ),
    );
  }

  Widget _tab(BuildContext context, String value, String label,
      {String? badge}) {
    final selected = cycle == value;
    return Expanded(
      child: GestureDetector(
        onTap: () => onChanged(value),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          padding: const EdgeInsets.symmetric(vertical: 10),
          decoration: BoxDecoration(
            gradient: selected ? AppColors.primaryGradient : null,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                label,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: selected ? Colors.white : AppColors.secondary(context),
                ),
              ),
              if (badge != null) ...[
                const SizedBox(width: 6),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: selected
                        ? Colors.white.withOpacity(0.2)
                        : AppColors.success.withOpacity(0.12),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    badge,
                    style: TextStyle(
                      fontSize: 9,
                      fontWeight: FontWeight.w800,
                      color: selected ? Colors.white : AppColors.success,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

// ─── Plan card ────────────────────────────────────────────────────────────────

class _PlanCard extends StatelessWidget {
  final String title;
  final String price;
  final String? period;
  final String description;
  final List<String> features;
  final bool isPopular;
  final bool isCurrent;
  final bool isRenewable;
  final String? expiryText;
  final String? renewLabel;
  final bool isLoading;
  final VoidCallback? onSelect;
  final AppL10n l10n;

  const _PlanCard({
    required this.title,
    required this.price,
    required this.description,
    required this.features,
    required this.isPopular,
    required this.l10n,
    this.period,
    this.isCurrent = false,
    this.isRenewable = false,
    this.expiryText,
    this.renewLabel,
    this.isLoading = false,
    this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: isPopular ? AppColors.primary : AppColors.surfaceColor(context),
        borderRadius: BorderRadius.circular(20),
        border: isPopular
            ? Border.all(color: AppColors.accent, width: 2)
            : Border.all(color: AppColors.borderColor(context)),
        boxShadow: [
          BoxShadow(
            color: isPopular
                ? AppColors.accent.withOpacity(0.2)
                : AppColors.primary.withOpacity(0.06),
            blurRadius: isPopular ? 30 : 20,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Title row
          Row(
            children: [
              Text(
                title,
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w800,
                  color:
                      isPopular ? Colors.white : AppColors.onSurface(context),
                ),
              ),
              if (isPopular) ...[
                const SizedBox(width: 10),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: AppColors.accent,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    l10n.popularBadge,
                    style: const TextStyle(
                      fontSize: 9,
                      fontWeight: FontWeight.w800,
                      color: AppColors.primary,
                      letterSpacing: 0.5,
                    ),
                  ),
                ),
              ],
              if (isCurrent) ...[
                const SizedBox(width: 10),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: AppColors.success.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    l10n.currentBadge,
                    style: const TextStyle(
                      fontSize: 9,
                      fontWeight: FontWeight.w800,
                      color: AppColors.success,
                      letterSpacing: 0.5,
                    ),
                  ),
                ),
              ],
              if (isRenewable) ...[
                const SizedBox(width: 10),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: AppColors.warning.withOpacity(0.15),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    l10n.expiringBadge,
                    style: TextStyle(
                      fontSize: 9,
                      fontWeight: FontWeight.w800,
                      color: AppColors.warning,
                      letterSpacing: 0.5,
                    ),
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 8),

          // Price
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                price,
                style: TextStyle(
                  fontSize: 32,
                  fontWeight: FontWeight.w800,
                  color: isPopular ? AppColors.accent : AppColors.primary,
                ),
              ),
              if (period != null) ...[
                const SizedBox(width: 4),
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Text(
                    period!,
                    style: TextStyle(
                      fontSize: 13,
                      color: isPopular
                          ? Colors.white.withOpacity(0.5)
                          : AppColors.secondary(context),
                    ),
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 4),

          Text(
            description,
            style: TextStyle(
              fontSize: 13,
              color: isPopular
                  ? Colors.white.withOpacity(0.5)
                  : AppColors.secondary(context),
            ),
          ),
          if (expiryText != null) ...[
            const SizedBox(height: 6),
            Row(
              children: [
                Icon(
                  Icons.calendar_today_rounded,
                  size: 13,
                  color: isRenewable
                      ? AppColors.warning
                      : (isPopular
                          ? Colors.white.withOpacity(0.6)
                          : AppColors.hint(context)),
                ),
                const SizedBox(width: 5),
                Text(
                  expiryText!,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: isRenewable
                        ? AppColors.warning
                        : (isPopular
                            ? Colors.white.withOpacity(0.6)
                            : AppColors.hint(context)),
                  ),
                ),
              ],
            ),
          ],
          const SizedBox(height: 16),

          // Features
          ...features.map((f) => Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(
                  children: [
                    Icon(
                      Icons.check_circle_rounded,
                      size: 18,
                      color: isPopular ? AppColors.accent : AppColors.success,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        f,
                        style: TextStyle(
                          fontSize: 13,
                          color: isPopular
                              ? Colors.white
                              : AppColors.onSurface(context),
                        ),
                      ),
                    ),
                  ],
                ),
              )),

          if (!isCurrent || isRenewable) ...[
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              height: 50,
              child: ElevatedButton(
                onPressed: isLoading ? null : onSelect,
                style: ElevatedButton.styleFrom(
                  backgroundColor: isRenewable
                      ? AppColors.warning
                      : (isPopular ? AppColors.accent : AppColors.primary),
                  foregroundColor: isRenewable
                      ? Colors.white
                      : (isPopular ? AppColors.primary : Colors.white),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                child: isLoading
                    ? SizedBox(
                        width: 22,
                        height: 22,
                        child: CircularProgressIndicator(
                          strokeWidth: 2.5,
                          color: isRenewable
                              ? Colors.white
                              : (isPopular ? AppColors.primary : Colors.white),
                        ),
                      )
                    : Text(
                        isRenewable
                            ? (renewLabel ?? l10n.renewAction)
                            : '${l10n.choosePlanCta} $title',
                        style: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

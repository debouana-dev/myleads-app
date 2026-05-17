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
import '../../providers/organization_provider.dart';
import '../../services/database_service.dart';
import '../../services/revenue_cat_service.dart';
import '../../services/storage_service.dart';
import '../../services/stripe_service.dart';

const _uuid = Uuid();

// Unit prices in EUR per license (matches StripeService price map).
const _unitMonthly = 7.19;
const _unitYearly = 71.88;

class CreateOrganizationScreen extends ConsumerStatefulWidget {
  const CreateOrganizationScreen({super.key});

  @override
  ConsumerState<CreateOrganizationScreen> createState() =>
      _CreateOrganizationScreenState();
}

class _CreateOrganizationScreenState
    extends ConsumerState<CreateOrganizationScreen> {
  final _formKey = GlobalKey<FormState>();
  final _nameCtrl = TextEditingController();
  bool _loading = false;
  String _billingCycle = 'monthly'; // 'monthly' | 'yearly'
  int _licenseCount = 1; // minimum 1 (admin counts as 1)

  bool get _stripeReady => AppConfig.stripePublishableKey.isNotEmpty;

  int get _paidLicenseCount => _licenseCount > 1 ? _licenseCount - 1 : 0;

  double get _unitPrice =>
      _billingCycle == 'yearly' ? _unitYearly : _unitMonthly;

  double get _totalPrice => _unitPrice * _paidLicenseCount;

  String _formatPrice(double amount) =>
      '${amount.toStringAsFixed(2).replaceAll('.', ',')} €';

  @override
  void dispose() {
    _nameCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;

    final paidLicenseCount = _paidLicenseCount;
    if (paidLicenseCount > 0 && Platform.isAndroid && !_stripeReady) {
      _showSnack('Stripe not configured', AppColors.warning);
      return;
    }

    setState(() => _loading = true);

    if (paidLicenseCount > 0) {
      final authState = ref.read(authProvider);
      bool success = false;
      String? transactionId;
      String? errorCode;

      if (Platform.isIOS) {
        // Use RevenueCat on iOS. Note: For multi-license, custom packages should be set up in RC.
        // Here we assume 'business_monthly' or 'business_yearly' corresponds to the base org plan.
        final rcResult = await RevenueCatService.purchasePlan('business', _billingCycle);
        success = rcResult.success;
        transactionId = rcResult.customerId;
        errorCode = rcResult.errorCode;
      } else {
        // Use Stripe on Android.
        final result = await StripeService.startCheckout(
          plan: 'business',
          billingCycle: _billingCycle,
          userEmail: authState.userEmail,
          licenseCount: paidLicenseCount,
        );
        success = result.success;
        transactionId = result.paymentIntentId;
        errorCode = result.errorCode;
      }

      if (!mounted) return;

      if (!success) {
        setState(() => _loading = false);
        final l10n = ref.read(l10nProvider);
        final msg = errorCode == 'cancelled'
            ? l10n.paymentCancelled
            : l10n.paymentFailed;
        _showSnack(msg, AppColors.error);
        return;
      }

      // Payment succeeded — record it and create the org.
      final record = PaymentRecord(
        id: transactionId?.isNotEmpty == true
            ? transactionId!
            : _uuid.v4(),
        transactionId: PaymentRecord.generateId(),
        userId: StorageService.currentUserId,
        plan: 'business',
        billingCycle: _billingCycle,
        amount: _totalPrice,
        currency: 'EUR',
        status: 'succeeded',
        stripePaymentIntentId: (Platform.isAndroid ? transactionId : null) ?? '',
        accountType: 'organization',
        createdAt: DateTime.now().toIso8601String(),
      );
      await DatabaseService.insertPaymentRecord(record);
    }

    final expiresAt = _billingCycle == 'yearly'
        ? DateTime.now().add(const Duration(days: 365))
        : DateTime.now().add(const Duration(days: 30));

    final error =
        await ref.read(organizationProvider.notifier).createOrganization(
              _nameCtrl.text,
              licenseCount: _licenseCount,
              orgPlanExpiresAt: expiresAt,
            );

    if (!mounted) return;
    setState(() => _loading = false);

    if (error != null) {
      _showSnack(error, AppColors.hot);
    } else {
      final l10n = ref.read(l10nProvider);
      _showSnack(l10n.orgCreated, AppColors.success);
      context.pop();
    }
  }

  void _showSnack(String msg, Color color) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), backgroundColor: color),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = ref.watch(l10nProvider);
    final authState = ref.watch(authProvider);
    final isBusinessUser = authState.plan == 'business';

    return Scaffold(
      backgroundColor: AppColors.bg(context),
      appBar: AppBar(
        backgroundColor: AppColors.primary,
        foregroundColor: Colors.white,
        title: Text(
          l10n.createOrgTitle,
          style:
              const TextStyle(color: Colors.white, fontWeight: FontWeight.w700),
        ),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_rounded),
          onPressed: () => context.pop(),
        ),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: isBusinessUser ? _buildForm(l10n) : _buildUpgradePrompt(l10n),
      ),
    );
  }

  // ── Upgrade prompt (non-Business users) ──────────────────────────────────────

  Widget _buildUpgradePrompt(AppL10n l10n) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        const SizedBox(height: 40),
        Container(
          width: 80,
          height: 80,
          decoration: BoxDecoration(
            color: AppColors.accent.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(24),
          ),
          child:
              const Icon(Icons.lock_rounded, color: AppColors.accent, size: 40),
        ),
        const SizedBox(height: 24),
        Text(
          l10n.orgBusinessPlanRequired,
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.w800,
            color: AppColors.onSurface(context),
          ),
        ),
        const SizedBox(height: 12),
        Text(
          l10n.orgBusinessPlanRequiredDesc,
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 14,
            color: AppColors.secondary(context),
            height: 1.5,
          ),
        ),
        const SizedBox(height: 32),
        SizedBox(
          width: double.infinity,
          child: ElevatedButton.icon(
            onPressed: () => context.push('/subscription-plan'),
            icon: const Icon(Icons.upgrade_rounded),
            label: Text(l10n.upgradeNow),
          ),
        ),
      ],
    );
  }

  // ── Main form (Business users) ───────────────────────────────────────────────

  Widget _buildForm(AppL10n l10n) {
    return Form(
      key: _formKey,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header icon + title
          Center(
            child: Container(
              width: 80,
              height: 80,
              decoration: BoxDecoration(
                gradient: AppColors.primaryGradient,
                borderRadius: BorderRadius.circular(24),
              ),
              child: const Icon(Icons.corporate_fare_rounded,
                  color: Colors.white, size: 40),
            ),
          ),
          const SizedBox(height: 20),
          Center(
            child: Text(
              l10n.createOrgTitle,
              style: TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.w800,
                color: AppColors.onSurface(context),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Center(
            child: Text(
              l10n.createOrgDesc,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 14,
                color: AppColors.secondary(context),
              ),
            ),
          ),
          const SizedBox(height: 32),

          // Org name
          Text(
            l10n.orgName,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: AppColors.hint(context),
              letterSpacing: 1,
            ),
          ),
          const SizedBox(height: 8),
          TextFormField(
            controller: _nameCtrl,
            textCapitalization: TextCapitalization.words,
            style: TextStyle(color: AppColors.onSurface(context)),
            cursorColor: AppColors.primary,
            decoration: InputDecoration(
              hintText: l10n.orgNameHint,
              hintStyle: TextStyle(color: AppColors.hint(context)),
              prefixIcon:
                  Icon(Icons.business_rounded, color: AppColors.hint(context)),
            ),
            validator: (v) =>
                (v == null || v.trim().isEmpty) ? l10n.orgNameRequired : null,
          ),
          const SizedBox(height: 24),

          // Billing cycle toggle
          Text(
            l10n.orgBillingCycle,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: AppColors.hint(context),
              letterSpacing: 1,
            ),
          ),
          const SizedBox(height: 8),
          _BillingCycleToggle(
            value: _billingCycle,
            onChanged: (v) => setState(() => _billingCycle = v),
            l10n: l10n,
          ),
          const SizedBox(height: 24),

          // License count stepper
          Text(
            l10n.orgSelectLicenses,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: AppColors.hint(context),
              letterSpacing: 1,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            l10n.orgLicensesIncludeAdmin,
            style: TextStyle(fontSize: 12, color: AppColors.hint(context)),
          ),
          const SizedBox(height: 10),
          _LicenseCountStepper(
            value: _licenseCount,
            onChanged: (v) => setState(() => _licenseCount = v),
          ),
          const SizedBox(height: 24),

          // Price summary card
          _PriceSummaryCard(
            licenseCount: _licenseCount,
            billingCycle: _billingCycle,
            unitPrice: _unitPrice,
            totalPrice: _totalPrice,
            formatPrice: _formatPrice,
            l10n: l10n,
          ),
          const SizedBox(height: 32),

          // Submit button
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: _loading ? null : _submit,
              icon: _loading
                  ? const SizedBox(
                      height: 18,
                      width: 18,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white),
                    )
                  : const Icon(Icons.payment_rounded),
              label: Text(l10n.orgPayAndCreate),
              style: ElevatedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 16),
              ),
            ),
          ),
          const SizedBox(height: 16),
          Center(
            child: Text(
              '🔒 ${l10n.secureTransactions}',
              style: TextStyle(fontSize: 12, color: AppColors.hint(context)),
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Billing cycle toggle ─────────────────────────────────────────────────────

class _BillingCycleToggle extends StatelessWidget {
  const _BillingCycleToggle({
    required this.value,
    required this.onChanged,
    required this.l10n,
  });

  final String value;
  final ValueChanged<String> onChanged;
  final AppL10n l10n;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.inputBackground(context),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.borderColor(context)),
      ),
      child: Row(
        children: [
          _Pill(
            label: l10n.orgMonthly,
            selected: value == 'monthly',
            onTap: () => onChanged('monthly'),
          ),
          _Pill(
            label: l10n.orgYearly,
            selected: value == 'yearly',
            onTap: () => onChanged('yearly'),
          ),
        ],
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          margin: const EdgeInsets.all(4),
          padding: const EdgeInsets.symmetric(vertical: 10),
          decoration: BoxDecoration(
            color: selected ? AppColors.primary : Colors.transparent,
            borderRadius: BorderRadius.circular(9),
          ),
          child: Text(
            label,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: selected ? Colors.white : AppColors.secondary(context),
            ),
          ),
        ),
      ),
    );
  }
}

// ─── License count stepper ────────────────────────────────────────────────────

class _LicenseCountStepper extends StatelessWidget {
  const _LicenseCountStepper({
    required this.value,
    required this.onChanged,
  });

  final int value;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: AppColors.surfaceColor(context),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.borderColor(context)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          IconButton(
            onPressed: value > 1 ? () => onChanged(value - 1) : null,
            icon: Icon(
              Icons.remove_circle_outline_rounded,
              color: value > 1 ? AppColors.primary : AppColors.cold,
              size: 28,
            ),
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(),
          ),
          Column(
            children: [
              Text(
                '$value',
                style: const TextStyle(
                  fontSize: 32,
                  fontWeight: FontWeight.w800,
                  color: AppColors.primary,
                ),
              ),
            ],
          ),
          IconButton(
            onPressed: () => onChanged(value + 1),
            icon: const Icon(
              Icons.add_circle_outline_rounded,
              color: AppColors.primary,
              size: 28,
            ),
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(),
          ),
        ],
      ),
    );
  }
}

// ─── Price summary card ───────────────────────────────────────────────────────

class _PriceSummaryCard extends StatelessWidget {
  const _PriceSummaryCard({
    required this.licenseCount,
    required this.billingCycle,
    required this.unitPrice,
    required this.totalPrice,
    required this.formatPrice,
    required this.l10n,
  });

  final int licenseCount;
  final String billingCycle;
  final double unitPrice;
  final double totalPrice;
  final String Function(double) formatPrice;
  final AppL10n l10n;

  @override
  Widget build(BuildContext context) {
    final periodLabel = billingCycle == 'yearly'
        ? l10n.orgPricePerLicenseYearly
        : l10n.orgPricePerLicense;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.primary.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.primary.withValues(alpha: 0.18)),
      ),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                l10n.orgLicenseCount(licenseCount),
                style: TextStyle(
                  fontSize: 14,
                  color: AppColors.secondary(context),
                ),
              ),
              Text(
                '${formatPrice(unitPrice)} $periodLabel',
                style: TextStyle(
                  fontSize: 13,
                  color: AppColors.secondary(context),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          const Divider(height: 1),
          const SizedBox(height: 10),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                'TOTAL',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: AppColors.primary,
                  letterSpacing: 1,
                ),
              ),
              Text(
                formatPrice(totalPrice),
                style: const TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w800,
                  color: AppColors.primary,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

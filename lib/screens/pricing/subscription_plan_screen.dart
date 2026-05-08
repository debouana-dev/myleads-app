import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/l10n/app_l10n.dart';
import '../../core/theme/app_colors.dart';
import '../../providers/auth_provider.dart';
import '../../providers/currency_provider.dart';
import '../../providers/settings_provider.dart';

class SubscriptionPlanScreen extends ConsumerStatefulWidget {
  const SubscriptionPlanScreen({super.key});

  @override
  ConsumerState<SubscriptionPlanScreen> createState() =>
      _SubscriptionPlanScreenState();
}

class _SubscriptionPlanScreenState
    extends ConsumerState<SubscriptionPlanScreen> {
  String? _loadingPlan;

  Future<void> _selectPlan(String planId) async {
    setState(() => _loadingPlan = planId);
    final err = await ref.read(authProvider.notifier).changePlan(planId);
    if (!mounted) return;
    setState(() => _loadingPlan = null);
    final l10n = ref.read(l10nProvider);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content:
            Text(err == null ? l10n.planChangedSuccess : l10n.planChangeError),
        backgroundColor: err == null ? AppColors.success : AppColors.error,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = ref.watch(l10nProvider);
    final currency = ref.watch(settingsProvider).currency;
    final eurToUsd = ref.watch(eurToUsdRateProvider);
    final currentPlan = ref.watch(authProvider).plan;

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
                  // Free
                  _PlanCard(
                    title: l10n.freePlanName,
                    price: l10n.freeLabel,
                    description: l10n.freePlanDesc,
                    features: _freeFeatures(l10n),
                    isPopular: false,
                    isCurrent: currentPlan == 'free',
                    isLoading: _loadingPlan == 'free',
                    onSelect: currentPlan == 'free'
                        ? null
                        : () => _selectPlan('free'),
                    l10n: l10n,
                  ),
                  const SizedBox(height: 16),

                  // Premium
                  _PlanCard(
                    title: l10n.premiumPlanName,
                    price:
                        l10n.premiumPrice(currency, eurToTargetRate: eurToUsd),
                    period: l10n.premiumPeriod(currency),
                    description: l10n.premiumPlanDesc,
                    features: _premiumFeatures(l10n),
                    isPopular: true,
                    isCurrent: currentPlan == 'premium',
                    isLoading: _loadingPlan == 'premium',
                    onSelect: currentPlan == 'premium'
                        ? null
                        : () => _selectPlan('premium'),
                    l10n: l10n,
                  ),
                  const SizedBox(height: 16),

                  // Business
                  _PlanCard(
                    title: l10n.businessPlanName,
                    price:
                        l10n.businessPrice(currency, eurToTargetRate: eurToUsd),
                    period: l10n.businessPeriod(currency),
                    description: l10n.businessPlanDesc,
                    features: _businessFeatures(l10n),
                    isPopular: false,
                    isCurrent: currentPlan == 'business',
                    isLoading: _loadingPlan == 'business',
                    onSelect: currentPlan == 'business'
                        ? null
                        : () => _selectPlan('business'),
                    l10n: l10n,
                  ),

                  const SizedBox(height: 24),

                  // Payment methods
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
                          l10n.paymentMethodsTitle,
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                            color: AppColors.hint(context),
                            letterSpacing: 1,
                          ),
                        ),
                        const SizedBox(height: 12),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            _paymentChip(context, l10n.bankCard),
                            _paymentChip(context, 'PayPal'),
                            _paymentChip(context, 'Apple Pay'),
                            _paymentChip(context, 'Google Pay'),
                            _paymentChip(context, 'Amazon Pay'),
                          ],
                        ),
                        const SizedBox(height: 12),
                        Text(
                          l10n.securePayment,
                          style: TextStyle(
                            fontSize: 11,
                            color: AppColors.hint(context),
                          ),
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

// ─── Plan card ────────────────────────────────────────────────────────────────

class _PlanCard extends StatelessWidget {
  final String title;
  final String price;
  final String? period;
  final String description;
  final List<String> features;
  final bool isPopular;
  final bool isCurrent;
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

          if (!isCurrent) ...[
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              height: 50,
              child: ElevatedButton(
                onPressed: isLoading ? null : onSelect,
                style: ElevatedButton.styleFrom(
                  backgroundColor:
                      isPopular ? AppColors.accent : AppColors.primary,
                  foregroundColor: isPopular ? AppColors.primary : Colors.white,
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
                          color: isPopular ? AppColors.primary : Colors.white,
                        ),
                      )
                    : Text(
                        '${l10n.choosePlanCta} $title',
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

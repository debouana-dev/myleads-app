import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/l10n/app_l10n.dart';
import '../../core/theme/app_colors.dart';
import '../../providers/auth_provider.dart';
import '../../providers/currency_provider.dart';
import '../../providers/settings_provider.dart';

class PricingScreen extends ConsumerWidget {
  const PricingScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = ref.watch(l10nProvider);
    final currency = ref.watch(settingsProvider).currency;
    final eurToUsd = ref.watch(eurToUsdRateProvider);
    final plan = ref.watch(authProvider).plan;

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
                            ],
                          ),
                        ),
                        GestureDetector(
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
                              period: l10n.premiumPeriod(l10n),
                              highlight: true,
                            ),
                            const SizedBox(width: 10),
                            _MiniPlanTile(
                              name: l10n.businessPlanName,
                              price: l10n.businessPrice(currency,
                                  eurToTargetRate: eurToUsd),
                              period: l10n.businessPeriod(l10n),
                              highlight: false,
                            ),
                          ],
                        ),
                        const SizedBox(height: 14),
                        Row(
                          children: [
                            const Icon(Icons.lock_rounded,
                                size: 14, color: AppColors.success),
                            const SizedBox(width: 6),
                            Text(
                              l10n.secureTransactions,
                              style: TextStyle(
                                fontSize: 11,
                                color: AppColors.secondary(context),
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

  const _MiniPlanTile({
    required this.name,
    required this.price,
    required this.period,
    required this.highlight,
  });

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: highlight
              ? AppColors.primary.withOpacity(0.06)
              : AppColors.bg(context),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: highlight
                ? AppColors.primary.withOpacity(0.2)
                : AppColors.borderColor(context),
          ),
        ),
        child: Column(
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
      ),
    );
  }
}

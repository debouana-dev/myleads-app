import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/l10n/app_l10n.dart';
import '../../core/theme/app_colors.dart';
import '../../providers/currency_provider.dart';
import '../../providers/settings_provider.dart';

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = ref.watch(l10nProvider);
    final settings = ref.watch(settingsProvider);
    final notifier = ref.read(settingsProvider.notifier);
    final isDark = settings.themeMode == ThemeMode.dark;
    final eurToUsd = ref.watch(eurToUsdRateProvider);

    return Scaffold(
      backgroundColor: AppColors.bg(context),
      appBar: AppBar(
        backgroundColor: AppColors.bg(context),
        elevation: 0,
        iconTheme: IconThemeData(color: AppColors.onSurface(context)),
        title: Text(
          l10n.settingsTitle,
          style: TextStyle(
            color: AppColors.onSurface(context),
            fontSize: 18,
            fontWeight: FontWeight.w800,
          ),
        ),
        leading: GestureDetector(
          onTap: () => Navigator.of(context).pop(),
          child: Icon(Icons.arrow_back_rounded,
              color: AppColors.onSurface(context)),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 40),
        children: [
          // ── Appearance ──────────────────────────────────────────────────
          _SectionHeader(label: l10n.appearance),
          const SizedBox(height: 12),

          // Theme
          _SettingCard(
            icon: isDark ? Icons.dark_mode_rounded : Icons.light_mode_rounded,
            iconColor: isDark ? AppColors.accent : AppColors.primary,
            title: l10n.themeColor,
            subtitle: l10n.themeColorDesc,
            child: _ThemeToggle(
              isDark: isDark,
              lightLabel: l10n.lightMode,
              darkLabel: l10n.darkMode,
              onChanged: (dark) => notifier
                  .setThemeMode(dark ? ThemeMode.dark : ThemeMode.light),
            ),
          ),

          const SizedBox(height: 12),

          // Language
          _SettingCard(
            icon: Icons.language_rounded,
            iconColor: AppColors.info,
            title: l10n.languageOption,
            subtitle: l10n.languageDesc,
            child: _OptionSelector<AppLanguage>(
              options: const [AppLanguage.fr, AppLanguage.en],
              current: settings.language,
              labelOf: (lang) =>
                  lang == AppLanguage.fr ? l10n.languageFr : l10n.languageEn,
              onSelected: (lang) => notifier.setLanguage(lang),
            ),
          ),

          const SizedBox(height: 12),

          // Currency
          _SettingCard(
            icon: Icons.payments_rounded,
            iconColor: AppColors.success,
            title: l10n.currencyOption,
            subtitle: l10n.currencyDesc,
            child: _OptionSelector<AppCurrency>(
              options: const [AppCurrency.eur, AppCurrency.usd],
              current: settings.currency,
              labelOf: (c) =>
                  c == AppCurrency.eur ? l10n.currencyEur : l10n.currencyUsd,
              onSelected: (c) => notifier.setCurrency(c),
            ),
          ),

          const SizedBox(height: 32),

          // Preview card showing currency in action
          _PreviewCard(settings: settings, l10n: l10n, eurToUsd: eurToUsd),
        ],
      ),
    );
  }
}

// ─── Section header ───────────────────────────────────────────────────────────

class _SectionHeader extends StatelessWidget {
  final String label;
  const _SectionHeader({required this.label});

  @override
  Widget build(BuildContext context) {
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
}

// ─── Setting card ─────────────────────────────────────────────────────────────

class _SettingCard extends StatelessWidget {
  final IconData icon;
  final Color iconColor;
  final String title;
  final String subtitle;
  final Widget child;

  const _SettingCard({
    required this.icon,
    required this.iconColor,
    required this.title,
    required this.subtitle,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surfaceColor(context),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.borderColor(context)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: iconColor.withOpacity(0.12),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(icon, color: iconColor, size: 20),
              ),
              const SizedBox(width: 12),
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
            ],
          ),
          const SizedBox(height: 16),
          child,
        ],
      ),
    );
  }
}

// ─── Theme toggle ─────────────────────────────────────────────────────────────

class _ThemeToggle extends StatelessWidget {
  final bool isDark;
  final String lightLabel;
  final String darkLabel;
  final ValueChanged<bool> onChanged;

  const _ThemeToggle({
    required this.isDark,
    required this.lightLabel,
    required this.darkLabel,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: _ToggleChip(
            label: lightLabel,
            icon: Icons.light_mode_rounded,
            isSelected: !isDark,
            onTap: () => onChanged(false),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: _ToggleChip(
            label: darkLabel,
            icon: Icons.dark_mode_rounded,
            isSelected: isDark,
            onTap: () => onChanged(true),
          ),
        ),
      ],
    );
  }
}

// ─── Option selector ─────────────────────────────────────────────────────────

class _OptionSelector<T> extends StatelessWidget {
  final List<T> options;
  final T current;
  final String Function(T) labelOf;
  final ValueChanged<T> onSelected;

  const _OptionSelector({
    required this.options,
    required this.current,
    required this.labelOf,
    required this.onSelected,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: options.map((opt) {
        final isSelected = opt == current;
        return Expanded(
          child: Padding(
            padding: EdgeInsets.only(
              right: opt != options.last ? 10 : 0,
            ),
            child: _ToggleChip(
              label: labelOf(opt),
              isSelected: isSelected,
              onTap: () => onSelected(opt),
            ),
          ),
        );
      }).toList(),
    );
  }
}

// ─── Toggle chip ──────────────────────────────────────────────────────────────

class _ToggleChip extends StatelessWidget {
  final String label;
  final IconData? icon;
  final bool isSelected;
  final VoidCallback onTap;

  const _ToggleChip({
    required this.label,
    required this.isSelected,
    required this.onTap,
    this.icon,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(vertical: 11),
        decoration: BoxDecoration(
          gradient: isSelected ? AppColors.primaryGradient : null,
          color: isSelected ? null : AppColors.bg(context),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color:
                isSelected ? AppColors.primary : AppColors.borderColor(context),
          ),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (icon != null) ...[
              Icon(
                icon,
                size: 15,
                color:
                    isSelected ? AppColors.white : AppColors.secondary(context),
              ),
              const SizedBox(width: 6),
            ],
            Text(
              label,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color:
                    isSelected ? AppColors.white : AppColors.secondary(context),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Preview card ─────────────────────────────────────────────────────────────

class _PreviewCard extends StatelessWidget {
  final SettingsState settings;
  final AppL10n l10n;
  final double eurToUsd;

  const _PreviewCard({
    required this.settings,
    required this.l10n,
    required this.eurToUsd,
  });

  @override
  Widget build(BuildContext context) {
    final currency = settings.currency;
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: AppColors.primaryGradient,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Preview',
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              color: AppColors.white.withOpacity(0.6),
              letterSpacing: 1,
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              _previewPlanTile(
                context,
                label: l10n.premiumPlanName,
                price: l10n.premiumPrice(currency, eurToTargetRate: eurToUsd),
                period: l10n.premiumPeriod(l10n),
                highlight: true,
              ),
              const SizedBox(width: 10),
              _previewPlanTile(
                context,
                label: l10n.businessPlanName,
                price: l10n.businessPrice(currency, eurToTargetRate: eurToUsd),
                period: l10n.businessPeriod(l10n),
                highlight: false,
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _previewPlanTile(
    BuildContext context, {
    required String label,
    required String price,
    required String period,
    required bool highlight,
  }) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: highlight
              ? AppColors.accent.withOpacity(0.2)
              : AppColors.white.withOpacity(0.08),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: highlight
                ? AppColors.accent.withOpacity(0.5)
                : AppColors.white.withOpacity(0.12),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label,
                style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: AppColors.white)),
            const SizedBox(height: 4),
            Text(price,
                style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w800,
                    color: highlight ? AppColors.accent : AppColors.white)),
            Text(period,
                style: TextStyle(
                    fontSize: 10, color: AppColors.white.withOpacity(0.6))),
          ],
        ),
      ),
    );
  }
}

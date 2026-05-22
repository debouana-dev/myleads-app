import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/constants/app_strings.dart';
import '../../core/l10n/app_l10n.dart';
import '../../core/theme/app_colors.dart';
import '../../models/contact.dart';
import '../../providers/auth_provider.dart';
import '../../providers/contacts_provider.dart';
import '../../providers/navigation_provider.dart';
import '../../providers/notifications_provider.dart';
import '../../providers/reminders_provider.dart';
import '../scan/scan_screen.dart';
import '../../services/photo_storage_service.dart';

class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  Future<void> _refreshData(WidgetRef ref) async {
    await Future.wait([
      ref.read(contactsProvider.notifier).reload(),
      ref.read(remindersProvider.notifier).refresh(),
      ref.read(notificationsProvider.notifier).refresh(),
    ]);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = ref.watch(l10nProvider);
    final contactsState = ref.watch(contactsProvider);
    final remindersState = ref.watch(remindersProvider);
    final hotLeads = ref.watch(hotLeadsProvider);
    final notificationsState = ref.watch(notificationsProvider);

    return Scaffold(
      backgroundColor: AppColors.bg(context),
      body: Column(
        children: [
          // -- Header --
          _Header(
            notificationCount: notificationsState.unreadCount,
            onNotificationTap: () => context.push('/notifications'),
            onSearchChanged: (q) =>
                ref.read(contactsProvider.notifier).setSearchQuery(q),
            onSearchSubmitted: () =>
                ref.read(currentTabProvider.notifier).state = 1,
            onSuggestionSelected: (contact) =>
                context.push('/contact/${contact.id}'),
          ),

          // -- Content --
          Expanded(
            child: RefreshIndicator(
              onRefresh: () => _refreshData(ref),
              child: SingleChildScrollView(
                physics: const BouncingScrollPhysics(),
                padding: EdgeInsets.fromLTRB(20, 24, 20,
                    88 + MediaQuery.of(context).padding.bottom + 5),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // CTA cards
                    _CTARow(
                      onScanTap: () => showScanOptions(context, ref),
                      onManualTap: () => context.push('/contact/new'),
                      l10n: l10n,
                    ),
                    const SizedBox(height: 24),

                    // Stats row
                    _StatsRow(
                      totalContacts: contactsState.totalContacts,
                      hotLeadsCount: contactsState.hotLeads,
                      remindersCount: remindersState.todayReminders.length +
                          remindersState.overdueReminders.length,
                      onContactsTap: () {
                        ref.read(contactsProvider.notifier).setFilter('all');
                        ref.read(currentTabProvider.notifier).state = 1;
                      },
                      onHotLeadsTap: () {
                        ref.read(contactsProvider.notifier).setFilter('hot');
                        ref.read(currentTabProvider.notifier).state = 1;
                      },
                      onRemindersTap: () =>
                          ref.read(currentTabProvider.notifier).state = 2,
                      l10n: l10n,
                    ),
                    const SizedBox(height: 28),

                    // Hot leads section
                    _SectionHeader(
                      title: l10n.hotLeads,
                      icon: Icons.local_fire_department_rounded,
                      iconColor: AppColors.hot,
                      onViewAll: () =>
                          ref.read(currentTabProvider.notifier).state = 1,
                      viewAllLabel: l10n.viewAll,
                    ),
                    const SizedBox(height: 12),
                    if (hotLeads.isEmpty)
                      _EmptyPlaceholder(
                        icon: Icons.local_fire_department_outlined,
                        text: l10n.noHotLeads,
                      )
                    else
                      ...hotLeads.take(3).map(
                            (contact) => Padding(
                              padding: const EdgeInsets.only(bottom: 12),
                              child: _HotLeadCard(
                                contact: contact,
                                onTap: () =>
                                    context.push('/contact/${contact.id}'),
                              ),
                            ),
                          ),
                    const SizedBox(height: 28),

                    // Reminders section
                    _SectionHeader(
                      title: l10n.reminders,
                      icon: Icons.notifications_active_rounded,
                      iconColor: AppColors.warm,
                      onViewAll: () =>
                          ref.read(currentTabProvider.notifier).state = 2,
                      viewAllLabel: l10n.viewAll,
                    ),
                    const SizedBox(height: 12),
                    _RemindersSummaryCard(
                      todayCount: remindersState.todayReminders.length,
                      overdueCount: remindersState.overdueReminders.length,
                      completedCount: remindersState.completedReminders.length,
                      l10n: l10n,
                    ),
                  ],
                ),
              ),
            ),
          )
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Header
// ---------------------------------------------------------------------------

class _Header extends ConsumerWidget {
  final int notificationCount;
  final VoidCallback onNotificationTap;
  final ValueChanged<String> onSearchChanged;
  final VoidCallback onSearchSubmitted;
  final ValueChanged<Contact> onSuggestionSelected;

  const _Header(
      {required this.notificationCount,
      required this.onNotificationTap,
      required this.onSearchChanged,
      required this.onSearchSubmitted,
      required this.onSuggestionSelected});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = ref.watch(l10nProvider);
    final topPadding = MediaQuery.of(context).padding.top;
    final userName = ref.watch(
        authProvider.select((s) => s.userName.isEmpty ? '' : s.userName));
    final firstName = userName.isEmpty ? '' : userName.split(' ').first;

    final contacts = ref.watch(contactsProvider).contacts;

    return Container(
      padding: EdgeInsets.fromLTRB(20, topPadding + 16, 20, 20),
      decoration: const BoxDecoration(
        gradient: AppColors.primaryGradient,
        borderRadius: BorderRadius.only(
          bottomLeft: Radius.circular(32),
          bottomRight: Radius.circular(32),
        ),
      ),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      firstName.isEmpty
                          ? '${l10n.hello} 👋'
                          : '${l10n.hello} $firstName 👋',
                      style: const TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.w700,
                        color: AppColors.white,
                        letterSpacing: -0.3,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      l10n.slogan,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w400,
                        color: AppColors.white.withOpacity(0.7),
                      ),
                    ),
                  ],
                ),
              ),
              _NotificationBell(
                count: notificationCount,
                onTap: onNotificationTap,
              ),
            ],
          ),
          const SizedBox(height: 20),

          // Search bar (functional)
          Container(
            height: 48,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            decoration: BoxDecoration(
              color: AppColors.white,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: AppColors.border),
            ),
            child: Row(
              children: [
                const Icon(
                  Icons.search_rounded,
                  color: AppColors.textLight,
                  size: 20,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Autocomplete<Contact>(
                    optionsBuilder: (TextEditingValue textEditingValue) {
                      if (textEditingValue.text.isEmpty) {
                        return const Iterable<Contact>.empty();
                      }
                      final query = textEditingValue.text.toLowerCase();
                      return contacts
                          .where(
                              (c) => c.fullName.toLowerCase().contains(query))
                          .take(5);
                    },
                    onSelected:
                        onSuggestionSelected, // Utiliser le callback passé
                    displayStringForOption: (Contact contact) =>
                        contact.fullName,
                    fieldViewBuilder: (BuildContext context,
                        TextEditingController textEditingController,
                        FocusNode focusNode,
                        VoidCallback onFieldSubmitted) {
                      return TextField(
                        controller: textEditingController,
                        focusNode: focusNode,
                        onChanged: onSearchChanged,
                        onSubmitted: (_) => onSearchSubmitted(),
                        textInputAction: TextInputAction.search,
                        style: const TextStyle(
                          fontSize: 14,
                          color: Colors.black,
                          fontWeight: FontWeight.w500,
                        ),
                        cursorColor: AppColors.primary,
                        decoration: InputDecoration(
                          hintText: l10n.searchContact,
                          hintStyle: const TextStyle(
                            fontSize: 14,
                            color: AppColors.textLight,
                            fontWeight: FontWeight.w400,
                          ),
                          border: InputBorder.none,
                          enabledBorder: InputBorder.none,
                          focusedBorder: InputBorder.none,
                          isDense: true,
                          contentPadding:
                              const EdgeInsets.symmetric(vertical: 12),
                        ),
                      );
                    },
                    optionsViewBuilder: (BuildContext context,
                        AutocompleteOnSelected<Contact> onSelected,
                        Iterable<Contact> options) {
                      return Align(
                        alignment: Alignment.topLeft,
                        child: Material(
                          elevation: 4.0,
                          child: Container(
                            width: MediaQuery.of(context).size.width - 40,
                            constraints: const BoxConstraints(maxHeight: 200),
                            decoration: BoxDecoration(
                              color: AppColors.surfaceColor(context),
                              borderRadius: BorderRadius.circular(14),
                              border: Border.all(
                                  color: AppColors.borderColor(context)),
                            ),
                            child: ListView.builder(
                              padding: EdgeInsets.zero,
                              shrinkWrap: true,
                              itemCount: options.length,
                              itemBuilder: (BuildContext context, int index) {
                                final contact = options.elementAt(index);
                                return ListTile(
                                  title: Text(
                                    contact.fullName,
                                    style: TextStyle(
                                      fontSize: 14,
                                      color: AppColors.onSurface(context),
                                    ),
                                  ),
                                  onTap: () => onSelected(contact),
                                );
                              },
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Notification bell with badge
// ---------------------------------------------------------------------------

class _NotificationBell extends StatelessWidget {
  final int count;
  final VoidCallback onTap;

  const _NotificationBell({required this.count, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: SizedBox(
        width: 44,
        height: 44,
        child: Stack(
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: AppColors.white.withOpacity(0.12),
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.notifications_outlined,
                color: AppColors.white,
                size: 22,
              ),
            ),
            if (count > 0)
              Positioned(
                top: 2,
                right: 2,
                child: Container(
                  width: 18,
                  height: 18,
                  decoration: const BoxDecoration(
                    color: AppColors.hot,
                    shape: BoxShape.circle,
                  ),
                  child: Center(
                    child: Text(
                      count > 9 ? '9+' : count.toString(),
                      style: const TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w700,
                        color: AppColors.white,
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// CTA Row (Scanner + Ajouter)
// ---------------------------------------------------------------------------

class _CTARow extends StatelessWidget {
  final VoidCallback onScanTap;
  final VoidCallback onManualTap;
  final AppL10n l10n;

  const _CTARow({
    required this.onScanTap,
    required this.onManualTap,
    required this.l10n,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        // Scan card
        Expanded(
          child: _CTACard(
            label: l10n.scanContact,
            icon: Icons.document_scanner_rounded,
            gradient: AppColors.accentGradient,
            textColor: AppColors.white,
            iconColor: AppColors.white,
            onTap: onScanTap,
          ),
        ),
        const SizedBox(width: 14),
        // Manual card
        Expanded(
          child: _CTACard(
            label: l10n.addManually,
            icon: Icons.person_add_alt_1_rounded,
            gradient: null,
            backgroundColor: AppColors.surfaceColor(context),
            textColor: AppColors.onSurface(context),
            iconColor: AppColors.primary,
            onTap: onManualTap,
          ),
        ),
      ],
    );
  }
}

class _CTACard extends StatelessWidget {
  final String label;
  final IconData icon;
  final LinearGradient? gradient;
  final Color? backgroundColor;
  final Color textColor;
  final Color iconColor;
  final VoidCallback onTap;

  const _CTACard({
    required this.label,
    required this.icon,
    this.gradient,
    this.backgroundColor,
    required this.textColor,
    required this.iconColor,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        height: 110,
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          gradient: gradient,
          color: gradient == null ? backgroundColor : null,
          borderRadius: BorderRadius.circular(20),
          boxShadow: [
            BoxShadow(
              color: (gradient != null
                      ? AppColors.accent
                      : AppColors.onSurface(context))
                  .withOpacity(0.12),
              blurRadius: 16,
              offset: const Offset(0, 6),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: (gradient != null ? AppColors.white : AppColors.primary)
                    .withOpacity(gradient != null ? 0.2 : 0.08),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(icon, color: iconColor, size: 22),
            ),
            Text(
              label,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: textColor,
                height: 1.2,
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Stats Row
// ---------------------------------------------------------------------------

class _StatsRow extends StatelessWidget {
  final int totalContacts;
  final int hotLeadsCount;
  final int remindersCount;
  final VoidCallback onContactsTap;
  final VoidCallback onHotLeadsTap;
  final VoidCallback onRemindersTap;
  final AppL10n l10n;

  const _StatsRow({
    required this.totalContacts,
    required this.hotLeadsCount,
    required this.remindersCount,
    required this.onContactsTap,
    required this.onHotLeadsTap,
    required this.onRemindersTap,
    required this.l10n,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: _StatCard(
            label: l10n.contacts,
            value: totalContacts.toString(),
            icon: Icons.people_alt_rounded,
            color: AppColors.primary,
            onTap: onContactsTap,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: _StatCard(
            label: l10n.hotLeads,
            value: hotLeadsCount.toString(),
            icon: Icons.local_fire_department_rounded,
            color: AppColors.hot,
            onTap: onHotLeadsTap,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: _StatCard(
            label: l10n.reminders,
            value: remindersCount.toString(),
            icon: Icons.notifications_active_rounded,
            color: AppColors.warm,
            onTap: onRemindersTap,
          ),
        ),
      ],
    );
  }
}

class _StatCard extends StatelessWidget {
  final String label;
  final String value;
  final IconData icon;
  final Color color;
  final VoidCallback? onTap;

  const _StatCard({
    required this.label,
    required this.value,
    required this.icon,
    required this.color,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final card = Container(
      padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 12),
      decoration: BoxDecoration(
        color: AppColors.surfaceColor(context),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.borderColor(context), width: 1),
      ),
      child: Column(
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: color.withOpacity(0.1),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(icon, color: color, size: 18),
          ),
          const SizedBox(height: 10),
          Text(
            value,
            style: TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.w800,
              color: AppColors.onSurface(context),
            ),
          ),
          const SizedBox(height: 2),
          Text(
            label,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w500,
              color: AppColors.hint(context),
            ),
            textAlign: TextAlign.center,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
    if (onTap == null) return card;
    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: card,
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Section header
// ---------------------------------------------------------------------------

class _SectionHeader extends StatelessWidget {
  final String title;
  final IconData icon;
  final Color iconColor;
  final VoidCallback onViewAll;
  final String viewAllLabel;

  const _SectionHeader({
    required this.title,
    required this.icon,
    required this.iconColor,
    required this.onViewAll,
    required this.viewAllLabel,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, color: iconColor, size: 20),
        const SizedBox(width: 8),
        Text(
          title,
          style: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.w700,
            color: AppColors.onSurface(context),
          ),
        ),
        const Spacer(),
        GestureDetector(
          onTap: onViewAll,
          child: Text(
            viewAllLabel,
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: AppColors.accent,
            ),
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Hot Lead Card
// ---------------------------------------------------------------------------

class _HotLeadCard extends StatelessWidget {
  final Contact contact;
  final VoidCallback onTap;

  const _HotLeadCard({required this.contact, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: AppColors.surfaceColor(context),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: AppColors.borderColor(context), width: 1),
          boxShadow: [
            BoxShadow(
              color: AppColors.onSurface(context).withOpacity(0.04),
              blurRadius: 8,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Row(
          children: [
            // Avatar with gradient or photo
            Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                gradient: contact.photoPath == null || kIsWeb
                    ? AppColors.avatarGradient(contact.status)
                    : null,
                borderRadius: BorderRadius.circular(14),
                image: contact.photoPath != null && !kIsWeb
                    ? DecorationImage(
                        image: FileImage(File(
                            PhotoStorageService.resolveAbsolutePath(
                                contact.photoPath)!)),
                        fit: BoxFit.cover,
                      )
                    : null,
              ),
              child: contact.photoPath == null || kIsWeb
                  ? Center(
                      child: Text(
                        contact.initials,
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                          color: AppColors.white,
                        ),
                      ),
                    )
                  : null,
            ),
            const SizedBox(width: 14),
            // Name + company
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    contact.fullName,
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                      color: AppColors.onSurface(context),
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (contact.subtitle.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(
                      contact.subtitle,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                        color: AppColors.secondary(context),
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 10),
            // HOT badge
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: BoxDecoration(
                color: AppColors.hot.withOpacity(0.1),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                  color: AppColors.hot.withOpacity(0.25),
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.local_fire_department_rounded,
                    size: 12,
                    color: AppColors.hot,
                  ),
                  const SizedBox(width: 4),
                  const Text(
                    'HOT',
                    style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                      color: AppColors.hot,
                      letterSpacing: 0.8,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 6),
            Icon(
              Icons.chevron_right_rounded,
              color: AppColors.hint(context),
              size: 20,
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Reminders Summary Card
// ---------------------------------------------------------------------------

class _RemindersSummaryCard extends StatelessWidget {
  final int todayCount;
  final int overdueCount;
  final int completedCount;
  final AppL10n l10n;

  const _RemindersSummaryCard({
    required this.todayCount,
    required this.overdueCount,
    required this.completedCount,
    required this.l10n,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [AppColors.primaryDark, AppColors.primary],
        ),
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: AppColors.primary.withOpacity(0.3),
            blurRadius: 20,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Row(
        children: [
          Expanded(
            child: _ReminderStat(
              label: l10n.today,
              value: todayCount.toString(),
              color: AppColors.white,
              icon: Icons.today_rounded,
            ),
          ),
          _VerticalDivider(),
          Expanded(
            child: _ReminderStat(
              label: l10n.overdue,
              value: overdueCount.toString(),
              color: AppColors.hotLight,
              icon: Icons.warning_amber_rounded,
            ),
          ),
          _VerticalDivider(),
          Expanded(
            child: _ReminderStat(
              label: l10n.done,
              value: completedCount.toString(),
              color: AppColors.successLight,
              icon: Icons.check_circle_outline_rounded,
            ),
          ),
        ],
      ),
    );
  }
}

class _ReminderStat extends StatelessWidget {
  final String label;
  final String value;
  final Color color;
  final IconData icon;

  const _ReminderStat({
    required this.label,
    required this.value,
    required this.color,
    required this.icon,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Icon(icon, color: color, size: 22),
        const SizedBox(height: 8),
        Text(
          value,
          style: TextStyle(
            fontSize: 26,
            fontWeight: FontWeight.w800,
            color: color,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          label,
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w500,
            color: AppColors.white.withOpacity(0.65),
          ),
          textAlign: TextAlign.center,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ],
    );
  }
}

class _VerticalDivider extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      width: 1,
      height: 50,
      margin: const EdgeInsets.symmetric(horizontal: 4),
      color: AppColors.white.withOpacity(0.15),
    );
  }
}

// ---------------------------------------------------------------------------
// Empty placeholder
// ---------------------------------------------------------------------------

class _EmptyPlaceholder extends StatelessWidget {
  final IconData icon;
  final String text;

  const _EmptyPlaceholder({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 32),
      decoration: BoxDecoration(
        color: AppColors.surfaceColor(context),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.borderColor(context)),
      ),
      child: Column(
        children: [
          Icon(icon, color: AppColors.hint(context), size: 36),
          const SizedBox(height: 8),
          Text(
            text,
            style: TextStyle(
              fontSize: 13,
              color: AppColors.hint(context),
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }
}

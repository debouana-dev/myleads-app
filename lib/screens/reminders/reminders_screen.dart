import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../core/l10n/app_l10n.dart';
import '../../core/theme/app_colors.dart';
import '../../models/reminder.dart';
import '../../providers/contacts_provider.dart';
import '../../providers/reminders_provider.dart';
import '../../services/calendar_service.dart';
import 'create_reminder_screen.dart';
import 'reminder_detail_screen.dart';

class RemindersScreen extends ConsumerStatefulWidget {
  const RemindersScreen({super.key});
  @override
  ConsumerState<RemindersScreen> createState() => _RemindersScreenState();
}

class _RemindersScreenState extends ConsumerState<RemindersScreen> {
  String _activeTab = 'today';

  @override
  Widget build(BuildContext context) {
    final l10n = ref.watch(l10nProvider);
    final state = ref.watch(remindersProvider);
    List<Reminder> current;
    switch (_activeTab) {
      case 'week':
        current = state.weekReminders;
        break;
      case 'later':
        current = state.laterReminders;
        break;
      case 'late':
        current = state.lateReminders;
        break;
      case 'done':
        current = state.doneReminders;
        break;
      default:
        current = state.todayReminders;
    }

    final tabs = <(String, String, int)>[
      ('today', l10n.tabToday, state.todayReminders.length),
      ('week', l10n.tabWeek, state.weekReminders.length),
      ('later', l10n.tabLater, state.laterReminders.length),
      ('late', l10n.tabLate, state.lateReminders.length),
      ('done', l10n.tabDone, state.doneReminders.length),
    ];

    return Scaffold(
      backgroundColor: AppColors.bg(context),
      floatingActionButton: Padding(
        padding: EdgeInsets.only(
          bottom: 88 + MediaQuery.of(context).padding.bottom,
        ),
        child: FloatingActionButton.extended(
          backgroundColor: AppColors.primary,
          foregroundColor: Colors.white,
          onPressed: () {
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => ProviderScope(
                  parent: ProviderScope.containerOf(context),
                  child: const CreateReminderScreen(),
                ),
              ),
            );
          },
          icon: const Icon(Icons.add_rounded),
          label: Text(l10n.newReminder,
              style: const TextStyle(fontWeight: FontWeight.w700)),
        ),
      ),
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
              child: Row(
                children: [
                  Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      gradient: AppColors.primaryGradient,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Icon(Icons.notifications_rounded, color: Colors.white),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(l10n.remindersTitle,
                            style: TextStyle(
                                fontSize: 22,
                                fontWeight: FontWeight.w800,
                                color: AppColors.onSurface(context))),
                        Text(l10n.remindersSubtitle,
                            style: TextStyle(fontSize: 13, color: AppColors.secondary(context))),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            SizedBox(
              height: 44,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 20),
                itemCount: tabs.length,
                separatorBuilder: (_, __) => const SizedBox(width: 8),
                itemBuilder: (_, i) {
                  final t = tabs[i];
                  final active = t.$1 == _activeTab;
                  final isLateTab = t.$1 == 'late';
                  return GestureDetector(
                    onTap: () => setState(() => _activeTab = t.$1),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                      decoration: BoxDecoration(
                        gradient: active
                            ? (isLateTab ? AppColors.hotGradient : AppColors.primaryGradient)
                            : null,
                        color: active ? null : AppColors.surfaceColor(context),
                        borderRadius: BorderRadius.circular(22),
                        border: active ? null : Border.all(color: AppColors.borderColor(context)),
                      ),
                      child: Row(
                        children: [
                          Text(t.$2,
                              style: TextStyle(
                                color: active ? Colors.white : AppColors.secondary(context),
                                fontSize: 13,
                                fontWeight: FontWeight.w700,
                              )),
                          const SizedBox(width: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                            decoration: BoxDecoration(
                              color: active
                                  ? Colors.white.withOpacity(0.25)
                                  : AppColors.primary.withOpacity(0.1),
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Text('${t.$3}',
                                style: TextStyle(
                                  color: active ? Colors.white : AppColors.primary,
                                  fontSize: 11,
                                  fontWeight: FontWeight.w800,
                                )),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
            const SizedBox(height: 12),
            Expanded(
              child: current.isEmpty
                  ? _buildEmpty(l10n)
                  : RefreshIndicator(
                      onRefresh: () => ref.read(remindersProvider.notifier).refresh(),
                      child: ListView.builder(
                        padding: const EdgeInsets.fromLTRB(20, 0, 20, 100),
                        itemCount: current.length,
                        itemBuilder: (_, i) => _ReminderCard(reminder: current[i]),
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEmpty(AppL10n l10n) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 80,
            height: 80,
            decoration: BoxDecoration(
              color: AppColors.primary.withOpacity(0.08),
              borderRadius: BorderRadius.circular(24),
            ),
            child: const Icon(Icons.notifications_off_outlined,
                size: 36, color: AppColors.primary),
          ),
          const SizedBox(height: 16),
          Text(l10n.noReminder,
              style: TextStyle(
                  fontSize: 16, fontWeight: FontWeight.w700, color: AppColors.onSurface(context))),
          const SizedBox(height: 6),
          Text(l10n.noReminderDesc,
              style: TextStyle(fontSize: 13, color: AppColors.secondary(context))),
        ],
      ),
    );
  }
}

class _ReminderCard extends ConsumerWidget {
  final Reminder reminder;
  const _ReminderCard({required this.reminder});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = ref.watch(l10nProvider);

    Color priorityColor;
    switch (reminder.priority) {
      case 'very_important':
        priorityColor = AppColors.hot;
        break;
      case 'important':
        priorityColor = AppColors.warm;
        break;
      default:
        priorityColor = AppColors.success;
    }
    IconData actionIcon;
    switch (reminder.toDoAction) {
      case 'sms':
        actionIcon = Icons.sms_rounded;
        break;
      case 'whatsapp':
        actionIcon = Icons.chat_rounded;
        break;
      case 'email':
        actionIcon = Icons.email_rounded;
        break;
      default:
        actionIcon = Icons.phone_rounded;
    }

    final contacts = ref.watch(contactsProvider).contacts;
    final linked = contacts.where((c) => reminder.contactIds.contains(c.id)).toList();
    final contactLabel = linked.isEmpty
        ? l10n.contactDeleted
        : linked.length == 1
            ? linked.first.fullName
            : '${linked.first.fullName} +${linked.length - 1}';

    final dateLabel = DateFormat('dd MMM HH:mm').format(reminder.startDateTime);

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: AppColors.surfaceColor(context),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.borderColor(context)),
      ),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => ProviderScope(
                parent: ProviderScope.containerOf(context),
                child: ReminderDetailScreen(reminderId: reminder.id),
              ),
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Row(
              children: [
                Container(
                  width: 4,
                  height: 48,
                  decoration: BoxDecoration(
                      color: priorityColor, borderRadius: BorderRadius.circular(4)),
                ),
                const SizedBox(width: 12),
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: priorityColor.withOpacity(0.12),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(actionIcon, color: priorityColor, size: 20),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        reminder.note,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w700,
                            color: AppColors.onSurface(context)),
                      ),
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          Icon(Icons.person_outline_rounded,
                              size: 12, color: AppColors.hint(context)),
                          const SizedBox(width: 3),
                          Expanded(
                              child: Text(contactLabel,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                      fontSize: 11, color: AppColors.secondary(context)))),
                          const SizedBox(width: 8),
                          Icon(Icons.access_time_rounded,
                              size: 12, color: AppColors.hint(context)),
                          const SizedBox(width: 3),
                          Text(dateLabel,
                              style: TextStyle(fontSize: 11, color: AppColors.secondary(context))),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                GestureDetector(
                  onTap: () {
                    CalendarService.addReminderToCalendar(reminder);
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                          content: Text(l10n.addedToCalendar),
                          backgroundColor: AppColors.primary),
                    );
                  },
                  child: Container(
                    padding: const EdgeInsets.all(6),
                    decoration: BoxDecoration(
                        color: AppColors.primary.withOpacity(0.08),
                        borderRadius: BorderRadius.circular(8)),
                    child: const Icon(Icons.calendar_month_rounded,
                        size: 16, color: AppColors.primary),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

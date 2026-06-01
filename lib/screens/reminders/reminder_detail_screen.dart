import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import '../../core/l10n/app_l10n.dart';
import '../../core/theme/app_colors.dart';
import '../../models/contact.dart';
import '../../models/reminder.dart';
import '../../providers/contacts_provider.dart';
import '../../providers/reminders_provider.dart';
import '../../services/calendar_service.dart';
import '../../services/contact_actions.dart';
import 'create_reminder_screen.dart';

class ReminderDetailScreen extends ConsumerWidget {
  final String reminderId;
  const ReminderDetailScreen({super.key, required this.reminderId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = ref.watch(l10nProvider);
    final reminders = ref.watch(remindersProvider).reminders;
    Reminder? reminder;
    for (final r in reminders) {
      if (r.id == reminderId) {
        reminder = r;
        break;
      }
    }

    if (reminder == null) {
      return Scaffold(
        backgroundColor: AppColors.bg(context),
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.error_outline, size: 48, color: AppColors.hint(context)),
              const SizedBox(height: 16),
              Text(
                l10n.reminderNotFound,
                style: TextStyle(color: AppColors.onSurface(context)),
              ),
              const SizedBox(height: 16),
              ElevatedButton(
                onPressed: () => Navigator.pop(context),
                child: Text(l10n.back),
              ),
            ],
          ),
        ),
      );
    }
    final r = reminder;

    final contacts = ref.watch(contactsProvider).contacts;
    final linked = contacts.where((c) => r.contactIds.contains(c.id)).toList();

    Color priorityColor;
    String priorityLabel;
    switch (r.priority) {
      case 'very_important':
        priorityColor = AppColors.hot;
        priorityLabel = l10n.priorityVeryImportant;
        break;
      case 'important':
        priorityColor = AppColors.warm;
        priorityLabel = l10n.priorityImportant;
        break;
      default:
        priorityColor = AppColors.success;
        priorityLabel = l10n.priorityNormal;
    }

    IconData actionIcon;
    switch (r.toDoAction) {
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

    return Scaffold(
      backgroundColor: AppColors.bg(context),
      body: SingleChildScrollView(
        child: Column(
          children: [
            Container(
              padding: EdgeInsets.only(
                  top: MediaQuery.of(context).padding.top + 10,
                  left: 20,
                  right: 20,
                  bottom: 24),
              decoration: const BoxDecoration(
                gradient: AppColors.primaryGradient,
                borderRadius: BorderRadius.only(
                    bottomLeft: Radius.circular(28), bottomRight: Radius.circular(28)),
              ),
              child: Column(
                children: [
                  Row(
                    children: [
                      _iconButton(Icons.arrow_back, () => Navigator.pop(context)),
                      const Spacer(),
                      _iconButton(Icons.edit_rounded, () {
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => ProviderScope(
                              parent: ProviderScope.containerOf(context),
                              child: CreateReminderScreen(existing: r),
                            ),
                          ),
                        );
                      }),
                      const SizedBox(width: 8),
                      _iconButton(Icons.delete_outline,
                          () => _confirmDelete(context, ref, r, l10n)),
                    ],
                  ),
                  const SizedBox(height: 20),
                  Container(
                    width: 64,
                    height: 64,
                    decoration: BoxDecoration(
                      color: Colors.white.withOpacity(0.2),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(color: Colors.white.withOpacity(0.3), width: 2),
                    ),
                    child: Icon(actionIcon, color: Colors.white, size: 30),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    r.note,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                        color: Colors.white, fontSize: 18, fontWeight: FontWeight.w800),
                  ),
                  const SizedBox(height: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
                    decoration: BoxDecoration(
                        color: priorityColor.withOpacity(0.9),
                        borderRadius: BorderRadius.circular(20)),
                    child: Text(priorityLabel,
                        style: const TextStyle(
                            color: Colors.white, fontSize: 12, fontWeight: FontWeight.w700)),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                children: [
                  if (linked.isNotEmpty) ...[
                    _section(
                        context,
                        l10n.affectedContacts,
                        Column(
                          children: linked.map((c) => _contactRow(context, c)).toList(),
                        )),
                    const SizedBox(height: 12),
                  ],
                  _section(
                      context,
                      l10n.planningSection,
                      Column(children: [
                        _info(context, Icons.play_arrow_rounded, l10n.startLabel,
                            DateFormat('dd MMM yyyy HH:mm').format(r.startDateTime)),
                        if (r.endDateTime != null)
                          _info(context, Icons.stop_rounded, l10n.endLabel,
                              DateFormat('dd MMM yyyy HH:mm').format(r.endDateTime!)),
                        if (r.repeatFrequency != null)
                          _info(context, Icons.repeat_rounded, l10n.repeatLabel,
                              _repeatLabel(r.repeatFrequency!, l10n)),
                      ])),
                  const SizedBox(height: 12),
                  if (linked.length == 1)
                    _section(context, l10n.actionSection,
                        _actionButton(context, linked.first, r, l10n)),
                  if (linked.length == 1) const SizedBox(height: 12),
                  _section(
                      context,
                      l10n.statusSection,
                      Column(children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(
                              l10n.completedStatus,
                              style: TextStyle(
                                  fontSize: 14, color: AppColors.secondary(context)),
                            ),
                            Switch(
                              value: r.isCompleted,
                              onChanged: (v) {
                                if (v) {
                                  ref.read(remindersProvider.notifier).completeReminder(r.id);
                                } else {
                                  ref
                                      .read(remindersProvider.notifier)
                                      .updateReminder(r.copyWith(isCompleted: false));
                                }
                              },
                              activeColor: AppColors.success,
                            ),
                          ],
                        ),
                        const SizedBox(height: 4),
                        OutlinedButton.icon(
                          onPressed: () async {
                            await CalendarService.addReminderToCalendar(r);
                            if (context.mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                    content: Text(l10n.addedToCalendar),
                                    backgroundColor: AppColors.primary),
                              );
                            }
                          },
                          icon: const Icon(Icons.calendar_month_rounded, size: 18),
                          label: Text(l10n.addToCalendar),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: AppColors.primary,
                            side: const BorderSide(color: AppColors.primary),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                            minimumSize: const Size(double.infinity, 44),
                          ),
                        ),
                      ])),
                  const SizedBox(height: 40),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _iconButton(IconData icon, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
            color: Colors.white.withOpacity(0.15), borderRadius: BorderRadius.circular(12)),
        child: Icon(icon, color: Colors.white, size: 20),
      ),
    );
  }

  String _repeatLabel(String f, AppL10n l10n) {
    return l10n.formatRepeatFrequency(f);
  }

  Widget _section(BuildContext context, String title, Widget child) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surfaceColor(context),
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
              color: AppColors.primary.withOpacity(0.06),
              blurRadius: 16,
              offset: const Offset(0, 4))
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title.toUpperCase(),
            style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w800,
                letterSpacing: 1,
                color: AppColors.hint(context)),
          ),
          const SizedBox(height: 12),
          child,
        ],
      ),
    );
  }

  Widget _info(BuildContext context, IconData icon, String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Icon(icon, size: 16, color: AppColors.primary),
          const SizedBox(width: 10),
          Text(label, style: TextStyle(fontSize: 13, color: AppColors.secondary(context))),
          const Spacer(),
          Flexible(
            child: Text(
              value,
              textAlign: TextAlign.right,
              style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: AppColors.onSurface(context)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _contactRow(BuildContext context, Contact c) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          CircleAvatar(
            radius: 18,
            backgroundColor: AppColors.primary.withOpacity(0.12),
            child: Text(c.initials,
                style: const TextStyle(
                    fontSize: 12, fontWeight: FontWeight.w700, color: AppColors.primary)),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(c.fullName,
                    style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                        color: AppColors.onSurface(context))),
                if (c.phone != null)
                  Text(c.phone!,
                      style: TextStyle(fontSize: 12, color: AppColors.secondary(context))),
                if (c.email != null)
                  Text(c.email!,
                      style: TextStyle(fontSize: 12, color: AppColors.secondary(context))),
              ],
            ),
          ),
          GestureDetector(
            onTap: () => context.push('/contact/${c.id}'),
            child: Container(
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                  color: AppColors.primary.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(8)),
              child: const Icon(Icons.open_in_new_rounded, size: 16, color: AppColors.primary),
            ),
          ),
        ],
      ),
    );
  }

  Widget _actionButton(
      BuildContext context, Contact contact, Reminder reminder, AppL10n l10n) {
    Color color;
    IconData icon;
    String label;
    VoidCallback action;
    switch (reminder.toDoAction) {
      case 'sms':
        color = AppColors.primary;
        icon = Icons.sms_rounded;
        label = l10n.sendSms;
        action = () => ContactActions.sms(context, contact);
        break;
      case 'whatsapp':
        color = const Color(0xFF25D366);
        icon = Icons.chat_rounded;
        label = l10n.openWhatsapp;
        action = () => ContactActions.whatsapp(context, contact);
        break;
      case 'email':
        color = AppColors.warm;
        icon = Icons.email_rounded;
        label = l10n.sendEmail;
        action = () => ContactActions.email(context, contact);
        break;
      default:
        color = AppColors.success;
        icon = Icons.phone_rounded;
        label = l10n.callLabel;
        action = () => ContactActions.call(context, contact);
    }
    return ElevatedButton.icon(
      onPressed: action,
      icon: Icon(icon, size: 20),
      label: Text(label),
      style: ElevatedButton.styleFrom(
        backgroundColor: color,
        foregroundColor: Colors.white,
        minimumSize: const Size(double.infinity, 48),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        elevation: 0,
      ),
    );
  }

  void _confirmDelete(
      BuildContext context, WidgetRef ref, Reminder reminder, AppL10n l10n) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text(l10n.deleteReminderTitle,
            style: const TextStyle(fontWeight: FontWeight.w700)),
        content: Text(
          l10n.deleteReminderWarning,
          style: TextStyle(color: AppColors.secondary(context)),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(l10n.cancel)),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.hot, foregroundColor: Colors.white),
            child: Text(l10n.delete),
          ),
        ],
      ),
    );
    if (ok == true) {
      await ref.read(remindersProvider.notifier).deleteReminder(reminder.id);
      if (context.mounted) Navigator.pop(context);
    }
  }
}

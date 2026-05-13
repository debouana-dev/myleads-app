import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../core/theme/app_colors.dart';
import '../../core/l10n/app_l10n.dart';
import '../../models/contact.dart';
import '../../models/interaction.dart';
import '../../models/reminder.dart';
import '../../providers/contacts_provider.dart';
import '../../providers/organization_provider.dart';
import '../../services/contact_actions.dart';
import '../../services/photo_storage_service.dart';
import '../../services/storage_service.dart';
import 'package:qr_flutter/qr_flutter.dart';
import '../../providers/reminders_provider.dart';
import '../reminders/create_reminder_screen.dart';
import '../reminders/reminder_detail_screen.dart';

class ContactDetailScreen extends ConsumerStatefulWidget {
  final String contactId;

  const ContactDetailScreen({super.key, required this.contactId});

  @override
  ConsumerState<ContactDetailScreen> createState() =>
      _ContactDetailScreenState();
}

class _ContactDetailScreenState extends ConsumerState<ContactDetailScreen> {
  List<Interaction> _interactions = [];

  @override
  void initState() {
    super.initState();
    _loadInteractions();
  }

  Future<void> _loadInteractions() async {
    final list = await ref
        .read(contactsProvider.notifier)
        .getInteractions(widget.contactId);
    if (mounted) setState(() => _interactions = list);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = ref.watch(l10nProvider);
    final contact = ref.watch(contactByIdProvider(widget.contactId));

    if (contact == null) {
      return Scaffold(
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.error_outline,
                  size: 48, color: AppColors.hint(context)),
              const SizedBox(height: 16),
              Text(l10n.contactNotFound),
              const SizedBox(height: 16),
              ElevatedButton(
                onPressed: () => context.pop(),
                child: Text(l10n.back),
              ),
            ],
          ),
        ),
      );
    }

    final avatarColor = contact.avatarColor != null
        ? Color(int.parse(contact.avatarColor!))
        : AppColors.primary;

    final currentUser = StorageService.currentUser;
    final inOrg = currentUser?.organizationId != null;
    final isOwner = currentUser != null && contact.ownerId == currentUser.id;
    final canEditOthers = ref.watch(orgCanEditOthersProvider);
    // Org users: governed solely by the can_edit privilege (admin always true).
    // Solo users: can only touch their own contacts.
    final canEdit = inOrg ? canEditOthers : isOwner;

    return Scaffold(
      backgroundColor: AppColors.bg(context),
      body: SingleChildScrollView(
        child: Column(
          children: [
            // Hero Header
            Container(
              padding: EdgeInsets.only(
                top: MediaQuery.of(context).padding.top + 10,
                bottom: 32,
              ),
              decoration: const BoxDecoration(
                gradient: AppColors.primaryGradient,
                borderRadius: BorderRadius.only(
                  bottomLeft: Radius.circular(32),
                  bottomRight: Radius.circular(32),
                ),
              ),
              child: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 24),
                    child: Row(
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
                            child: const Icon(Icons.arrow_back,
                                color: Colors.white, size: 20),
                          ),
                        ),
                        const Spacer(),
                        GestureDetector(
                          onTap: () => _showActionsSheet(context, contact, canEdit: canEdit),
                          child: Container(
                            width: 40,
                            height: 40,
                            decoration: BoxDecoration(
                              color: Colors.white.withOpacity(0.12),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: const Icon(Icons.more_vert,
                                color: Colors.white, size: 20),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 20),
                  Container(
                    width: 80,
                    height: 80,
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: [avatarColor, avatarColor.withOpacity(0.7)],
                      ),
                      borderRadius: BorderRadius.circular(24),
                      border: Border.all(
                        color: Colors.white.withOpacity(0.2),
                        width: 3,
                      ),
                      image: contact.photoPath != null && !kIsWeb
                          ? DecorationImage(
                              image: FileImage(File(PhotoStorageService.resolveAbsolutePath(contact.photoPath)!)),
                              fit: BoxFit.cover,
                            )
                          : null,
                    ),
                    child: contact.photoPath == null || kIsWeb
                        ? Center(
                            child: Text(
                              contact.initials,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 32,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          )
                        : null,
                  ),
                  const SizedBox(height: 14),
                  Text(
                    contact.fullName,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 24,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  if (contact.subtitle.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(
                      contact.subtitle,
                      style: TextStyle(
                        color: Colors.white.withOpacity(0.6),
                        fontSize: 14,
                      ),
                    ),
                  ],
                  const SizedBox(height: 12),
                  _buildStatusChip(contact.status),
                ],
              ),
            ),

            // Action Buttons (functional)
            Padding(
              padding:
                  const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  _buildActionBtn(
                    context: context,
                    icon: const Icon(Icons.phone, size: 22),
                    label: l10n.callLabel,
                    color: AppColors.success,
                    onTap: () => ContactActions.call(context, contact),
                  ),
                  _buildActionBtn(
                    context: context,
                    icon: const Icon(Icons.sms, size: 22),
                    label: l10n.smsLabel,
                    color: AppColors.primary,
                    onTap: () => ContactActions.sms(context, contact),
                  ),
                  _buildActionBtn(
                    context: context,
                    // Official WhatsApp brand glyph (Font Awesome, per doc v7).
                    icon: const FaIcon(FontAwesomeIcons.whatsapp, size: 22),
                    label: l10n.whatsappLabel,
                    color: const Color(0xFF25D366),
                    onTap: () => ContactActions.whatsapp(context, contact),
                  ),
                  _buildActionBtn(
                    context: context,
                    icon: const Icon(Icons.email, size: 22),
                    label: l10n.emailActionLabel,
                    color: AppColors.warm,
                    onTap: () => ContactActions.email(context, contact),
                  ),
                  _buildActionBtn(
                    context: context,
                    icon: const Icon(Icons.share, size: 22),
                    label: l10n.shareButton,
                    color: AppColors.accent,
                    onTap: () => ContactActions.share(context, contact),
                  ),
                ],
              ),
            ),

            // Edit / Delete row — hidden when user lacks edit privilege
            if (canEdit)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: () =>
                            context.push('/contact/${contact.id}/edit'),
                        icon: const Icon(Icons.edit_outlined, size: 18),
                        label: Text(l10n.editButton),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: AppColors.primary,
                          side: const BorderSide(
                              color: AppColors.primary, width: 1.5),
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: () => _confirmDelete(contact),
                        icon: const Icon(Icons.delete_outline, size: 18),
                        label: Text(l10n.deleteButton),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: AppColors.hot,
                          side: const BorderSide(
                              color: AppColors.hot, width: 1.5),
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),

            // Information Section
            _buildSection(
              context: context,
              title: l10n.informationLabel,
              child: Column(
                children: [
                  if (contact.phone != null && contact.phone!.isNotEmpty)
                    _infoRow(context: context, label: l10n.phoneLabel, value: contact.phone!),
                  if (contact.email != null && contact.email!.isNotEmpty)
                    _infoRow(context: context, label: l10n.emailLabel, value: contact.email!),
                  if (contact.company != null && contact.company!.isNotEmpty)
                    _infoRow(context: context, label: l10n.companyLabel, value: contact.company!),
                  if (contact.source != null && contact.source!.isNotEmpty)
                    _infoRow(context: context, label: l10n.sourceLabel, value: contact.source!),
                ],
              ),
            ),

            // Projects Section
            if (_hasProjects(contact))
              _buildSection(
                context: context,
                title: l10n.projects,
                child: Column(
                  children: [
                    if (contact.project1 != null && contact.project1!.isNotEmpty) ...[
                      _infoRow(context: context, label: l10n.project1Label, value: contact.project1!),
                      if (contact.project1Budget != null && contact.project1Budget!.isNotEmpty)
                        _infoRow(context: context, label: l10n.budgetLabel, value: contact.project1Budget!),
                    ],
                    if (contact.project2 != null && contact.project2!.isNotEmpty) ...[
                      if (contact.project1 != null && contact.project1!.isNotEmpty)
                        const Divider(height: 16),
                      _infoRow(context: context, label: l10n.project2Label, value: contact.project2!),
                      if (contact.project2Budget != null && contact.project2Budget!.isNotEmpty)
                        _infoRow(context: context, label: l10n.budgetLabel, value: contact.project2Budget!),
                    ],
                  ],
                ),
              ),


            // QR Code Section
            _buildSection(
              context: context,
              title: l10n.qrCode,
              child: Center(
                child: QrImageView(
                  data: [
                    'Prénom: ${contact.firstName}',
                    'Nom: ${contact.lastName}',
                    'Fonction: ${contact.jobTitle ?? ""}',
                    'Société: ${contact.company ?? ""}',
                    'Téléphone: ${contact.phone ?? ""}',
                    'Source: ${contact.source ?? ""}',
                    'Projet 1: ${contact.project1 ?? ""}',
                    'Budget 1: ${contact.project1Budget ?? ""}',
                    'Projet 2: ${contact.project2 ?? ""}',
                    'Budget 2: ${contact.project2Budget ?? ""}',
                    'Tags: ${contact.tags.join(", ")}',
                    'Notes: ${contact.notes ?? ""}',
                  ].join('\n'),
                  version: QrVersions.auto,
                  size: 200,
                ),
              ),
            ),

            // Notes Section (shown before Rappels so users see the context first)
            if (contact.notes != null && contact.notes!.isNotEmpty)
              _buildSection(
                context: context,
                title: l10n.notesLabel,
                child: Text(
                  contact.notes!,
                  style: TextStyle(
                    fontSize: 13,
                    color: AppColors.secondary(context),
                    height: 1.6,
                  ),
                ),
              ),

            // Rappels Section — only incomplete reminders, max 3, ascending.
            // Header always shows a nav button to the full pending list.
            Builder(
              builder: (context) {
                final pending = ref
                    .watch(remindersProvider)
                    .getRemindersForContact(contact.id)
                    .where((r) => !r.isCompleted)
                    .take(3)
                    .toList();
                return _buildSection(
                  context: context,
                  title: l10n.reminderSection,
                  trailing: GestureDetector(
                    onTap: () => context.push(
                        '/contact/${contact.id}/reminders'),
                    child: const Icon(
                      Icons.arrow_forward_ios_rounded,
                      size: 16,
                      color: AppColors.accent,
                    ),
                  ),
                  child: pending.isEmpty
                      ? Text(
                          l10n.noPendingReminders,
                          style: TextStyle(
                            fontSize: 13,
                            fontStyle: FontStyle.italic,
                            color: AppColors.hint(context),
                          ),
                        )
                      : Column(
                          children: pending.map((reminder) {
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
                            return GestureDetector(
                              onTap: () => Navigator.push(
                                context,
                                MaterialPageRoute(
                                  builder: (_) => ProviderScope(
                                    parent: ProviderScope.containerOf(context),
                                    child: ReminderDetailScreen(
                                        reminderId: reminder.id),
                                  ),
                                ),
                              ),
                              child: Container(
                                margin: const EdgeInsets.only(bottom: 10),
                                padding: const EdgeInsets.all(14),
                                decoration: BoxDecoration(
                                  color: AppColors.bg(context),
                                  borderRadius: BorderRadius.circular(12),
                                  border: Border.all(
                                      color: AppColors.borderColor(context)),
                                ),
                                child: Row(
                                  children: [
                                    Container(
                                      width: 4,
                                      height: 40,
                                      decoration: BoxDecoration(
                                        color: priorityColor,
                                        borderRadius: BorderRadius.circular(2),
                                      ),
                                    ),
                                    const SizedBox(width: 12),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            reminder.note,
                                            style: TextStyle(
                                              fontSize: 13,
                                              fontWeight: FontWeight.w600,
                                              color: AppColors.onSurface(
                                                  context),
                                            ),
                                          ),
                                          const SizedBox(height: 2),
                                          Text(
                                            DateFormat("dd MMM yyyy HH:mm")
                                                .format(reminder.startDateTime),
                                            style: TextStyle(
                                              fontSize: 11,
                                              color: AppColors.hint(context),
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                    Icon(Icons.chevron_right,
                                        color: AppColors.hint(context),
                                        size: 18),
                                  ],
                                ),
                              ),
                            );
                          }).toList(),
                        ),
                );
              },
            ),
            // History Section — merge raw interactions with completed
            // reminders linked to this contact (doc v7). Shows 3 most
            // recent; "View all" opens the full history screen.
            Builder(builder: (_) {
              final remindersState = ref.watch(remindersProvider);
              final doneForContact = remindersState.doneReminders
                  .where((r) => r.contactIds.contains(contact.id))
                  .toList();

              final entries = <_HistoryEntry>[
                ..._interactions.map((i) => _HistoryEntry.fromInteraction(i, l10n)),
                ...doneForContact.map((r) => _HistoryEntry.fromReminder(r, l10n)),
              ]..sort((a, b) => b.date.compareTo(a.date));

              if (entries.isEmpty) return const SizedBox.shrink();

              final shown = entries.take(3).toList();
              final hasMore = entries.length > 3;

              return _buildSection(
                context: context,
                title: l10n.historyLabel,
                trailing: hasMore
                    ? GestureDetector(
                        onTap: () => context.push(
                            '/contact/${contact.id}/history'),
                        child: Text(
                          l10n.viewAll,
                          style: const TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                            color: AppColors.accent,
                          ),
                        ),
                      )
                    : null,
                child: Column(
                  children: shown.map((e) => _historyRow(context, e)).toList(),
                ),
              );
            }),

            const SizedBox(height: 40),
          ],
        ),
      ),
    );
  }

  bool _hasProjects(Contact contact) {
    return (contact.project1 != null && contact.project1!.isNotEmpty) ||
        (contact.project2 != null && contact.project2!.isNotEmpty);
  }

  Widget _buildStatusChip(String status) {
    final l10n = ref.read(l10nProvider);
    Color color;
    String label;
    switch (status) {
      case 'hot':
        color = AppColors.hot;
        label = l10n.hotStatus;
        break;
      case 'warm':
        color = AppColors.warm;
        label = l10n.warmStatus;
        break;
      default:
        color = AppColors.cold;
        label = l10n.coldStatus;
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      decoration: BoxDecoration(
        color: color.withOpacity(0.2),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w800,
          color: color,
          letterSpacing: 0.5,
        ),
      ),
    );
  }

  Widget _buildActionBtn({
    required BuildContext context,
    required Widget icon,
    required String label,
    required Color color,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Column(
        children: [
          Container(
            width: 52,
            height: 52,
            decoration: BoxDecoration(
              color: AppColors.surfaceColor(context),
              borderRadius: BorderRadius.circular(16),
              boxShadow: [
                BoxShadow(
                  color: AppColors.primary.withOpacity(0.08),
                  blurRadius: 20,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: Center(
              child: IconTheme(
                data: IconThemeData(color: color, size: 22),
                child: icon,
              ),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            label,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: AppColors.secondary(context),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSection({
    required BuildContext context,
    required String title,
    required Widget child,
    Widget? trailing,
  }) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 24, vertical: 7),
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: AppColors.surfaceColor(context),
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: AppColors.primary.withOpacity(0.08),
            blurRadius: 20,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                title.toUpperCase(),
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: AppColors.hint(context),
                  letterSpacing: 1,
                ),
              ),
              const Spacer(),
              if (trailing != null) trailing,
            ],
          ),
          const SizedBox(height: 14),
          child,
        ],
      ),
    );
  }

  Widget _infoRow({
    required BuildContext context,
    required String label,
    required String value,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label,
              style: TextStyle(fontSize: 13, color: AppColors.secondary(context))),
          Flexible(
            child: Text(
              value,
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: AppColors.onSurface(context),
              ),
              textAlign: TextAlign.right,
            ),
          ),
        ],
      ),
    );
  }

  Widget _historyRow(BuildContext context, _HistoryEntry entry) {
    Color dotColor;
    switch (entry.kind) {
      case _HistoryKind.reminderDone:
        dotColor = AppColors.accent;
        break;
      case _HistoryKind.edit:
        dotColor = AppColors.primary;
        break;
      case _HistoryKind.interaction:
        switch (entry.type) {
          case 'call':
            dotColor = AppColors.success;
            break;
          case 'email':
            dotColor = AppColors.warm;
            break;
          case 'meeting':
            dotColor = AppColors.accent;
            break;
          default:
            dotColor = AppColors.primary;
        }
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 10,
            height: 10,
            margin: const EdgeInsets.only(top: 5),
            decoration: BoxDecoration(
              color: dotColor,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      entry.label,
                      style: const TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        color: AppColors.primary,
                        letterSpacing: 0.3,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  entry.content,
                  style: TextStyle(
                      fontSize: 13, color: AppColors.onSurface(context)),
                ),
                const SizedBox(height: 2),
                Text(
                  DateFormat('dd MMM yyyy HH:mm').format(entry.date),
                  style: TextStyle(
                      fontSize: 11, color: AppColors.hint(context)),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  void _showActionsSheet(BuildContext context, Contact contact, {required bool canEdit}) {
    final l10n = ref.read(l10nProvider);
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: AppColors.borderColor(context),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 20),
            if (canEdit)
              ListTile(
                leading: const Icon(Icons.edit, color: AppColors.primary),
                title: Text(l10n.editButton),
                onTap: () {
                  Navigator.pop(ctx);
                  context.push('/contact/${contact.id}/edit');
                },
              ),
            ListTile(
              leading: const Icon(Icons.alarm_add_rounded, color: AppColors.accent),
              title: Text(l10n.newReminder),
              onTap: () {
                Navigator.pop(ctx);
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => ProviderScope(
                      parent: ProviderScope.containerOf(context),
                      child: CreateReminderScreen(
                          preselectedContactId: contact.id),
                    ),
                  ),
                );
              },
            ),
            ListTile(
              leading: const Icon(Icons.share, color: AppColors.primary),
              title: Text(l10n.shareButton),
              onTap: () {
                Navigator.pop(ctx);
                ContactActions.share(context, contact);
              },
            ),
            if (canEdit)
              ListTile(
                leading: const Icon(Icons.delete, color: AppColors.hot),
                title: Text(l10n.deleteButton,
                    style: const TextStyle(color: AppColors.hot)),
                onTap: () {
                  Navigator.pop(ctx);
                  _confirmDelete(contact);
                },
              ),
            SizedBox(height: MediaQuery.of(ctx).padding.bottom),
          ],
        ),
      ),
    );
  }

  Future<void> _confirmDelete(Contact contact) async {
    final l10n = ref.read(l10nProvider);
    final messenger = ScaffoldMessenger.of(context);
    final router = GoRouter.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      barrierDismissible: true,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
        ),
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: AppColors.hot.withOpacity(0.1),
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Icon(
                Icons.warning_amber_rounded,
                color: AppColors.hot,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                l10n.deleteContactTitle,
                style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
              ),
            ),
          ],
        ),
        content: Text(
          l10n.deleteContactMessage(contact.fullName),
          style: TextStyle(fontSize: 14, color: AppColors.secondary(context)),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            style: TextButton.styleFrom(
              foregroundColor: AppColors.secondary(context),
              padding:
                  const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
            ),
            child: Text(l10n.cancel),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.hot,
              foregroundColor: Colors.white,
              elevation: 0,
              padding:
                  const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
              ),
            ),
            child: Text(l10n.delete),
          ),
        ],
      ),
    );

    if (confirmed == true && mounted) {
      final err = await ref.read(contactsProvider.notifier).deleteContact(contact.id);
      if (!mounted) return;
      if (err != null) {
        messenger.showSnackBar(SnackBar(content: Text(err))); // pre-captured
      } else {
        router.pop(); // pre-captured
      }
    }
  }
}

/// Classifies a history row so the icon/colour and label stay consistent.
enum _HistoryKind { interaction, reminderDone, edit }

/// A unified history entry — either a persisted [Interaction] or a
/// completed [Reminder] linked to the current contact (doc v7).
class _HistoryEntry {
  final _HistoryKind kind;
  final String type;
  final String content;
  final String label;
  final DateTime date;

  const _HistoryEntry({
    required this.kind,
    required this.type,
    required this.content,
    required this.label,
    required this.date,
  });

  factory _HistoryEntry.fromInteraction(Interaction i, AppL10n l10n) {
    final isEdit = i.type == 'edit';
    return _HistoryEntry(
      kind: isEdit ? _HistoryKind.edit : _HistoryKind.interaction,
      type: i.type,
      content: i.content,
      label: isEdit ? l10n.modificationBadge : i.typeLabel.toUpperCase(),
      date: i.createdAt,
    );
  }

  factory _HistoryEntry.fromReminder(Reminder r, AppL10n l10n) {
    return _HistoryEntry(
      kind: _HistoryKind.reminderDone,
      type: 'reminder',
      content: r.note,
      label: l10n.completedReminderBadge,
      date: r.sortKey,
    );
  }
}



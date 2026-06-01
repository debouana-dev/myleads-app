import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/l10n/app_l10n.dart';
import '../../core/theme/app_colors.dart';
import '../../models/app_task.dart';
import '../../models/organization.dart';
import '../../providers/organization_provider.dart';
import '../../providers/tasks_provider.dart';
import '../../services/calendar_service.dart';
import '../../services/database_service.dart';
import '../../services/storage_service.dart';
import 'create_task_screen.dart';

class TaskDetailScreen extends ConsumerStatefulWidget {
  final String taskId;

  const TaskDetailScreen({super.key, required this.taskId});

  @override
  ConsumerState<TaskDetailScreen> createState() => _TaskDetailScreenState();
}

class _TaskDetailScreenState extends ConsumerState<TaskDetailScreen> {
  Map<String, OrgMember> _memberMap = {};
  bool _toggling = false;

  @override
  void initState() {
    super.initState();
    _loadMembers();
  }

  Future<void> _loadMembers() async {
    final orgId = StorageService.currentUser?.organizationId;
    if (orgId == null) return;
    final members = await DatabaseService.getMembersForOrganization(orgId);
    if (!mounted) return;
    setState(() {
      _memberMap = {for (final m in members) m.userId: m};
    });
  }

  OrgMember? _member(String userId) => _memberMap[userId];

  @override
  Widget build(BuildContext context) {
    final l10n = ref.watch(l10nProvider);
    final isSuspended = ref.watch(orgCurrentUserIsSuspendedProvider);

    if (isSuspended) {
      return Scaffold(
        backgroundColor: AppColors.bg(context),
        appBar: AppBar(
          backgroundColor: AppColors.bg(context),
          elevation: 0,
          leading: IconButton(
            icon: Icon(Icons.arrow_back_ios_new_rounded,
                color: AppColors.onSurface(context)),
            onPressed: () => context.pop(),
          ),
        ),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 80,
                  height: 80,
                  decoration: BoxDecoration(
                    color: AppColors.warning.withValues(alpha: 0.10),
                    borderRadius: BorderRadius.circular(24),
                  ),
                  child: const Icon(Icons.block_rounded,
                      size: 36, color: AppColors.warning),
                ),
                const SizedBox(height: 16),
                Text(l10n.taskSuspendedTitle,
                    style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                        color: AppColors.onSurface(context))),
                const SizedBox(height: 6),
                Text(l10n.taskSuspendedDesc,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                        fontSize: 13, color: AppColors.secondary(context))),
              ],
            ),
          ),
        ),
      );
    }

    final task = ref
        .watch(tasksProvider)
        .tasks
        .cast<AppTask?>()
        .firstWhere((t) => t?.id == widget.taskId, orElse: () => null);

    if (task == null) {
      return Scaffold(
        backgroundColor: AppColors.bg(context),
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.error_outline,
                  size: 48, color: AppColors.hint(context)),
              const SizedBox(height: 16),
              Text(l10n.taskNotFound,
                  style: TextStyle(color: AppColors.onSurface(context))),
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

    final user = StorageService.currentUser;
    final currentUserId = user?.id ?? '';
    final isAdminOrOwner =
        user?.orgRole == 'admin' || user?.orgRole == 'owner';
    final isCreator = task.createdByUserId == currentUserId;
    final isAssignee = task.assigneeUserIds.contains(currentUserId);
    final canEdit = isAdminOrOwner || isCreator;
    final canDelete = isAdminOrOwner;
    final canToggle = isAdminOrOwner || isCreator || isAssignee;

    final assignees = task.assigneeUserIds.map(_member).toList();
    // First assignee with contact info drives the action button.
    final primaryAssignee = assignees.firstWhere(
      (m) => m != null && (m.phone?.isNotEmpty == true || m.email?.isNotEmpty == true),
      orElse: () => assignees.isNotEmpty ? assignees.first : null,
    );
    final creator = _member(task.createdByUserId);

    Color priorityColor;
    String priorityLabel;
    switch (task.priority) {
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
    switch (task.toDoAction) {
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
            // ── Gradient header ──────────────────────────────────────────
            Container(
              padding: EdgeInsets.only(
                top: MediaQuery.of(context).padding.top + 10,
                left: 20,
                right: 20,
                bottom: 24,
              ),
              decoration: const BoxDecoration(
                gradient: AppColors.primaryGradient,
                borderRadius: BorderRadius.only(
                  bottomLeft: Radius.circular(28),
                  bottomRight: Radius.circular(28),
                ),
              ),
              child: Column(
                children: [
                  Row(
                    children: [
                      _iconBtn(
                          Icons.arrow_back, () => context.pop()),
                      const Spacer(),
                      if (canEdit)
                        _iconBtn(Icons.edit_rounded, () {
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => ProviderScope(
                                parent: ProviderScope.containerOf(context),
                                child: CreateTaskScreen(existing: task),
                              ),
                            ),
                          );
                        }),
                      if (canEdit) const SizedBox(width: 8),
                      if (canDelete)
                        _iconBtn(
                          Icons.delete_outline,
                          () => _confirmDelete(context, ref, task, l10n),
                        ),
                    ],
                  ),
                  const SizedBox(height: 20),
                  Container(
                    width: 64,
                    height: 64,
                    decoration: BoxDecoration(
                      color: Colors.white.withOpacity(0.2),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(
                          color: Colors.white.withOpacity(0.3), width: 2),
                    ),
                    child: Icon(actionIcon, color: Colors.white, size: 30),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    task.note,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 18,
                        fontWeight: FontWeight.w800),
                  ),
                  const SizedBox(height: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 5),
                    decoration: BoxDecoration(
                      color: priorityColor.withOpacity(0.9),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text(priorityLabel,
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 12,
                            fontWeight: FontWeight.w700)),
                  ),
                ],
              ),
            ),

            // ── Body ─────────────────────────────────────────────────────
            Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                children: [
                  // ── Assigned by ────────────────────────────────────
                  _sectionCard(
                    context,
                    l10n.assignedBy,
                    _memberRow(context, creator,
                        task.createdByUserId, l10n),
                  ),
                  const SizedBox(height: 12),

                  // ── Assigned to ────────────────────────────────────
                  _sectionCard(
                    context,
                    l10n.taskAssigneesLabel,
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        for (var i = 0; i < assignees.length; i++) ...[
                          _memberRow(
                            context,
                            assignees[i],
                            task.assigneeUserIds[i],
                            l10n,
                          ),
                          if (i < assignees.length - 1)
                            const SizedBox(height: 8),
                        ],
                        const SizedBox(height: 12),
                        _actionButton(context, task, primaryAssignee, l10n),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),

                  // ── Planning ───────────────────────────────────────
                  _sectionCard(
                    context,
                    l10n.planningSection,
                    Column(children: [
                      _infoRow(
                        context,
                        Icons.play_arrow_rounded,
                        l10n.startLabel,
                        DateFormat('dd MMM yyyy HH:mm')
                            .format(task.startDateTime),
                      ),
                      if (task.endDateTime != null)
                        _infoRow(
                          context,
                          Icons.stop_rounded,
                          l10n.endLabel,
                          DateFormat('dd MMM yyyy HH:mm')
                              .format(task.endDateTime!),
                        ),
                      if (task.repeatFrequency != null)
                        _infoRow(
                          context,
                          Icons.repeat_rounded,
                          l10n.repeatLabel,
                          _repeatLabel(task.repeatFrequency!, l10n),
                        ),
                    ]),
                  ),
                  const SizedBox(height: 12),

                  // ── Status ─────────────────────────────────────────
                  _sectionCard(
                    context,
                    l10n.statusSection,
                    Column(children: [
                      if (canToggle)
                        Row(
                          mainAxisAlignment:
                              MainAxisAlignment.spaceBetween,
                          children: [
                            Text(
                              task.isCompleted
                                  ? l10n.uncompleteTask
                                  : l10n.completeTask,
                              style: TextStyle(
                                  fontSize: 14,
                                  color: AppColors.secondary(context)),
                            ),
                            _toggling
                                ? const SizedBox(
                                    width: 28,
                                    height: 28,
                                    child: CircularProgressIndicator(
                                        strokeWidth: 2),
                                  )
                                : Switch(
                                    value: task.isCompleted,
                                    onChanged: (v) =>
                                        _toggleComplete(
                                            context, ref, task, v,
                                            currentUserId, l10n),
                                    activeColor: AppColors.success,
                                  ),
                          ],
                        ),
                      if (task.isCompleted &&
                          task.completedByUserId != null) ...[
                        const SizedBox(height: 4),
                        Row(
                          children: [
                            Icon(Icons.check_circle_outline_rounded,
                                size: 14, color: AppColors.success),
                            const SizedBox(width: 6),
                            Text(
                              '${l10n.taskCompletedBy}: ${_member(task.completedByUserId!)?.fullName ?? task.completedByUserId!}',
                              style: TextStyle(
                                  fontSize: 12,
                                  color: AppColors.secondary(context)),
                            ),
                          ],
                        ),
                      ],
                      const SizedBox(height: 12),
                      OutlinedButton.icon(
                        onPressed: () async {
                          await CalendarService.addTaskToCalendar(task);
                          if (context.mounted) {
                            ScaffoldMessenger.of(context)
                                .showSnackBar(SnackBar(
                              content: Text(l10n.addedToCalendar),
                              backgroundColor: AppColors.primary,
                            ));
                          }
                        },
                        icon: const Icon(Icons.calendar_month_rounded,
                            size: 18),
                        label: Text(l10n.addToCalendar),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: AppColors.primary,
                          side: const BorderSide(color: AppColors.primary),
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(10)),
                          minimumSize: const Size(double.infinity, 44),
                        ),
                      ),
                    ]),
                  ),
                  const SizedBox(height: 40),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── Helpers ──────────────────────────────────────────────────────────────

  Widget _memberRow(BuildContext context, OrgMember? member,
      String fallbackId, AppL10n l10n) {
    final name = member?.fullName ?? fallbackId;
    final role = member?.role ?? '';
    final initials = member != null
        ? _initials(member.firstName, member.lastName)
        : '?';

    return Row(
      children: [
        CircleAvatar(
          radius: 20,
          backgroundColor: AppColors.primary.withOpacity(0.12),
          child: Text(initials,
              style: const TextStyle(
                  color: AppColors.primary, fontWeight: FontWeight.w700)),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Text(name,
              style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  color: AppColors.onSurface(context))),
        ),
        if (role.isNotEmpty)
          Container(
            padding:
                const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: AppColors.primary.withOpacity(0.1),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(role,
                style: const TextStyle(
                    color: AppColors.primary,
                    fontSize: 11,
                    fontWeight: FontWeight.w700)),
          ),
      ],
    );
  }

  Widget _actionButton(BuildContext context, AppTask task,
      OrgMember? assignee, AppL10n l10n) {
    final String rawPhone = assignee?.phone ?? '';
    final String rawEmail = assignee?.email ?? '';

    void showMissingInfo(String msg) =>
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(msg),
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 2),
        ));

    Color color;
    IconData icon;
    String label;
    VoidCallback action;
    bool missingInfo;

    switch (task.toDoAction) {
      case 'sms':
        color = AppColors.primary;
        icon = Icons.sms_rounded;
        label = l10n.sendSms;
        missingInfo = rawPhone.isEmpty;
        action = missingInfo
            ? () => showMissingInfo(l10n.taskAssigneeNoPhone)
            : () => _launch(Uri(scheme: 'sms', path: _cleanPhone(rawPhone)));
        break;
      case 'whatsapp':
        color = const Color(0xFF25D366);
        icon = Icons.chat_rounded;
        label = l10n.openWhatsapp;
        final digits = rawPhone.replaceAll(RegExp(r'[^0-9]'), '');
        missingInfo = digits.isEmpty;
        action = missingInfo
            ? () => showMissingInfo(l10n.taskAssigneeNoPhone)
            : () => _launch(Uri.parse('https://wa.me/$digits'),
                mode: LaunchMode.externalApplication);
        break;
      case 'email':
        color = AppColors.warm;
        icon = Icons.email_rounded;
        label = l10n.sendEmail;
        missingInfo = rawEmail.isEmpty;
        action = missingInfo
            ? () => showMissingInfo(l10n.taskAssigneeNoEmail)
            : () => _launch(Uri(scheme: 'mailto', path: rawEmail));
        break;
      default:
        color = AppColors.success;
        icon = Icons.phone_rounded;
        label = l10n.callLabel;
        missingInfo = rawPhone.isEmpty;
        action = missingInfo
            ? () => showMissingInfo(l10n.taskAssigneeNoPhone)
            : () => _launch(Uri(scheme: 'tel', path: _cleanPhone(rawPhone)));
    }

    return Opacity(
      opacity: missingInfo ? 0.55 : 1.0,
      child: ElevatedButton.icon(
        onPressed: action,
        icon: Icon(icon, size: 20),
        label: Text(label),
        style: ElevatedButton.styleFrom(
          backgroundColor: color,
          foregroundColor: Colors.white,
          minimumSize: const Size(double.infinity, 48),
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12)),
          elevation: 0,
        ),
      ),
    );
  }

  Future<void> _launch(Uri uri,
      {LaunchMode mode = LaunchMode.platformDefault}) async {
    try {
      await launchUrl(uri, mode: mode);
    } catch (_) {}
  }

  String _cleanPhone(String p) => p.replaceAll(RegExp(r'[\s\-()]'), '');

  Widget _iconBtn(IconData icon, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(0.15),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Icon(icon, color: Colors.white, size: 20),
      ),
    );
  }

  Widget _sectionCard(
      BuildContext context, String title, Widget child) {
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
            offset: const Offset(0, 4),
          ),
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
              color: AppColors.hint(context),
            ),
          ),
          const SizedBox(height: 12),
          child,
        ],
      ),
    );
  }

  Widget _infoRow(BuildContext context, IconData icon, String label,
      String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Icon(icon, size: 16, color: AppColors.primary),
          const SizedBox(width: 10),
          Text(label,
              style: TextStyle(
                  fontSize: 13, color: AppColors.secondary(context))),
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

  String _repeatLabel(String f, AppL10n l10n) {
    return l10n.formatRepeatFrequency(f);
  }

  String _initials(String first, String last) {
    final f = first.isNotEmpty ? first[0].toUpperCase() : '';
    final l = last.isNotEmpty ? last[0].toUpperCase() : '';
    return '$f$l';
  }

  Future<void> _toggleComplete(
    BuildContext context,
    WidgetRef ref,
    AppTask task,
    bool markDone,
    String currentUserId,
    AppL10n l10n,
  ) async {
    setState(() => _toggling = true);
    try {
      if (markDone) {
        await ref
            .read(tasksProvider.notifier)
            .completeTask(task.id, currentUserId);
      } else {
        await ref
            .read(tasksProvider.notifier)
            .uncompleteTask(task.id);
      }
    } finally {
      if (mounted) setState(() => _toggling = false);
    }
  }

  Future<void> _confirmDelete(BuildContext context, WidgetRef ref,
      AppTask task, AppL10n l10n) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text(l10n.deleteTaskTitle,
            style: const TextStyle(fontWeight: FontWeight.w700)),
        content: Text(l10n.deleteTaskWarning,
            style: TextStyle(color: AppColors.secondary(context))),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(l10n.cancel)),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.hot,
                foregroundColor: Colors.white),
            child: Text(l10n.delete),
          ),
        ],
      ),
    );
    if (ok == true) {
      await ref.read(tasksProvider.notifier).deleteTask(task.id);
      if (context.mounted) context.pop();
    }
  }
}

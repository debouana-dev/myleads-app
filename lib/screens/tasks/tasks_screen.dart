import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../core/l10n/app_l10n.dart';
import '../../core/theme/app_colors.dart';
import '../../models/app_task.dart';
import '../../models/organization.dart';
import '../../providers/organization_provider.dart';
import '../../providers/tasks_provider.dart';
import '../../services/calendar_service.dart';
import '../../services/database_service.dart';
import '../../services/storage_service.dart';

class TasksScreen extends ConsumerStatefulWidget {
  const TasksScreen({super.key});

  @override
  ConsumerState<TasksScreen> createState() => _TasksScreenState();
}

class _TasksScreenState extends ConsumerState<TasksScreen> {
  String _activeTab = 'pending';
  bool _scopeAll = true;
  Map<String, OrgMember> _memberMap = {};
  bool _loadComplete = false;
  bool _isRefreshing = false;

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  Future<void> _loadData() async {
    final user = StorageService.currentUser;
    final orgId = user?.organizationId;
    if (user == null || orgId == null) {
      // initState runs before the widget is mounted, so mounted is false here.
      // addPostFrameCallback defers the setState until after the first frame.
      WidgetsBinding.instance.addPostFrameCallback(
          (_) { if (mounted) setState(() => _loadComplete = true); });
      return;
    }

    // Load tasks from local DB. Timeout guards against a locked sqflite queue.
    try {
      await ref.read(tasksProvider.notifier)
          .loadTasksForOrg(orgId)
          .timeout(const Duration(seconds: 5));
    } catch (_) {}

    // Tasks are ready (or timed out); show the list immediately.
    if (mounted) setState(() => _loadComplete = true);

    // Member names (assignee display) and cloud sync are non-critical — fire and forget.
    _loadMemberNames(orgId);
    ref.read(tasksProvider.notifier).syncSilently(orgId, user.id);
  }

  Future<void> _loadMemberNames(String orgId) async {
    try {
      final members = await DatabaseService.getMembersForOrganization(orgId);
      if (mounted) {
        setState(() => _memberMap = {for (final m in members) m.userId: m});
      }
    } catch (_) {}
  }

  Future<void> _onRefresh() async {
    final user = StorageService.currentUser;
    final orgId = user?.organizationId;
    if (orgId == null || !mounted) return;
    setState(() => _isRefreshing = true);
    try {
      await ref.read(tasksProvider.notifier).syncAndLoad(orgId, user!.id);
    } finally {
      if (mounted) setState(() => _isRefreshing = false);
    }
    _loadMemberNames(orgId);
  }

  OrgMember? _member(String userId) => _memberMap[userId];

  @override
  Widget build(BuildContext context) {
    final l10n = ref.watch(l10nProvider);
    final isSuspended = ref.watch(orgCurrentUserIsSuspendedProvider);
    final canViewOthers = ref.watch(orgCanViewOthersTasksProvider);
    final state = ref.watch(tasksProvider);

    final currentUserId = StorageService.currentUserId;
    // Members without the "view team tasks" privilege always see only their own tasks.
    final effectiveScopeAll = canViewOthers && _scopeAll;
    final pendingList = effectiveScopeAll
        ? state.pendingTasks
        : state.myAssignedTasks(currentUserId);
    final completedList = effectiveScopeAll
        ? state.completedTasks
        : state.completedTasksForUser(currentUserId);
    final current = _activeTab == 'done' ? completedList : pendingList;

    return Scaffold(
      backgroundColor: AppColors.bg(context),
      floatingActionButton: isSuspended
          ? null
          : Padding(
        padding:
            EdgeInsets.only(bottom: 16 + MediaQuery.of(context).padding.bottom),
        child: FloatingActionButton.extended(
          backgroundColor: AppColors.primary,
          foregroundColor: Colors.white,
          onPressed: () => context.push('/organization/tasks/new'),
          icon: const Icon(Icons.add_rounded),
          label: Text(l10n.newTask,
              style: const TextStyle(fontWeight: FontWeight.w700)),
        ),
      ),
      body: SafeArea(
        child: Column(
          children: [
            // ── Header ────────────────────────────────────────────────────
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
              child: Row(
                children: [
                  GestureDetector(
                    onTap: () => context.pop(),
                    child: Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        color: AppColors.surfaceColor(context),
                        borderRadius: BorderRadius.circular(12),
                        border:
                            Border.all(color: AppColors.borderColor(context)),
                      ),
                      child: Icon(Icons.arrow_back_ios_new_rounded,
                          size: 18, color: AppColors.onSurface(context)),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      gradient: AppColors.primaryGradient,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Icon(Icons.task_alt_rounded,
                        color: Colors.white),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(l10n.tasksTitle,
                            style: TextStyle(
                                fontSize: 22,
                                fontWeight: FontWeight.w800,
                                color: AppColors.onSurface(context))),
                        Text(l10n.tasksSection,
                            style: TextStyle(
                                fontSize: 13,
                                color: AppColors.secondary(context))),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),

            // ── Scope toggle (Mine / All) — only for permitted members ────
            if (canViewOthers) ...[
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Row(
                  children: [
                    _ScopeChip(
                      label: l10n.myTasks,
                      active: !_scopeAll,
                      onTap: () => setState(() => _scopeAll = false),
                    ),
                    const SizedBox(width: 8),
                    _ScopeChip(
                      label: l10n.allTasks,
                      active: _scopeAll,
                      onTap: () => setState(() => _scopeAll = true),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 10),
            ],

            // ── Tabs ──────────────────────────────────────────────────────
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Row(
                children: [
                  _Tab(
                    label: l10n.taskPending,
                    count: pendingList.length,
                    active: _activeTab == 'pending',
                    onTap: () => setState(() => _activeTab = 'pending'),
                  ),
                  const SizedBox(width: 8),
                  _Tab(
                    label: l10n.taskCompletedTab,
                    count: completedList.length,
                    active: _activeTab == 'done',
                    onTap: () => setState(() => _activeTab = 'done'),
                    completedStyle: true,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),

            // ── List ──────────────────────────────────────────────────────
            Expanded(
              child: isSuspended
                  ? _buildSuspendedNotice(l10n)
                  : !_loadComplete
                  ? const Center(child: CircularProgressIndicator(color: AppColors.primary))
                  : RefreshIndicator(
                      onRefresh: _onRefresh,
                      child: current.isEmpty
                          ? ListView(
                              physics: const AlwaysScrollableScrollPhysics(),
                              children: [
                                SizedBox(height: 300, child: _buildEmpty(l10n)),
                              ],
                            )
                          : ListView.builder(
                              physics: const AlwaysScrollableScrollPhysics(),
                              padding:
                                  const EdgeInsets.fromLTRB(20, 0, 20, 80),
                              itemCount: current.length,
                              itemBuilder: (_, i) => _TaskCard(
                                task: current[i],
                                assignees: current[i]
                                    .assigneeUserIds
                                    .map(_member)
                                    .toList(),
                              ),
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
            child: const Icon(Icons.task_alt_rounded,
                size: 36, color: AppColors.primary),
          ),
          const SizedBox(height: 16),
          Text(l10n.noTask,
              style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  color: AppColors.onSurface(context))),
          const SizedBox(height: 6),
          Text(l10n.noTaskDesc,
              textAlign: TextAlign.center,
              style:
                  TextStyle(fontSize: 13, color: AppColors.secondary(context))),
        ],
      ),
    );
  }

  Widget _buildSuspendedNotice(AppL10n l10n) {
    return Center(
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
    );
  }
}

// ── Scope chip (Mine / All) ───────────────────────────────────────────────────

class _ScopeChip extends StatelessWidget {
  final String label;
  final bool active;
  final VoidCallback onTap;

  const _ScopeChip({
    required this.label,
    required this.active,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
        decoration: BoxDecoration(
          color: active ? AppColors.primary : AppColors.surfaceColor(context),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: active ? AppColors.primary : AppColors.borderColor(context),
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w700,
            color: active ? Colors.white : AppColors.secondary(context),
          ),
        ),
      ),
    );
  }
}

// ── Tab chip ────────────────────────────────────────────────────────────────

class _Tab extends StatelessWidget {
  final String label;
  final int count;
  final bool active;
  final bool completedStyle;
  final VoidCallback onTap;

  const _Tab({
    required this.label,
    required this.count,
    required this.active,
    required this.onTap,
    this.completedStyle = false,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        decoration: BoxDecoration(
          gradient: active
              ? (completedStyle
                  ? AppColors.hotGradient
                  : AppColors.primaryGradient)
              : null,
          color: active ? null : AppColors.surfaceColor(context),
          borderRadius: BorderRadius.circular(22),
          border: active ? null : Border.all(color: AppColors.borderColor(context)),
        ),
        child: Row(
          children: [
            Text(label,
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
              child: Text('$count',
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
  }
}

// ── Task card ────────────────────────────────────────────────────────────────

class _TaskCard extends ConsumerWidget {
  final AppTask task;
  final List<OrgMember?> assignees;

  const _TaskCard({required this.task, required this.assignees});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = ref.watch(l10nProvider);

    Color priorityColor;
    switch (task.priority) {
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

    final dateLabel = DateFormat('dd MMM HH:mm').format(task.startDateTime);

    // Assignee display: single shows name + role badge; multi shows stacked avatars.
    final displayCount = assignees.length;
    final visibleAssignees = assignees.take(2).toList();
    final overflow = displayCount > 2 ? displayCount - 2 : 0;

    final singleAssignee = displayCount == 1 ? assignees.first : null;
    final roleLabel = singleAssignee?.role ?? '';

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
          onTap: () => context.push('/organization/task/${task.id}'),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Priority bar
                Container(
                  width: 4,
                  height: 56,
                  decoration: BoxDecoration(
                    color: priorityColor,
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
                const SizedBox(width: 12),
                // Action icon
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
                // Content
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        task.note,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                          color: AppColors.onSurface(context),
                        ),
                      ),
                      const SizedBox(height: 6),
                      // Assignee row
                      Row(
                        children: [
                          // Stacked avatars (max 2 visible)
                          SizedBox(
                            width: visibleAssignees.length == 1
                                ? 22.0
                                : (14.0 * visibleAssignees.length + 8.0),
                            height: 22,
                            child: Stack(
                              children: [
                                for (var i = 0;
                                    i < visibleAssignees.length;
                                    i++)
                                  Positioned(
                                    left: i * 14.0,
                                    child: Container(
                                      width: 22,
                                      height: 22,
                                      decoration: BoxDecoration(
                                        gradient: AppColors.primaryGradient,
                                        shape: BoxShape.circle,
                                        border: Border.all(
                                          color:
                                              AppColors.surfaceColor(context),
                                          width: 1.5,
                                        ),
                                      ),
                                      child: Center(
                                        child: Text(
                                          visibleAssignees[i] != null
                                              ? _initials(
                                                  visibleAssignees[i]!
                                                      .firstName,
                                                  visibleAssignees[i]!
                                                      .lastName)
                                              : '?',
                                          style: const TextStyle(
                                              color: Colors.white,
                                              fontSize: 7,
                                              fontWeight: FontWeight.w800),
                                        ),
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                          if (overflow > 0) ...[
                            const SizedBox(width: 3),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 5, vertical: 1),
                              decoration: BoxDecoration(
                                color: AppColors.primary.withOpacity(0.12),
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Text('+$overflow',
                                  style: const TextStyle(
                                      color: AppColors.primary,
                                      fontSize: 9,
                                      fontWeight: FontWeight.w800)),
                            ),
                          ],
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              displayCount == 1
                                  ? (singleAssignee?.fullName ??
                                      (task.assigneeUserIds.isNotEmpty
                                          ? task.assigneeUserIds.first
                                          : ''))
                                  : l10n.taskAssigneesCount(displayCount),
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w600,
                                  color: AppColors.onSurface(context)),
                            ),
                          ),
                          if (displayCount == 1 && roleLabel.isNotEmpty) ...[
                            const SizedBox(width: 4),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 6, vertical: 2),
                              decoration: BoxDecoration(
                                color: AppColors.primary.withOpacity(0.1),
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: Text(roleLabel,
                                  style: const TextStyle(
                                      color: AppColors.primary,
                                      fontSize: 9,
                                      fontWeight: FontWeight.w700)),
                            ),
                          ],
                        ],
                      ),
                      const SizedBox(height: 4),
                      // Date row
                      Row(
                        children: [
                          Icon(Icons.access_time_rounded,
                              size: 12, color: AppColors.hint(context)),
                          const SizedBox(width: 3),
                          Text(dateLabel,
                              style: TextStyle(
                                  fontSize: 11,
                                  color: AppColors.secondary(context))),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                // Calendar button
                GestureDetector(
                  onTap: () {
                    CalendarService.addTaskToCalendar(task);
                    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                      content: Text(l10n.addedToCalendar),
                      backgroundColor: AppColors.primary,
                    ));
                  },
                  child: Container(
                    padding: const EdgeInsets.all(6),
                    decoration: BoxDecoration(
                      color: AppColors.primary.withOpacity(0.08),
                      borderRadius: BorderRadius.circular(8),
                    ),
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

  String _initials(String first, String last) {
    final f = first.isNotEmpty ? first[0].toUpperCase() : '';
    final l = last.isNotEmpty ? last[0].toUpperCase() : '';
    return '$f$l';
  }
}

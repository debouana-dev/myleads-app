import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../core/l10n/app_l10n.dart';
import '../../core/theme/app_colors.dart';
import '../../models/app_task.dart';
import '../../models/organization.dart';
import '../../providers/tasks_provider.dart';
import '../../services/database_service.dart';
import '../../services/storage_service.dart';

class CreateTaskScreen extends ConsumerStatefulWidget {
  final AppTask? existing;

  const CreateTaskScreen({super.key, this.existing});

  @override
  ConsumerState<CreateTaskScreen> createState() => _CreateTaskScreenState();
}

class _CreateTaskScreenState extends ConsumerState<CreateTaskScreen> {
  final _formKey = GlobalKey<FormState>();
  final _noteCtrl = TextEditingController();

  List<OrgMember> _activeMembers = [];
  List<OrgMember> _selectedAssignees = [];
  bool _isAdminOrOwner = false;
  bool _membersLoaded = false;

  DateTime _startDateTime =
      DateTime.now().add(const Duration(hours: 1));
  DateTime? _endDateTime;
  String? _repeatFrequency;
  int _customRepeatValue = 1;
  String _customRepeatUnit = 'd';
  String _toDoAction = 'call';
  String _priority = 'normal';
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    if (e != null) {
      _startDateTime = e.startDateTime;
      _endDateTime = e.endDateTime;
      _repeatFrequency = e.repeatFrequency;
      _toDoAction = e.toDoAction;
      _priority = e.priority;
      _noteCtrl.text = e.note;

      if (_repeatFrequency != null &&
          !['30m', '1h', '1d', '1w', '1mo'].contains(_repeatFrequency)) {
        final match =
            RegExp(r'^(\d+)(m|h|d|w|mo)$').firstMatch(_repeatFrequency!);
        if (match != null) {
          _customRepeatValue = int.tryParse(match.group(1)!) ?? 1;
          _customRepeatUnit = match.group(2)!;
          _repeatFrequency = 'custom';
        }
      }
    }
    _loadMembers();
  }

  @override
  void dispose() {
    _noteCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadMembers() async {
    final user = StorageService.currentUser;
    if (user == null) return;

    _isAdminOrOwner =
        user.orgRole == 'admin' || user.orgRole == 'owner';
    final orgId = user.organizationId;
    if (orgId == null) return;

    final members = await DatabaseService.getMembersForOrganization(orgId);

    final isSuspended =
        members.any((m) => m.userId == user.id && m.status == 'suspended');
    if (isSuspended) {
      if (!mounted) return;
      final l10n = ref.read(l10nProvider);
      context.pop();
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(l10n.taskSuspendedTitle),
        backgroundColor: AppColors.warning,
      ));
      return;
    }

    final active =
        members.where((m) => m.status == 'active').toList();

    List<OrgMember> selected = [];
    if (widget.existing != null) {
      final existingIds = widget.existing!.assigneeUserIds.toSet();
      selected = active.where((m) => existingIds.contains(m.userId)).toList();
    }
    // Regular members default to self; admins start with no pre-selection on new tasks.
    if (selected.isEmpty && !_isAdminOrOwner) {
      final self = active.where((m) => m.userId == user.id).firstOrNull;
      if (self != null) selected = [self];
    }

    if (!mounted) return;
    setState(() {
      _activeMembers = active;
      _selectedAssignees = selected;
      _membersLoaded = true;
    });
  }

  Future<void> _pickDate({required bool isStart}) async {
    final base = isStart
        ? _startDateTime
        : (_endDateTime ?? _startDateTime.add(const Duration(hours: 1)));
    final date = await showDatePicker(
      context: context,
      initialDate: base,
      firstDate: DateTime.now().subtract(const Duration(days: 365)),
      lastDate: DateTime.now().add(const Duration(days: 365 * 5)),
    );
    if (date == null || !mounted) return;
    final time = await showTimePicker(
        context: context, initialTime: TimeOfDay.fromDateTime(base));
    if (time == null) return;
    final dt = DateTime(
        date.year, date.month, date.day, time.hour, time.minute);
    setState(() {
      if (isStart) {
        _startDateTime = dt;
        if (_endDateTime != null && _endDateTime!.isBefore(dt)) {
          _endDateTime = null;
        }
      } else {
        _endDateTime = dt;
      }
    });
  }

  void _pickMembers(AppL10n l10n) {
    if (!_isAdminOrOwner) return;
    // Local copy committed only when user taps "Done".
    final sheetSelected = List<OrgMember>.from(_selectedAssignees);

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => StatefulBuilder(
        builder: (ctx, setSheetState) {
          return Container(
            height: MediaQuery.of(context).size.height * 0.65,
            decoration: BoxDecoration(
              color: AppColors.surfaceColor(context),
              borderRadius:
                  const BorderRadius.vertical(top: Radius.circular(24)),
            ),
            child: Column(
              children: [
                Container(
                  width: 40,
                  height: 4,
                  margin: const EdgeInsets.only(top: 10),
                  decoration: BoxDecoration(
                    color: AppColors.borderColor(context),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 8, 0),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          l10n.taskSelectAssignees,
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                            color: AppColors.onSurface(context),
                          ),
                        ),
                      ),
                      TextButton(
                        onPressed: () {
                          setState(() => _selectedAssignees =
                              List.from(sheetSelected));
                          Navigator.pop(ctx);
                        },
                        child: Text(
                          l10n.done,
                          style: const TextStyle(
                              color: AppColors.primary,
                              fontWeight: FontWeight.w700),
                        ),
                      ),
                    ],
                  ),
                ),
                if (sheetSelected.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 2, 16, 4),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        l10n.taskAssigneesCount(sheetSelected.length),
                        style: TextStyle(
                            fontSize: 12,
                            color: AppColors.secondary(context)),
                      ),
                    ),
                  ),
                Expanded(
                  child: _activeMembers.isEmpty
                      ? Center(
                          child: Text(
                            l10n.noMembersAvailable,
                            style: TextStyle(
                                color: AppColors.secondary(context)),
                          ),
                        )
                      : ListView.builder(
                          itemCount: _activeMembers.length,
                          itemBuilder: (_, i) {
                            final m = _activeMembers[i];
                            final sel = sheetSelected
                                .any((s) => s.userId == m.userId);
                            return ListTile(
                              leading: CircleAvatar(
                                backgroundColor:
                                    AppColors.primary.withOpacity(0.12),
                                child: Text(
                                  _initials(m.firstName, m.lastName),
                                  style: const TextStyle(
                                      color: AppColors.primary,
                                      fontWeight: FontWeight.w700),
                                ),
                              ),
                              title: Text(m.fullName,
                                  style: TextStyle(
                                      color: AppColors.onSurface(context),
                                      fontWeight: FontWeight.w600)),
                              subtitle: Text(m.role,
                                  style: TextStyle(
                                      color: AppColors.secondary(context),
                                      fontSize: 12)),
                              trailing: sel
                                  ? const Icon(Icons.check_box_rounded,
                                      color: AppColors.primary)
                                  : Icon(
                                      Icons.check_box_outline_blank_rounded,
                                      color: AppColors.hint(context)),
                              onTap: () {
                                setSheetState(() {
                                  if (sel) {
                                    sheetSelected.removeWhere(
                                        (s) => s.userId == m.userId);
                                  } else {
                                    sheetSelected.add(m);
                                  }
                                });
                              },
                            );
                          },
                        ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Future<void> _save(AppL10n l10n) async {
    if (!_formKey.currentState!.validate()) return;
    if (_selectedAssignees.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(l10n.taskNoAssigneeSelected),
        backgroundColor: AppColors.hot,
      ));
      return;
    }
    setState(() => _saving = true);
    try {
      final freq = _repeatFrequency == 'custom'
          ? '$_customRepeatValue$_customRepeatUnit'
          : _repeatFrequency;
      final orgId = StorageService.currentUser?.organizationId;
      final addCal =
          _priority == 'important' || _priority == 'very_important';
      final assigneeIds =
          _selectedAssignees.map((m) => m.userId).toList();

      if (widget.existing != null) {
        final updated = widget.existing!.copyWith(
          assigneeUserIds: assigneeIds,
          startDateTime: _startDateTime,
          endDateTime: _endDateTime,
          repeatFrequency: freq,
          note: _noteCtrl.text.trim(),
          toDoAction: _toDoAction,
          priority: _priority,
        );
        await ref.read(tasksProvider.notifier).updateTask(updated);
      } else {
        await ref.read(tasksProvider.notifier).createTask(
              organizationId: orgId,
              assigneeUserIds: assigneeIds,
              startDateTime: _startDateTime,
              endDateTime: _endDateTime,
              repeatFrequency: freq,
              note: _noteCtrl.text.trim(),
              toDoAction: _toDoAction,
              priority: _priority,
              addToCalendar: addCal,
            );
      }
      if (addCal && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(l10n.addedToCalendar),
          backgroundColor: AppColors.primary,
        ));
      }
      if (mounted) context.pop();
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = ref.watch(l10nProvider);
    final isEdit = widget.existing != null;

    return Scaffold(
      backgroundColor: AppColors.bg(context),
      body: SafeArea(
        child: Form(
          key: _formKey,
          child: Column(
            children: [
              // ── App bar ───────────────────────────────────────────────
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                child: Row(
                  children: [
                    IconButton(
                      onPressed: () => context.pop(),
                      icon: Icon(Icons.arrow_back,
                          color: AppColors.onSurface(context)),
                    ),
                    Expanded(
                      child: Text(
                        isEdit ? l10n.editTaskTitle : l10n.createTaskTitle,
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w800,
                          color: AppColors.onSurface(context),
                        ),
                      ),
                    ),
                  ],
                ),
              ),

              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // ── Assignees ─────────────────────────────────────
                      _section(context, l10n.taskAssigneesLabel),
                      _membersLoaded
                          ? _buildAssigneeTile(context, l10n)
                          : const Center(
                              child: Padding(
                                padding: EdgeInsets.all(12),
                                child: CircularProgressIndicator(),
                              ),
                            ),
                      const SizedBox(height: 20),

                      // ── Planning ──────────────────────────────────────
                      _section(context, l10n.planningSection),
                      _rowField(
                        context: context,
                        icon: Icons.play_arrow_rounded,
                        label: l10n.startLabel,
                        value: DateFormat('dd MMM yyyy HH:mm')
                            .format(_startDateTime),
                        onTap: () => _pickDate(isStart: true),
                      ),
                      const SizedBox(height: 8),
                      _rowField(
                        context: context,
                        icon: Icons.stop_rounded,
                        label: l10n.endLabel,
                        value: _endDateTime == null
                            ? '-'
                            : DateFormat('dd MMM yyyy HH:mm')
                                .format(_endDateTime!),
                        onTap: () => _pickDate(isStart: false),
                        trailing: _endDateTime == null
                            ? null
                            : IconButton(
                                icon: const Icon(Icons.close, size: 18),
                                onPressed: () =>
                                    setState(() => _endDateTime = null),
                              ),
                      ),
                      const SizedBox(height: 8),
                      DropdownButtonFormField<String?>(
                        value: _repeatFrequency,
                        dropdownColor: AppColors.surfaceColor(context),
                        style:
                            TextStyle(color: AppColors.onSurface(context)),
                        decoration: InputDecoration(
                          labelText: l10n.repeatLabel,
                          border: const OutlineInputBorder(),
                          prefixIcon: const Icon(Icons.repeat_rounded),
                        ),
                        items: [
                          DropdownMenuItem(
                              value: null, child: Text(l10n.repeatNone)),
                          DropdownMenuItem(
                              value: '30m', child: Text(l10n.repeat30min)),
                          DropdownMenuItem(
                              value: '1h', child: Text(l10n.repeatHourly)),
                          DropdownMenuItem(
                              value: '1d', child: Text(l10n.repeatDaily)),
                          DropdownMenuItem(
                              value: '1w', child: Text(l10n.repeatWeekly)),
                          DropdownMenuItem(
                              value: '1mo', child: Text(l10n.repeatMonthly)),
                          DropdownMenuItem(
                              value: 'custom',
                              child: Text(l10n.repeatCustom)),
                        ],
                        onChanged: (v) =>
                            setState(() => _repeatFrequency = v),
                      ),
                      if (_repeatFrequency == 'custom') ...[
                        const SizedBox(height: 12),
                        Row(
                          children: [
                            Expanded(
                              flex: 2,
                              child: TextFormField(
                                initialValue:
                                    _customRepeatValue.toString(),
                                style: TextStyle(
                                    color: AppColors.onSurface(context)),
                                decoration: InputDecoration(
                                  labelText: l10n.customRepeatValue,
                                  border: const OutlineInputBorder(),
                                ),
                                keyboardType: TextInputType.number,
                                onChanged: (v) => setState(() =>
                                    _customRepeatValue =
                                        int.tryParse(v) ?? 1),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              flex: 3,
                              child: DropdownButtonFormField<String>(
                                value: _customRepeatUnit,
                                dropdownColor:
                                    AppColors.surfaceColor(context),
                                style: TextStyle(
                                    color: AppColors.onSurface(context)),
                                decoration: InputDecoration(
                                  labelText: l10n.customRepeatUnit,
                                  border: const OutlineInputBorder(),
                                ),
                                items: [
                                  DropdownMenuItem(
                                      value: 'm',
                                      child: Text(l10n.unitMinutes)),
                                  DropdownMenuItem(
                                      value: 'h',
                                      child: Text(l10n.unitHours)),
                                  DropdownMenuItem(
                                      value: 'd',
                                      child: Text(l10n.unitDays)),
                                  DropdownMenuItem(
                                      value: 'w',
                                      child: Text(l10n.unitWeeks)),
                                  DropdownMenuItem(
                                      value: 'mo',
                                      child: Text(l10n.unitMonths)),
                                ],
                                onChanged: (v) =>
                                    setState(() => _customRepeatUnit = v!),
                              ),
                            ),
                          ],
                        ),
                      ],
                      const SizedBox(height: 20),

                      // ── Note ──────────────────────────────────────────
                      _section(context, l10n.noteSection),
                      TextFormField(
                        controller: _noteCtrl,
                        maxLines: 3,
                        style: TextStyle(
                            color: AppColors.onSurface(context)),
                        validator: (v) =>
                            v == null || v.trim().isEmpty
                                ? l10n.noteRequired
                                : null,
                        decoration: InputDecoration(
                          hintText: l10n.taskNoteHint,
                          hintStyle:
                              TextStyle(color: AppColors.hint(context)),
                          border: const OutlineInputBorder(),
                        ),
                      ),
                      const SizedBox(height: 20),

                      // ── Action ────────────────────────────────────────
                      _section(context, l10n.todoSection),
                      Wrap(
                        spacing: 8,
                        children: [
                          _choiceChip(context, 'call', l10n.actionCall,
                              Icons.phone_rounded),
                          _choiceChip(context, 'sms', l10n.actionSms,
                              Icons.sms_rounded),
                          _choiceChip(context, 'whatsapp',
                              l10n.actionWhatsapp, Icons.chat_rounded),
                          _choiceChip(context, 'email', l10n.actionEmail,
                              Icons.email_rounded),
                        ],
                      ),
                      const SizedBox(height: 20),

                      // ── Priority ──────────────────────────────────────
                      _section(context, l10n.prioritySection),
                      Wrap(
                        spacing: 8,
                        children: [
                          _priorityChip(context, 'normal',
                              l10n.priorityNormal, AppColors.success),
                          _priorityChip(context, 'important',
                              l10n.priorityImportant, AppColors.warm),
                          _priorityChip(context, 'very_important',
                              l10n.priorityVeryImportant, AppColors.hot),
                        ],
                      ),
                      const SizedBox(height: 32),
                    ],
                  ),
                ),
              ),

              // ── Save button ────────────────────────────────────────────
              SafeArea(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: ElevatedButton(
                    onPressed: _saving ? null : () => _save(l10n),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.primary,
                      foregroundColor: Colors.white,
                      minimumSize: const Size(double.infinity, 52),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14)),
                    ),
                    child: _saving
                        ? const SizedBox(
                            height: 22,
                            width: 22,
                            child: CircularProgressIndicator(
                                color: Colors.white, strokeWidth: 2),
                          )
                        : Text(
                            isEdit ? l10n.saveTaskBtn : l10n.createTaskBtn,
                            style: const TextStyle(
                                fontSize: 15, fontWeight: FontWeight.w700),
                          ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildAssigneeTile(BuildContext context, AppL10n l10n) {
    if (_selectedAssignees.isEmpty) {
      return InkWell(
        onTap: _isAdminOrOwner ? () => _pickMembers(l10n) : null,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            border: Border.all(color: AppColors.borderColor(context)),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            children: [
              Icon(Icons.people_rounded,
                  color: AppColors.hint(context), size: 20),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  l10n.taskSelectAssignees,
                  style:
                      TextStyle(color: AppColors.hint(context), fontSize: 14),
                ),
              ),
              if (_isAdminOrOwner)
                Icon(Icons.chevron_right_rounded,
                    color: AppColors.hint(context)),
            ],
          ),
        ),
      );
    }

    final visible = _selectedAssignees.take(3).toList();
    final overflow = _selectedAssignees.length > 3
        ? _selectedAssignees.length - 3
        : 0;

    return InkWell(
      onTap: _isAdminOrOwner ? () => _pickMembers(l10n) : null,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: AppColors.primary.withOpacity(0.05),
          border: Border.all(color: AppColors.primary.withOpacity(0.3)),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            // Stacked avatars (max 3 visible)
            SizedBox(
              width: visible.length == 1
                  ? 40.0
                  : (20.0 * visible.length + 20.0),
              height: 40,
              child: Stack(
                children: [
                  for (var i = 0; i < visible.length; i++)
                    Positioned(
                      left: i * 20.0,
                      child: CircleAvatar(
                        radius: 20,
                        backgroundColor: AppColors.primary.withOpacity(0.15),
                        child: Text(
                          _initials(visible[i].firstName, visible[i].lastName),
                          style: const TextStyle(
                              color: AppColors.primary,
                              fontWeight: FontWeight.w700,
                              fontSize: 11),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            if (overflow > 0) ...[
              const SizedBox(width: 4),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: AppColors.primary.withOpacity(0.12),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text('+$overflow',
                    style: const TextStyle(
                        color: AppColors.primary,
                        fontSize: 10,
                        fontWeight: FontWeight.w800)),
              ),
            ],
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                _selectedAssignees.length == 1
                    ? _selectedAssignees.first.fullName
                    : l10n.taskAssigneesCount(_selectedAssignees.length),
                style: TextStyle(
                  fontWeight: FontWeight.w700,
                  color: AppColors.onSurface(context),
                ),
              ),
            ),
            if (_isAdminOrOwner)
              Icon(Icons.chevron_right_rounded,
                  color: AppColors.hint(context)),
          ],
        ),
      ),
    );
  }

  Widget _section(BuildContext context, String t) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Text(
          t.toUpperCase(),
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w800,
            letterSpacing: 1,
            color: AppColors.hint(context),
          ),
        ),
      );

  Widget _rowField({
    required BuildContext context,
    required IconData icon,
    required String label,
    required String value,
    required VoidCallback onTap,
    Widget? trailing,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          border: Border.all(color: AppColors.borderColor(context)),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          children: [
            Icon(icon, size: 18, color: AppColors.primary),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label,
                      style: TextStyle(
                          fontSize: 11, color: AppColors.hint(context))),
                  Text(value,
                      style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: AppColors.onSurface(context))),
                ],
              ),
            ),
            if (trailing != null) trailing,
          ],
        ),
      ),
    );
  }

  Widget _choiceChip(
      BuildContext context, String v, String label, IconData icon) {
    final sel = _toDoAction == v;
    return ChoiceChip(
      avatar: Icon(icon, size: 16, color: sel ? Colors.white : AppColors.primary),
      label: Text(label),
      selected: sel,
      onSelected: (_) => setState(() => _toDoAction = v),
      selectedColor: AppColors.primary,
      labelStyle: TextStyle(
        color: sel ? Colors.white : AppColors.onSurface(context),
        fontWeight: FontWeight.w600,
      ),
    );
  }

  Widget _priorityChip(
      BuildContext context, String v, String label, Color color) {
    final sel = _priority == v;
    return ChoiceChip(
      label: Text(label),
      selected: sel,
      onSelected: (_) => setState(() => _priority = v),
      selectedColor: color,
      labelStyle:
          TextStyle(color: sel ? Colors.white : color, fontWeight: FontWeight.w700),
      side: BorderSide(color: color),
      backgroundColor: AppColors.surfaceColor(context),
    );
  }

  String _initials(String first, String last) {
    final f = first.isNotEmpty ? first[0].toUpperCase() : '';
    final l = last.isNotEmpty ? last[0].toUpperCase() : '';
    return '$f$l';
  }
}

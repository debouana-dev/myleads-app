import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../core/l10n/app_l10n.dart';
import '../../core/theme/app_colors.dart';
import '../../models/reminder.dart';
import '../../providers/contacts_provider.dart';
import '../../providers/reminders_provider.dart';
import '../../services/calendar_service.dart';

class CreateReminderScreen extends ConsumerStatefulWidget {
  final Reminder? existing;
  final String? preselectedContactId;
  const CreateReminderScreen({super.key, this.existing, this.preselectedContactId});
  @override
  ConsumerState<CreateReminderScreen> createState() => _CreateReminderScreenState();
}

class _CreateReminderScreenState extends ConsumerState<CreateReminderScreen> {
  final _formKey = GlobalKey<FormState>();
  final _noteCtrl = TextEditingController();

  List<String> _contactIds = [];
  DateTime _startDateTime = DateTime.now().add(const Duration(hours: 1));
  DateTime? _endDateTime;
  String? _repeatFrequency;
  String _toDoAction = 'call';
  String _priority = 'normal';
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    if (e != null) {
      _contactIds = [...e.contactIds];
      _startDateTime = e.startDateTime;
      _endDateTime = e.endDateTime;
      _repeatFrequency = e.repeatFrequency;
      _toDoAction = e.toDoAction;
      _priority = e.priority;
      _noteCtrl.text = e.note;
    } else if (widget.preselectedContactId != null) {
      _contactIds = [widget.preselectedContactId!];
    }
  }

  @override
  void dispose() {
    _noteCtrl.dispose();
    super.dispose();
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
    final time = await showTimePicker(context: context, initialTime: TimeOfDay.fromDateTime(base));
    if (time == null) return;
    final dt = DateTime(date.year, date.month, date.day, time.hour, time.minute);
    setState(() {
      if (isStart) {
        _startDateTime = dt;
        if (_endDateTime != null && _endDateTime!.isBefore(dt)) _endDateTime = null;
      } else {
        _endDateTime = dt;
      }
    });
  }

  void _pickContacts(AppL10n l10n) {
    final contacts = ref.read(contactsProvider).contacts;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) {
        final selected = {..._contactIds};
        return StatefulBuilder(
          builder: (ctx, setSt) => Container(
            height: MediaQuery.of(context).size.height * 0.75,
            decoration: BoxDecoration(
              color: AppColors.surfaceColor(context),
              borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
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
                  padding: const EdgeInsets.all(16),
                  child: Text(
                    l10n.selectContacts,
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                      color: AppColors.onSurface(context),
                    ),
                  ),
                ),
                Expanded(
                  child: contacts.isEmpty
                      ? Center(
                          child: Text(
                            l10n.noContactsAvailable,
                            style: TextStyle(color: AppColors.secondary(context)),
                          ),
                        )
                      : ListView.builder(
                          itemCount: contacts.length,
                          itemBuilder: (_, i) {
                            final c = contacts[i];
                            final isSel = selected.contains(c.id);
                            return ListTile(
                              leading: CircleAvatar(
                                backgroundColor: AppColors.primary.withOpacity(0.12),
                                child: Text(c.initials,
                                    style: const TextStyle(color: AppColors.primary, fontWeight: FontWeight.w700)),
                              ),
                              title: Text(
                                c.fullName,
                                style: TextStyle(color: AppColors.onSurface(context)),
                              ),
                              subtitle: Text(
                                c.phone ?? c.email ?? '',
                                style: TextStyle(color: AppColors.secondary(context)),
                              ),
                              trailing: isSel
                                  ? const Icon(Icons.check_circle, color: AppColors.primary)
                                  : Icon(Icons.radio_button_unchecked, color: AppColors.hint(context)),
                              onTap: () => setSt(() {
                                if (isSel) {
                                  selected.remove(c.id);
                                } else {
                                  selected.add(c.id);
                                }
                              }),
                            );
                          },
                        ),
                ),
                SafeArea(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: ElevatedButton(
                      onPressed: () {
                        setState(() => _contactIds = selected.toList());
                        Navigator.pop(ctx);
                      },
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppColors.primary,
                        foregroundColor: Colors.white,
                        minimumSize: const Size(double.infinity, 48),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      ),
                      child: Text(
                        l10n.validateContacts(selected.length),
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _save(AppL10n l10n) async {
    if (!_formKey.currentState!.validate()) return;
    if (_contactIds.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(l10n.contactRequired),
          backgroundColor: AppColors.hot,
        ),
      );
      return;
    }
    setState(() => _saving = true);
    try {
      Reminder saved;
      if (widget.existing != null) {
        saved = widget.existing!.copyWith(
          contactIds: _contactIds,
          startDateTime: _startDateTime,
          endDateTime: _endDateTime,
          repeatFrequency: _repeatFrequency,
          note: _noteCtrl.text.trim(),
          toDoAction: _toDoAction,
          priority: _priority,
        );
        await ref.read(remindersProvider.notifier).updateReminder(saved);
      } else {
        saved = await ref.read(remindersProvider.notifier).addReminder(
              contactIds: _contactIds,
              startDateTime: _startDateTime,
              endDateTime: _endDateTime,
              repeatFrequency: _repeatFrequency,
              note: _noteCtrl.text.trim(),
              toDoAction: _toDoAction,
              priority: _priority,
            );
      }
      if (_priority == 'important' || _priority == 'very_important') {
        try {
          await CalendarService.addReminderToCalendar(saved);
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(l10n.addedToCalendar),
                backgroundColor: AppColors.primary,
              ),
            );
          }
        } catch (_) {}
      }
      if (mounted) Navigator.pop(context);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = ref.watch(l10nProvider);
    final isEdit = widget.existing != null;
    final contacts = ref.watch(contactsProvider).contacts;
    final selectedContacts = contacts.where((c) => _contactIds.contains(c.id)).toList();

    return Scaffold(
      backgroundColor: AppColors.bg(context),
      body: SafeArea(
        child: Form(
          key: _formKey,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                child: Row(
                  children: [
                    IconButton(
                      onPressed: () => Navigator.pop(context),
                      icon: Icon(Icons.arrow_back, color: AppColors.onSurface(context)),
                    ),
                    Expanded(
                      child: Text(
                        isEdit ? l10n.editReminderTitle : l10n.newReminderTitle,
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
                      _section(context, l10n.contactsSection),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          ...selectedContacts.map((c) => Chip(
                                label: Text(
                                  c.fullName,
                                  style: TextStyle(color: AppColors.onSurface(context)),
                                ),
                                onDeleted: () => setState(() => _contactIds.remove(c.id)),
                                backgroundColor: AppColors.primary.withOpacity(0.12),
                              )),
                          ActionChip(
                            label: Text(
                              l10n.addButton,
                              style: TextStyle(color: AppColors.onSurface(context)),
                            ),
                            onPressed: () => _pickContacts(l10n),
                            backgroundColor: AppColors.surfaceColor(context),
                          ),
                        ],
                      ),
                      const SizedBox(height: 20),
                      _section(context, l10n.planningSection),
                      _rowField(
                        context: context,
                        icon: Icons.play_arrow_rounded,
                        label: l10n.startLabel,
                        value: DateFormat('dd MMM yyyy HH:mm').format(_startDateTime),
                        onTap: () => _pickDate(isStart: true),
                      ),
                      const SizedBox(height: 8),
                      _rowField(
                        context: context,
                        icon: Icons.stop_rounded,
                        label: l10n.endLabel,
                        value: _endDateTime == null
                            ? '-'
                            : DateFormat('dd MMM yyyy HH:mm').format(_endDateTime!),
                        onTap: () => _pickDate(isStart: false),
                        trailing: _endDateTime == null
                            ? null
                            : IconButton(
                                icon: const Icon(Icons.close, size: 18),
                                onPressed: () => setState(() => _endDateTime = null),
                              ),
                      ),
                      const SizedBox(height: 8),
                      DropdownButtonFormField<String?>(
                        value: _repeatFrequency,
                        dropdownColor: AppColors.surfaceColor(context),
                        style: TextStyle(color: AppColors.onSurface(context)),
                        decoration: InputDecoration(
                          labelText: l10n.repeatLabel,
                          border: const OutlineInputBorder(),
                          prefixIcon: const Icon(Icons.repeat_rounded),
                        ),
                        items: [
                          DropdownMenuItem(value: null, child: Text(l10n.repeatNone)),
                          DropdownMenuItem(value: '30m', child: Text(l10n.repeat30min)),
                          DropdownMenuItem(value: '1h', child: Text(l10n.repeatHourly)),
                          DropdownMenuItem(value: '1d', child: Text(l10n.repeatDaily)),
                          DropdownMenuItem(value: '1w', child: Text(l10n.repeatWeekly)),
                          DropdownMenuItem(value: '1mo', child: Text(l10n.repeatMonthly)),
                        ],
                        onChanged: (v) => setState(() => _repeatFrequency = v),
                      ),
                      const SizedBox(height: 20),
                      _section(context, l10n.noteSection),
                      TextFormField(
                        controller: _noteCtrl,
                        maxLines: 3,
                        style: TextStyle(color: AppColors.onSurface(context)),
                        validator: (v) =>
                            v == null || v.trim().isEmpty ? l10n.noteRequired : null,
                        decoration: InputDecoration(
                          hintText: l10n.noteHint,
                          hintStyle: TextStyle(color: AppColors.hint(context)),
                          border: const OutlineInputBorder(),
                        ),
                      ),
                      const SizedBox(height: 20),
                      _section(context, l10n.todoSection),
                      Wrap(
                        spacing: 8,
                        children: [
                          _choiceChip(context, 'call', l10n.actionCall, Icons.phone_rounded),
                          _choiceChip(context, 'sms', l10n.actionSms, Icons.sms_rounded),
                          _choiceChip(context, 'whatsapp', l10n.actionWhatsapp, Icons.chat_rounded),
                          _choiceChip(context, 'email', l10n.actionEmail, Icons.email_rounded),
                        ],
                      ),
                      const SizedBox(height: 20),
                      _section(context, l10n.prioritySection),
                      Wrap(
                        spacing: 8,
                        children: [
                          _priorityChip(context, 'normal', l10n.priorityNormal, AppColors.success),
                          _priorityChip(context, 'important', l10n.priorityImportant, AppColors.warm),
                          _priorityChip(context, 'very_important', l10n.priorityVeryImportant, AppColors.hot),
                        ],
                      ),
                      const SizedBox(height: 32),
                    ],
                  ),
                ),
              ),
              SafeArea(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: ElevatedButton(
                    onPressed: _saving ? null : () => _save(l10n),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.primary,
                      foregroundColor: Colors.white,
                      minimumSize: const Size(double.infinity, 52),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                    ),
                    child: _saving
                        ? const SizedBox(
                            height: 22,
                            width: 22,
                            child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2),
                          )
                        : Text(
                            isEdit ? l10n.saveReminderBtn : l10n.createReminderBtn,
                            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
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
                  Text(label, style: TextStyle(fontSize: 11, color: AppColors.hint(context))),
                  Text(
                    value,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: AppColors.onSurface(context),
                    ),
                  ),
                ],
              ),
            ),
            if (trailing != null) trailing,
          ],
        ),
      ),
    );
  }

  Widget _choiceChip(BuildContext context, String v, String label, IconData icon) {
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

  Widget _priorityChip(BuildContext context, String v, String label, Color color) {
    final sel = _priority == v;
    return ChoiceChip(
      label: Text(label),
      selected: sel,
      onSelected: (_) => setState(() => _priority = v),
      selectedColor: color,
      labelStyle: TextStyle(color: sel ? Colors.white : color, fontWeight: FontWeight.w700),
      side: BorderSide(color: color),
      backgroundColor: AppColors.surfaceColor(context),
    );
  }
}

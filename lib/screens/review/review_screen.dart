import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:go_router/go_router.dart';
import 'package:uuid/uuid.dart';
import '../../core/l10n/app_l10n.dart';
import '../../core/theme/app_colors.dart';
import '../../models/contact.dart';
import '../../providers/contacts_provider.dart';
import '../../widgets/phone_prefix_input.dart';

class ReviewScreen extends ConsumerStatefulWidget {
  final Map<String, String> ocrData;
  const ReviewScreen({super.key, this.ocrData = const {}});

  @override
  ConsumerState<ReviewScreen> createState() => _ReviewScreenState();
}

class _ReviewScreenState extends ConsumerState<ReviewScreen> {
  late final TextEditingController _firstNameCtrl;
  late final TextEditingController _lastNameCtrl;
  late final TextEditingController _jobTitleCtrl;
  late final TextEditingController _companyCtrl;
  late final TextEditingController _phoneCtrl;
  late final TextEditingController _emailCtrl;
  late final TextEditingController _sourceCtrl;
  late final TextEditingController _project1Ctrl;
  late final TextEditingController _project1BudgetCtrl;
  late final TextEditingController _project2Ctrl;
  late final TextEditingController _project2BudgetCtrl;
  late final TextEditingController _notesCtrl;
  String? _photoPath;

  @override
  void initState() {
    super.initState();
    final d = widget.ocrData;
    _firstNameCtrl = TextEditingController(text: d['firstName'] ?? '');
    _lastNameCtrl = TextEditingController(text: d['lastName'] ?? '');
    _jobTitleCtrl = TextEditingController(text: d['jobTitle'] ?? '');
    _companyCtrl = TextEditingController(text: d['company'] ?? '');
    _phoneCtrl = TextEditingController(text: d['phone'] ?? '');
    _emailCtrl = TextEditingController(text: d['email'] ?? '');
    _sourceCtrl = TextEditingController(text: d['source'] ?? '');
    _project1Ctrl = TextEditingController(text: d['project1'] ?? '');
    _project1BudgetCtrl = TextEditingController(text: d['project1Budget'] ?? '');
    _project2Ctrl = TextEditingController(text: d['project2'] ?? '');
    _project2BudgetCtrl = TextEditingController(text: d['project2Budget'] ?? '');
    _notesCtrl = TextEditingController(text: d['notes'] ?? '');
    _photoPath = d['photoPath'];

    // Pre-select tags found by OCR (comma-separated).
    final parsedTags = (d['tags'] ?? '')
        .split(',')
        .map((t) => t.trim())
        .where((t) => t.isNotEmpty)
        .toList();
    if (parsedTags.isNotEmpty) {
      for (final t in parsedTags) {
        if (!_availableTags.contains(t)) _availableTags.add(t);
        _selectedTags.add(t);
      }
    }
  }

  final List<String> _availableTags = [
    'Tech',
    'CEO',
    'Investor',
    'Partner',
    'Event',
    'Priority',
    'B2B',
    'Media',
  ];
  final Set<String> _selectedTags = {'Tech', 'CEO'};

  @override
  void dispose() {
    _firstNameCtrl.dispose();
    _lastNameCtrl.dispose();
    _jobTitleCtrl.dispose();
    _companyCtrl.dispose();
    _phoneCtrl.dispose();
    _emailCtrl.dispose();
    _sourceCtrl.dispose();
    _project1Ctrl.dispose();
    _project1BudgetCtrl.dispose();
    _project2Ctrl.dispose();
    _project2BudgetCtrl.dispose();
    _notesCtrl.dispose();
    super.dispose();
  }

  String? _orNull(String value) => value.trim().isEmpty ? null : value.trim();

  String _randomHexColor() {
    final r = Random();
    return '#'
        '${r.nextInt(256).toRadixString(16).padLeft(2, '0')}'
        '${r.nextInt(256).toRadixString(16).padLeft(2, '0')}'
        '${r.nextInt(256).toRadixString(16).padLeft(2, '0')}';
  }

  Future<void> _saveContact({bool andContact = false}) async {
    final contact = Contact(
      id: const Uuid().v4(),
      firstName: _firstNameCtrl.text.trim(),
      lastName: _lastNameCtrl.text.trim(),
      jobTitle: _orNull(_jobTitleCtrl.text),
      company: _orNull(_companyCtrl.text),
      phone: _orNull(_phoneCtrl.text),
      email: _orNull(_emailCtrl.text),
      source: _orNull(_sourceCtrl.text),
      project1: _orNull(_project1Ctrl.text),
      project1Budget: _orNull(_project1BudgetCtrl.text),
      project2: _orNull(_project2Ctrl.text),
      project2Budget: _orNull(_project2BudgetCtrl.text),
      notes: _orNull(_notesCtrl.text),
      tags: _selectedTags.toList(),
      status: 'warm',
      captureMethod: 'scan',
      photoPath: _photoPath,
      avatarColor: _randomHexColor(),
    );

    final result =
        await ref.read(contactsProvider.notifier).addContact(contact);

    if (!mounted) return;

    if (!result.isSuccess) {
      final l10n = ref.read(l10nProvider);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Row(
            children: [
              const Icon(Icons.error_outline, color: Colors.white, size: 20),
              const SizedBox(width: 10),
              Expanded(child: Text(_localizedError(result.error!, l10n))),
            ],
          ),
          backgroundColor: AppColors.hot,
          behavior: SnackBarBehavior.floating,
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
      );
      return;
    }

    final l10n = ref.read(l10nProvider);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            const Icon(Icons.check_circle, color: AppColors.accent, size: 20),
            const SizedBox(width: 10),
            Text(l10n.contactSaved),
          ],
        ),
        backgroundColor: AppColors.primary,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    );
    await Future.delayed(const Duration(milliseconds: 800));
    if (mounted) context.go('/main');
  }

  String _localizedError(String error, AppL10n l10n) {
    if (error == ContactsNotifier.freeContactLimitError) {
      return l10n.freeContactLimitReached;
    }
    return error;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = ref.watch(l10nProvider);
    return Scaffold(
      backgroundColor: AppColors.bg(context),
      body: Column(
        children: [
          // Header
          Container(
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
                Row(
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
                  ],
                ),
                const SizedBox(height: 16),
                Text(
                  l10n.reviewTitle,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 22,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  l10n.reviewSubtitle,
                  style: TextStyle(
                    color: Colors.white.withOpacity(0.5),
                    fontSize: 13,
                  ),
                ),
                const SizedBox(height: 12),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                  decoration: BoxDecoration(
                    color: AppColors.success.withOpacity(0.15),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.check_circle,
                          color: AppColors.success, size: 14),
                      const SizedBox(width: 6),
                      Text(
                        l10n.ocrConfidence,
                        style: const TextStyle(
                          color: AppColors.success,
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),

          // Form
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildField(l10n.firstName, _firstNameCtrl),
                  _buildField(l10n.lastName, _lastNameCtrl),
                  _buildField(l10n.jobTitleLabel, _jobTitleCtrl),
                  _buildField(l10n.companyLabel, _companyCtrl),
                  const SizedBox(height: 4),
                  PhonePrefixInput(
                    controller: _phoneCtrl,
                    labelText: l10n.phoneLabel,
                    showLabel: true,
                    hint: '6 99 88 77 66',
                  ),
                  const SizedBox(height: 16),
                  _buildField(l10n.emailLabel, _emailCtrl,
                      type: TextInputType.emailAddress),
                  _buildField(l10n.sourceLabel, _sourceCtrl),
                  _buildField(l10n.project1Review, _project1Ctrl),
                  _buildField(l10n.project1BudgetReview, _project1BudgetCtrl),
                  _buildField(l10n.project2Review, _project2Ctrl),
                  _buildField(l10n.project2BudgetReview, _project2BudgetCtrl),

                  // Tags
                  const SizedBox(height: 4),
                  Text(
                    l10n.tagsLabel.toUpperCase(),
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      color: AppColors.hint(context),
                      letterSpacing: 1,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: _availableTags.map((tag) {
                      final selected = _selectedTags.contains(tag);
                      return GestureDetector(
                        onTap: () {
                          setState(() {
                            if (selected) {
                              _selectedTags.remove(tag);
                            } else {
                              _selectedTags.add(tag);
                            }
                          });
                        },
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 200),
                          padding: const EdgeInsets.symmetric(
                              horizontal: 14, vertical: 6),
                          decoration: BoxDecoration(
                            color: selected
                                ? AppColors.accent
                                : AppColors.primary.withOpacity(0.06),
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: Text(
                            tag,
                            style: const TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: AppColors.primary,
                            ),
                          ),
                        ),
                      );
                    }).toList(),
                  ),

                  const SizedBox(height: 16),
                  _buildField(l10n.notesLabel, _notesCtrl, maxLines: 3),

                  // Quick Actions
                  const SizedBox(height: 8),
                  Text(
                    l10n.quickActions.toUpperCase(),
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      color: AppColors.hint(context),
                      letterSpacing: 1,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      _buildQuickAction(const Icon(Icons.phone, size: 20),
                          l10n.callLabel, AppColors.success),
                      const SizedBox(width: 10),
                      _buildQuickAction(
                          const FaIcon(FontAwesomeIcons.whatsapp, size: 20),
                          l10n.whatsappLabel,
                          const Color(0xFF25D366)),
                      const SizedBox(width: 10),
                      _buildQuickAction(const Icon(Icons.email, size: 20),
                          l10n.emailActionLabel, AppColors.primary),
                      const SizedBox(width: 10),
                      _buildQuickAction(const Icon(Icons.sms, size: 20),
                          l10n.smsLabel, AppColors.warm),
                    ],
                  ),
                  const SizedBox(height: 100),
                ],
              ),
            ),
          ),

          // Bottom Action
          Container(
            padding: EdgeInsets.only(
              left: 24,
              right: 24,
              bottom: MediaQuery.of(context).padding.bottom + 16,
              top: 16,
            ),
            decoration: BoxDecoration(
              color: AppColors.bg(context),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.05),
                  blurRadius: 10,
                  offset: const Offset(0, -4),
                ),
              ],
            ),
            child: Row(
              children: [
                Expanded(
                  child: SizedBox(
                    height: 54,
                    child: ElevatedButton(
                      onPressed: _saveContact,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppColors.accent,
                        foregroundColor: AppColors.primary,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      child: Text(
                        l10n.saveButton,
                        style: const TextStyle(
                            fontSize: 16, fontWeight: FontWeight.w700),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildField(String label, TextEditingController ctrl,
      {TextInputType? type, int maxLines = 1}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label.toUpperCase(),
            style: const TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              color: AppColors.textLight,
              letterSpacing: 1,
            ),
          ),
          const SizedBox(height: 6),
          TextField(
            controller: ctrl,
            keyboardType: type,
            maxLines: maxLines,
            style: const TextStyle(fontSize: 14, color: AppColors.textDark),
            decoration: InputDecoration(
              filled: true,
              fillColor: AppColors.card,
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: const BorderSide(color: AppColors.border, width: 2),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: const BorderSide(color: AppColors.border, width: 2),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: const BorderSide(color: AppColors.accent, width: 2),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildQuickAction(Widget icon, String label, Color color) {
    return Expanded(
      child: GestureDetector(
        onTap: () {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('$label en cours...'),
              duration: const Duration(seconds: 1),
            ),
          );
        },
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 14),
          decoration: BoxDecoration(
            color: AppColors.card,
            borderRadius: BorderRadius.circular(12),
            boxShadow: [
              BoxShadow(
                color: AppColors.primary.withOpacity(0.08),
                blurRadius: 20,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Column(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: color.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Center(
                  child: IconTheme(
                    data: IconThemeData(color: color, size: 20),
                    child: icon,
                  ),
                ),
              ),
              const SizedBox(height: 6),
              Text(
                label,
                style: const TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: AppColors.textMid,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

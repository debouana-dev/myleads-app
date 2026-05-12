import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';

import '../../core/theme/app_colors.dart';
import '../../core/l10n/app_l10n.dart';
import '../../models/contact.dart';
import '../../providers/contacts_provider.dart';
import '../../services/ftp_photo_service.dart';
import '../../services/photo_storage_service.dart';
import '../../services/storage_service.dart';

/// Screen used both for editing an existing contact and for creating a new
/// contact manually. When [contactId] is null we render empty fields with
/// placeholder hints. When provided, we pre-fill from the existing contact.
class ContactEditScreen extends ConsumerStatefulWidget {
  final String? contactId;
  const ContactEditScreen({super.key, this.contactId});

  @override
  ConsumerState<ContactEditScreen> createState() => _ContactEditScreenState();
}

class _ContactEditScreenState extends ConsumerState<ContactEditScreen> {
  final _formKey = GlobalKey<FormState>();

  final _firstNameCtrl = TextEditingController();
  final _lastNameCtrl = TextEditingController();
  final _jobTitleCtrl = TextEditingController();
  final _companyCtrl = TextEditingController();
  final _phoneCtrl = TextEditingController();
  final _emailCtrl = TextEditingController();
  final _sourceCtrl = TextEditingController();
  final _project1Ctrl = TextEditingController();
  final _project1BudgetCtrl = TextEditingController();
  final _project2Ctrl = TextEditingController();
  final _project2BudgetCtrl = TextEditingController();
  final _notesCtrl = TextEditingController();

  String _status = 'warm';
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
  final Set<String> _selectedTags = {};

  Contact? _existing;
  bool _saving = false;
  String? _photoPath;

  @override
  void initState() {
    super.initState();
    if (widget.contactId != null) {
      // Pre-fill in next frame so providers are mounted.
      WidgetsBinding.instance.addPostFrameCallback((_) => _loadExisting());
    }
  }

  void _loadExisting() {
    final contact = ref.read(contactByIdProvider(widget.contactId!));
    if (contact == null) return;
    _existing = contact;
    setState(() {
      _firstNameCtrl.text = contact.firstName;
      _lastNameCtrl.text = contact.lastName;
      _jobTitleCtrl.text = contact.jobTitle ?? '';
      _companyCtrl.text = contact.company ?? '';
      _phoneCtrl.text = contact.phone ?? '';
      _emailCtrl.text = contact.email ?? '';
      _sourceCtrl.text = contact.source ?? '';
      _project1Ctrl.text = contact.project1 ?? '';
      _project1BudgetCtrl.text = contact.project1Budget ?? '';
      _project2Ctrl.text = contact.project2 ?? '';
      _project2BudgetCtrl.text = contact.project2Budget ?? '';
      _notesCtrl.text = contact.notes ?? '';
      _status = contact.status;
      _photoPath = contact.photoPath;
      _selectedTags
        ..clear()
        ..addAll(contact.tags);
    });
  }

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

  Future<void> _save(AppL10n l10n) async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _saving = true);

    final base = _existing ??
        Contact(
          id: '',
          firstName: '',
          lastName: '',
          captureMethod: 'manual',
        );

    final updated = base.copyWith(
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
      status: _status,
      photoPath: _photoPath,
    );

    final notifier = ref.read(contactsProvider.notifier);
    final result = _existing == null
        ? await notifier.addContact(updated)
        : await notifier.updateContact(updated);

    if (!mounted) return;
    setState(() => _saving = false);

    if (!result.isSuccess) {
      _showError(_localizedError(result.error!, l10n));
      return;
    }

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            const Icon(Icons.check_circle, color: AppColors.accent, size: 20),
            const SizedBox(width: 10),
            Text(_existing == null ? l10n.contactCreated : l10n.contactUpdated),
          ],
        ),
        backgroundColor: AppColors.primary,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    );

    await Future.delayed(const Duration(milliseconds: 600));
    if (mounted) context.pop();
  }

  String? _orNull(String value) => value.trim().isEmpty ? null : value.trim();

  void _showError(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            const Icon(Icons.error_outline, color: Colors.white, size: 20),
            const SizedBox(width: 10),
            Expanded(child: Text(message)),
          ],
        ),
        backgroundColor: AppColors.hot,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    );
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
    final isEdit = widget.contactId != null;

    return Scaffold(
      backgroundColor: AppColors.bg(context),
      body: Form(
        key: _formKey,
        child: Column(
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
                    isEdit ? l10n.editContact : l10n.addContact,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 22,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    isEdit ? l10n.editContactSubtitle : l10n.addContactSubtitle,
                    style: TextStyle(
                      color: Colors.white.withOpacity(0.6),
                      fontSize: 13,
                    ),
                  ),
                ],
              ),
            ),

            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Photo picker
                    if (!kIsWeb)
                      Center(
                        child: GestureDetector(
                          onTap: () async {
                            final img = await ImagePicker().pickImage(
                              source: ImageSource.gallery,
                              imageQuality: 80,
                              maxWidth: 512,
                            );
                            if (img != null) {
                              try {
                                final savedPath =
                                    await PhotoStorageService.saveContactPhoto(
                                        img.path);
                                if (savedPath != null) {
                                  // Upload to FTP immediately (fire-and-forget) for premium/business users
                                  // so the photo is available when contact is accessed from another device
                                  final user = StorageService.currentUser;
                                  if (user != null &&
                                      (user.plan == 'premium' ||
                                          user.plan == 'business')) {
                                    FtpPhotoService.uploadPhoto(savedPath)
                                        .ignore();
                                  }

                                  setState(() => _photoPath = savedPath);
                                } else {
                                  setState(() => _photoPath = img.path);
                                }
                              } on PhotoFileTooLargeException {
                                _showError(l10n.photoTooLarge);
                              }
                            }
                          },
                          child: Stack(
                            children: [
                              Container(
                                width: 80,
                                height: 80,
                                margin: const EdgeInsets.only(bottom: 16),
                                decoration: BoxDecoration(
                                  color: AppColors.primary.withOpacity(0.1),
                                  borderRadius: BorderRadius.circular(24),
                                  image: _photoPath != null
                                      ? DecorationImage(
                                          image: FileImage(File(
                                              PhotoStorageService
                                                  .resolveAbsolutePath(
                                                      _photoPath)!)),
                                          fit: BoxFit.cover,
                                        )
                                      : null,
                                ),
                                child: _photoPath == null
                                    ? Icon(Icons.person,
                                        size: 36,
                                        color: AppColors.hint(context))
                                    : null,
                              ),
                              Positioned(
                                bottom: 12,
                                right: 0,
                                child: Container(
                                  width: 26,
                                  height: 26,
                                  decoration: BoxDecoration(
                                    color: AppColors.accent,
                                    shape: BoxShape.circle,
                                    border: Border.all(
                                        color: Colors.white, width: 2),
                                  ),
                                  child: const Icon(Icons.camera_alt,
                                      size: 12, color: AppColors.primary),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),

                    _buildField(
                      context,
                      l10n.firstName,
                      _firstNameCtrl,
                      hint: l10n.firstNameHint,
                    ),
                    _buildField(
                      context,
                      '${l10n.lastName} *',
                      _lastNameCtrl,
                      hint: l10n.lastNameHint,
                      validator: (v) {
                        if (v == null || v.trim().isEmpty) {
                          return l10n.lastNameRequired2;
                        }
                        return null;
                      },
                    ),
                    _buildField(
                      context,
                      l10n.jobTitleLabel,
                      _jobTitleCtrl,
                      hint: 'Ex : CEO',
                    ),
                    _buildField(
                      context,
                      l10n.companyLabel,
                      _companyCtrl,
                      hint: 'Ex : GreenTech Cameroon',
                    ),
                    _buildField(
                      context,
                      l10n.phoneLabel,
                      _phoneCtrl,
                      hint: 'Ex : +237 6 99 88 77 66',
                      type: TextInputType.phone,
                    ),
                    _buildField(
                      context,
                      l10n.emailLabel,
                      _emailCtrl,
                      hint: l10n.emailHint,
                      type: TextInputType.emailAddress,
                    ),
                    Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: Text(
                        l10n.emailPhoneRequired,
                        style: TextStyle(
                          fontSize: 11,
                          color: AppColors.hint(context),
                          fontStyle: FontStyle.italic,
                        ),
                      ),
                    ),
                    _buildField(
                      context,
                      l10n.sourceLabel,
                      _sourceCtrl,
                      hint: 'Ex : Salon Luxembourg 2026',
                    ),

                    // Projet 1
                    _label(context, l10n.project1Section),
                    const SizedBox(height: 6),
                    _buildField(
                      context,
                      l10n.projectNameLabel,
                      _project1Ctrl,
                      hint: 'Ex : Partenariat Tech',
                    ),
                    _buildField(
                      context,
                      l10n.budgetLabel,
                      _project1BudgetCtrl,
                      hint: 'Ex : 15 000 €',
                      type: TextInputType.text,
                    ),

                    // Projet 2
                    _label(context, l10n.project2Section),
                    const SizedBox(height: 6),
                    _buildField(
                      context,
                      l10n.projectNameLabel,
                      _project2Ctrl,
                      hint: 'Ex : Déploiement CRM',
                    ),
                    _buildField(
                      context,
                      l10n.budgetLabel,
                      _project2BudgetCtrl,
                      hint: 'Ex : 8 000 €',
                      type: TextInputType.text,
                    ),

                    // Status
                    const SizedBox(height: 4),
                    _label(context, l10n.statusLabel),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        _statusChip('hot', 'Hot', AppColors.hot),
                        const SizedBox(width: 8),
                        _statusChip('warm', 'Warm', AppColors.warm),
                        const SizedBox(width: 8),
                        _statusChip('cold', 'Cold', AppColors.cold),
                      ],
                    ),

                    // Tags
                    const SizedBox(height: 20),
                    _label(context, l10n.tagsLabel),
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
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                                color: selected
                                    ? AppColors.primary
                                    : AppColors.primary,
                              ),
                            ),
                          ),
                        );
                      }).toList(),
                    ),

                    const SizedBox(height: 20),
                    _buildField(
                      context,
                      l10n.notesLabel,
                      _notesCtrl,
                      hint: 'Notes personnelles sur le contact...',
                      maxLines: 3,
                    ),

                    const SizedBox(height: 80),
                  ],
                ),
              ),
            ),

            // Save button
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
              child: SizedBox(
                height: 54,
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: _saving ? null : () => _save(l10n),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.accent,
                    foregroundColor: AppColors.primary,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  child: _saving
                      ? const SizedBox(
                          width: 22,
                          height: 22,
                          child: CircularProgressIndicator(
                            strokeWidth: 2.5,
                            valueColor: AlwaysStoppedAnimation<Color>(
                                AppColors.primary),
                          ),
                        )
                      : Text(
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
    );
  }

  Widget _buildField(
    BuildContext context,
    String label,
    TextEditingController ctrl, {
    TextInputType? type,
    int maxLines = 1,
    String? hint,
    String? Function(String?)? validator,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _label(context, label),
          const SizedBox(height: 6),
          TextFormField(
            controller: ctrl,
            keyboardType: type,
            maxLines: maxLines,
            validator: validator,
            style: TextStyle(fontSize: 14, color: AppColors.onSurface(context)),
            decoration: InputDecoration(
              filled: true,
              fillColor: AppColors.surfaceColor(context),
              hintText: hint,
              hintStyle: TextStyle(
                color: AppColors.hint(context).withOpacity(0.6),
                fontSize: 14,
                fontWeight: FontWeight.w400,
              ),
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide:
                    BorderSide(color: AppColors.borderColor(context), width: 2),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide:
                    BorderSide(color: AppColors.borderColor(context), width: 2),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: const BorderSide(color: AppColors.accent, width: 2),
              ),
              errorBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: const BorderSide(color: AppColors.hot, width: 2),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _label(BuildContext context, String text) => Text(
        text.toUpperCase(),
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          color: AppColors.hint(context),
          letterSpacing: 1,
        ),
      );

  Widget _statusChip(String value, String label, Color color) {
    final selected = _status == value;
    return GestureDetector(
      onTap: () => setState(() => _status = value),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        decoration: BoxDecoration(
          color: selected ? color : color.withOpacity(0.1),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: color, width: 1.5),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w800,
            color: selected ? Colors.white : color,
            letterSpacing: 0.5,
          ),
        ),
      ),
    );
  }
}

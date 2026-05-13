import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/l10n/app_l10n.dart';
import '../../core/theme/app_colors.dart';
import '../../models/contact.dart';
import '../../providers/auth_provider.dart';
import '../../providers/contacts_provider.dart';
import '../../providers/organization_provider.dart';
import '../../services/contact_import_export_service.dart';
import '../../services/storage_service.dart';

class ImportExportScreen extends ConsumerStatefulWidget {
  const ImportExportScreen({super.key});

  @override
  ConsumerState<ImportExportScreen> createState() => _ImportExportScreenState();
}

class _ImportExportScreenState extends ConsumerState<ImportExportScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tab;
  CrmExportFormat _crmFormat = CrmExportFormat.generic;
  bool _isLoading = false;
  String? _resultMessage;
  bool _resultIsError = false;
  bool _showCsvGuide = false;
  bool _showVcardGuide = false;
  bool _showTxtGuide = false;

  @override
  void initState() {
    super.initState();
    _tab = TabController(length: 2, vsync: this);
  }

  @override
  void dispose() {
    _tab.dispose();
    super.dispose();
  }

  // ─── Import flow ──────────────────────────────────────────────────────────

  Future<void> _pickAndImport(List<String> extensions) async {
    _clearResult();
    FilePickerResult? result;
    try {
      result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: extensions,
        withData: true,
      );
    } catch (_) {
      _setResult(ref.read(l10nProvider).importError, isError: true);
      return;
    }
    if (result == null || result.files.isEmpty) return;

    final file = result.files.first;
    final String content;
    try {
      content = file.bytes != null
          ? String.fromCharCodes(file.bytes!)
          : await File(file.path!).readAsString();
    } catch (_) {
      _setResult(ref.read(l10nProvider).importError, isError: true);
      return;
    }

    setState(() => _isLoading = true);

    final ext = (file.extension ?? '').toLowerCase();
    await _doImport(content, ext);
  }

  Future<void> _doImport(String content, String ext) async {
    final l10n = ref.read(l10nProvider);
    final ownerId = StorageService.currentUser?.id ?? '';

    List<Contact> parsed;
    try {
      if (ext == 'vcf' || ext == 'vcard') {
        parsed = ContactImportExportService.importFromVCard(content, ownerId);
      } else if (ext == 'txt') {
        parsed = ContactImportExportService.importFromTxt(content, ownerId);
      } else {
        parsed = ContactImportExportService.importFromCsv(content, ownerId);
      }
    } catch (_) {
      setState(() => _isLoading = false);
      _setResult(l10n.importError, isError: true);
      return;
    }

    setState(() => _isLoading = false);

    if (parsed.isEmpty) {
      _setResult(l10n.importNoContacts, isError: true);
      return;
    }

    if (!mounted) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => _ImportPreviewDialog(contacts: parsed, l10n: l10n),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _isLoading = true);

    int created = 0, skipped = 0;
    var hitLimit = false;
    final notifier = ref.read(contactsProvider.notifier);
    for (final contact in parsed) {
      try {
        final res = await notifier.addContact(contact);
        if (res.isSuccess) {
          created++;
        } else {
          skipped++;
          if (res.error == ContactsNotifier.freeContactLimitError) {
            hitLimit = true;
          }
        }
      } catch (_) {
        skipped++;
      }
    }

    setState(() => _isLoading = false);
    if (created == 0 && hitLimit) {
      _setResult(l10n.freeContactLimitReached, isError: true);
    } else {
      _setResult(l10n.importSuccess(created, skipped));
    }
  }

  // ─── Export flow ──────────────────────────────────────────────────────────

  Future<void> _export(String fileType) async {
    _clearResult();
    final l10n = ref.read(l10nProvider);
    final canExportOrgContacts = ref.read(orgCanExportContactsProvider);
    final allContacts = ref.read(contactsProvider).contacts;
    final contacts = canExportOrgContacts
        ? allContacts
        : allContacts
            .where((c) => c.ownerId == StorageService.currentUser?.id)
            .toList();

    if (contacts.isEmpty) {
      _setResult(l10n.exportNoContacts, isError: true);
      return;
    }

    setState(() => _isLoading = true);

    try {
      final ts = DateFormat('yyyyMMdd_HHmmss').format(DateTime.now());
      String content;
      String filename;

      if (fileType == 'csv') {
        content = ContactImportExportService.exportToCsv(
          contacts,
          format: _crmFormat,
        );
        filename = 'me2leads_contacts_${_crmFormat.name}_$ts.csv';
      } else if (fileType == 'vcf') {
        content = ContactImportExportService.exportToVCard(contacts);
        filename = 'me2leads_contacts_$ts.vcf';
      } else {
        content = ContactImportExportService.exportToTxt(contacts);
        filename = 'me2leads_contacts_$ts.txt';
      }

      final file =
          await ContactImportExportService.writeExportFile(content, filename);

      if (!mounted) return;
      await SharePlus.instance.share(
        ShareParams(
          files: [XFile(file.path, mimeType: _mimeType(fileType))],
          subject: 'Me2Leads — Contacts Export',
        ),
      );

      if (!mounted) return;
      _setResult(l10n.exportSuccess(contacts.length));
    } catch (_) {
      _setResult(l10n.exportError, isError: true);
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  String _mimeType(String ext) {
    switch (ext) {
      case 'csv':
        return 'text/csv';
      case 'vcf':
        return 'text/vcard';
      default:
        return 'text/plain';
    }
  }

  // ─── State helpers ────────────────────────────────────────────────────────

  void _setResult(String message, {bool isError = false}) {
    if (!mounted) return;
    setState(() {
      _resultMessage = message;
      _resultIsError = isError;
    });
  }

  void _clearResult() {
    if (_resultMessage != null) setState(() => _resultMessage = null);
  }

  String _crmLabel(AppL10n l10n, CrmExportFormat f) {
    switch (f) {
      case CrmExportFormat.generic:
        return l10n.crmFormatGeneric;
      case CrmExportFormat.salesforce:
        return 'Salesforce';
      case CrmExportFormat.odoo:
        return 'Odoo';
      case CrmExportFormat.sap:
        return 'SAP';
    }
  }

  // ─── Build ────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final l10n = ref.watch(l10nProvider);
    final isFreePlan = ref
        .watch(effectivePlanProvider)
        .maybeWhen(data: (plan) => plan == 'free', orElse: () => true);
    final canCreate = ref.watch(orgCanCreateProvider);

    return Scaffold(
      backgroundColor: AppColors.bg(context),
      body: Column(
        children: [
          _buildHeader(context, l10n),
          if (_resultMessage != null) _buildResultBanner(context),
          Expanded(
            child: TabBarView(
              controller: _tab,
              children: [
                _buildImportTab(context, l10n, canCreate: canCreate),
                _buildExportTab(context, l10n, isFreePlan),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ─── Header ───────────────────────────────────────────────────────────────

  Widget _buildHeader(BuildContext context, AppL10n l10n) {
    return Container(
      padding: EdgeInsets.only(
        top: MediaQuery.of(context).padding.top + 8,
        left: 16,
        right: 16,
        bottom: 0,
      ),
      decoration: const BoxDecoration(
        gradient: AppColors.primaryGradient,
        borderRadius: BorderRadius.only(
          bottomLeft: Radius.circular(24),
          bottomRight: Radius.circular(24),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              GestureDetector(
                onTap: () => Navigator.of(context).pop(),
                child: Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.15),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Icon(
                    Icons.arrow_back_ios_new_rounded,
                    color: Colors.white,
                    size: 16,
                  ),
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      l10n.importExportTitle,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 20,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    Text(
                      l10n.importExportSubtitle,
                      style: TextStyle(
                        color: Colors.white.withOpacity(0.6),
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
              if (_isLoading)
                const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(
                    color: Colors.white,
                    strokeWidth: 2,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 16),
          TabBar(
            controller: _tab,
            indicatorColor: AppColors.accent,
            indicatorWeight: 3,
            labelColor: Colors.white,
            unselectedLabelColor: Colors.white54,
            labelStyle:
                const TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
            tabs: [
              Tab(text: l10n.importTab),
              Tab(text: l10n.exportTab),
            ],
          ),
        ],
      ),
    );
  }

  // ─── Result banner ────────────────────────────────────────────────────────

  Widget _buildResultBanner(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: _resultIsError
            ? AppColors.hot.withOpacity(0.08)
            : AppColors.success.withOpacity(0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: _resultIsError
              ? AppColors.hot.withOpacity(0.25)
              : AppColors.success.withOpacity(0.25),
        ),
      ),
      child: Row(
        children: [
          Icon(
            _resultIsError
                ? Icons.error_outline_rounded
                : Icons.check_circle_outline_rounded,
            color: _resultIsError ? AppColors.hot : AppColors.success,
            size: 20,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              _resultMessage!,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: _resultIsError ? AppColors.hot : AppColors.success,
              ),
            ),
          ),
          GestureDetector(
            onTap: _clearResult,
            child: Icon(
              Icons.close_rounded,
              color: AppColors.hint(context),
              size: 18,
            ),
          ),
        ],
      ),
    );
  }

  // ─── Import tab ───────────────────────────────────────────────────────────

  Widget _buildImportTab(BuildContext context, AppL10n l10n,
      {required bool canCreate}) {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 40),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _sectionHeader(
            context,
            l10n.importSection,
            l10n.importSectionDesc,
            Icons.upload_file_rounded,
            AppColors.primary,
          ),
          const SizedBox(height: 16),
          _formatCard(
            context,
            icon: Icons.table_chart_rounded,
            color: AppColors.success,
            title: 'CSV',
            subtitle: l10n.csvImportDesc,
            onTap: canCreate
                ? () => _pickAndImport(['csv', 'tsv'])
                : () => _setResult(l10n.importCreatePrivilegeLocked,
                    isError: true),
          ),
          const SizedBox(height: 8),
          _guideToggle(
            context,
            label: _showCsvGuide ? l10n.csvGuideHideBtn : l10n.csvGuideShowBtn,
            color: AppColors.success,
            onTap: () => setState(() => _showCsvGuide = !_showCsvGuide),
            expanded: _showCsvGuide,
          ),
          AnimatedSize(
            duration: const Duration(milliseconds: 250),
            curve: Curves.easeInOut,
            alignment: Alignment.topCenter,
            child: _showCsvGuide
                ? _CsvFormatGuide(l10n: l10n)
                : const SizedBox.shrink(),
          ),
          const SizedBox(height: 10),
          _formatCard(
            context,
            icon: Icons.contact_page_rounded,
            color: AppColors.primary,
            title: 'vCard (.vcf)',
            subtitle: l10n.vcardImportDesc,
            onTap: canCreate
                ? () => _pickAndImport(['vcf', 'vcard'])
                : () => _setResult(l10n.importCreatePrivilegeLocked,
                    isError: true),
          ),
          const SizedBox(height: 8),
          _guideToggle(
            context,
            label: _showVcardGuide
                ? l10n.vcardGuideHideBtn
                : l10n.vcardGuideShowBtn,
            color: AppColors.primary,
            onTap: () => setState(() => _showVcardGuide = !_showVcardGuide),
            expanded: _showVcardGuide,
          ),
          AnimatedSize(
            duration: const Duration(milliseconds: 250),
            curve: Curves.easeInOut,
            alignment: Alignment.topCenter,
            child: _showVcardGuide
                ? _VcardFormatGuide(l10n: l10n)
                : const SizedBox.shrink(),
          ),
          const SizedBox(height: 10),
          _formatCard(
            context,
            icon: Icons.text_snippet_rounded,
            color: AppColors.warm,
            title: 'TXT',
            subtitle: l10n.txtImportDesc,
            onTap: canCreate
                ? () => _pickAndImport(['txt'])
                : () => _setResult(l10n.importCreatePrivilegeLocked,
                    isError: true),
          ),
          const SizedBox(height: 8),
          _guideToggle(
            context,
            label: _showTxtGuide ? l10n.txtGuideHideBtn : l10n.txtGuideShowBtn,
            color: AppColors.warm,
            onTap: () => setState(() => _showTxtGuide = !_showTxtGuide),
            expanded: _showTxtGuide,
          ),
          AnimatedSize(
            duration: const Duration(milliseconds: 250),
            curve: Curves.easeInOut,
            alignment: Alignment.topCenter,
            child: _showTxtGuide
                ? _TxtFormatGuide(l10n: l10n)
                : const SizedBox.shrink(),
          ),
          const SizedBox(height: 24),
          _infoBox(
            context,
            canCreate
                ? l10n.importInfoBox
                : l10n.importCreatePrivilegeLockedInfo,
          ),
        ],
      ),
    );
  }

  // ─── Export tab ───────────────────────────────────────────────────────────

  Widget _buildExportTab(BuildContext context, AppL10n l10n, bool isFreePlan) {
    final contactCount = ref.watch(contactsProvider).contacts.length;

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 40),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _sectionHeader(
            context,
            l10n.exportSection,
            l10n.exportSectionDesc(contactCount),
            Icons.download_rounded,
            AppColors.accent,
          ),
          const SizedBox(height: 20),
          // CRM format selector
          Text(
            l10n.crmFormatLabel.toUpperCase(),
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              color: AppColors.hint(context),
              letterSpacing: 1,
            ),
          ),
          const SizedBox(height: 10),
          _crmFormatSelector(context, l10n),
          const SizedBox(height: 22),
          Text(
            l10n.exportFormatLabel.toUpperCase(),
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              color: AppColors.hint(context),
              letterSpacing: 1,
            ),
          ),
          const SizedBox(height: 10),
          _formatCard(
            context,
            icon: Icons.table_chart_rounded,
            color: AppColors.success,
            title: 'CSV',
            subtitle: l10n.csvExportDesc(_crmLabel(l10n, _crmFormat)),
            onTap: isFreePlan
                ? () => _setResult(l10n.exportPlanLocked, isError: true)
                : () => _export('csv'),
          ),
          const SizedBox(height: 10),
          _formatCard(
            context,
            icon: Icons.contact_page_rounded,
            color: AppColors.primary,
            title: 'vCard (.vcf)',
            subtitle: l10n.vcardExportDesc,
            onTap: isFreePlan
                ? () => _setResult(l10n.exportPlanLocked, isError: true)
                : () => _export('vcf'),
          ),
          const SizedBox(height: 10),
          _formatCard(
            context,
            icon: Icons.text_snippet_rounded,
            color: AppColors.warm,
            title: 'TXT',
            subtitle: l10n.txtExportDesc,
            onTap: isFreePlan
                ? () => _setResult(l10n.exportPlanLocked, isError: true)
                : () => _export('txt'),
          ),
          const SizedBox(height: 24),
          _infoBox(
            context,
            isFreePlan ? l10n.exportPlanLockedInfo : l10n.exportInfoBox,
          ),
        ],
      ),
    );
  }

  // ─── Shared widgets ───────────────────────────────────────────────────────

  Widget _sectionHeader(BuildContext context, String title, String subtitle,
      IconData icon, Color color) {
    return Row(
      children: [
        Container(
          width: 46,
          height: 46,
          decoration: BoxDecoration(
            color: color.withOpacity(0.12),
            borderRadius: BorderRadius.circular(14),
          ),
          child: Icon(icon, color: color, size: 22),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w800,
                  color: AppColors.onSurface(context),
                ),
              ),
              Text(
                subtitle,
                style: TextStyle(
                  fontSize: 12,
                  color: AppColors.secondary(context),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _crmFormatSelector(BuildContext context, AppL10n l10n) {
    final options = [
      (CrmExportFormat.generic, l10n.crmFormatGeneric, Icons.code_rounded),
      (CrmExportFormat.salesforce, 'Salesforce', Icons.cloud_rounded),
      (CrmExportFormat.odoo, 'Odoo', Icons.shopping_bag_rounded),
      (CrmExportFormat.sap, 'SAP', Icons.business_center_rounded),
    ];

    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: options.map((opt) {
        final isSelected = _crmFormat == opt.$1;
        return GestureDetector(
          onTap: () => setState(() => _crmFormat = opt.$1),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            decoration: BoxDecoration(
              color: isSelected
                  ? AppColors.primary
                  : AppColors.surfaceColor(context),
              borderRadius: BorderRadius.circular(22),
              border: Border.all(
                color: isSelected
                    ? AppColors.primary
                    : AppColors.borderColor(context),
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  opt.$3,
                  size: 14,
                  color:
                      isSelected ? Colors.white : AppColors.secondary(context),
                ),
                const SizedBox(width: 6),
                Text(
                  opt.$2,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: isSelected
                        ? Colors.white
                        : AppColors.onSurface(context),
                  ),
                ),
              ],
            ),
          ),
        );
      }).toList(),
    );
  }

  Widget _formatCard(
    BuildContext context, {
    required IconData icon,
    required Color color,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
  }) {
    return Material(
      color: AppColors.surfaceColor(context),
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        onTap: _isLoading ? null : onTap,
        borderRadius: BorderRadius.circular(14),
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: AppColors.borderColor(context)),
          ),
          child: Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: color.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(icon, color: color, size: 22),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                        color: _isLoading
                            ? AppColors.hint(context)
                            : AppColors.onSurface(context),
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: TextStyle(
                        fontSize: 12,
                        color: AppColors.secondary(context),
                      ),
                    ),
                  ],
                ),
              ),
              Icon(
                Icons.arrow_forward_ios_rounded,
                color: AppColors.hint(context),
                size: 14,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _infoBox(BuildContext context, String text) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.primary.withOpacity(0.05),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.primary.withOpacity(0.15)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            Icons.info_outline_rounded,
            color: AppColors.primary.withOpacity(0.7),
            size: 18,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                fontSize: 12,
                color: AppColors.secondary(context),
                height: 1.5,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _guideToggle(
    BuildContext context, {
    required String label,
    required Color color,
    required VoidCallback onTap,
    required bool expanded,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              expanded
                  ? Icons.keyboard_arrow_up_rounded
                  : Icons.keyboard_arrow_down_rounded,
              size: 18,
              color: color,
            ),
            const SizedBox(width: 4),
            Text(
              label,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: color,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Import preview dialog ────────────────────────────────────────────────────

class _ImportPreviewDialog extends StatelessWidget {
  final List<Contact> contacts;
  final AppL10n l10n;

  const _ImportPreviewDialog({
    required this.contacts,
    required this.l10n,
  });

  @override
  Widget build(BuildContext context) {
    final preview = contacts.length > 5 ? contacts.sublist(0, 5) : contacts;
    final extra = contacts.length - preview.length;

    return Dialog(
      backgroundColor: AppColors.surfaceColor(context),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: AppColors.primary.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Icon(
                    Icons.upload_file_rounded,
                    color: AppColors.primary,
                    size: 20,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    l10n.importPreviewTitle,
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w800,
                      color: AppColors.onSurface(context),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            Text(
              l10n.importPreviewDesc(contacts.length),
              style: TextStyle(
                fontSize: 13,
                color: AppColors.secondary(context),
              ),
            ),
            const SizedBox(height: 12),
            Container(
              decoration: BoxDecoration(
                color: AppColors.bg(context),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: AppColors.borderColor(context)),
              ),
              child: ListView.separated(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                padding: const EdgeInsets.all(8),
                itemCount: preview.length,
                separatorBuilder: (_, __) => Divider(
                  height: 1,
                  color: AppColors.borderColor(context),
                ),
                itemBuilder: (_, i) {
                  final c = preview[i];
                  return Padding(
                    padding:
                        const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
                    child: Row(
                      children: [
                        Container(
                          width: 30,
                          height: 30,
                          decoration: BoxDecoration(
                            color: AppColors.primary.withOpacity(0.1),
                            shape: BoxShape.circle,
                          ),
                          child: Center(
                            child: Text(
                              c.initials.isEmpty ? '?' : c.initials,
                              style: const TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w700,
                                color: AppColors.primary,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                c.fullName.isEmpty ? '—' : c.fullName,
                                style: TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                  color: AppColors.onSurface(context),
                                ),
                              ),
                              if (c.subtitle.isNotEmpty)
                                Text(
                                  c.subtitle,
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: AppColors.secondary(context),
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
            if (extra > 0)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  l10n.importPreviewMore(extra),
                  style: TextStyle(
                    fontSize: 12,
                    color: AppColors.hint(context),
                  ),
                ),
              ),
            const SizedBox(height: 20),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => Navigator.pop(context, false),
                    child: Text(l10n.cancel),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: ElevatedButton(
                    onPressed: () => Navigator.pop(context, true),
                    child: Text(l10n.confirmImport),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// ─── TXT format guide ─────────────────────────────────────────────────────────

class _TxtFormatGuide extends StatelessWidget {
  final AppL10n l10n;

  const _TxtFormatGuide({required this.l10n});

  // Field definitions: (name, required, description_en, description_fr)
  static const _fields = [
    ('First Name:', false, 'Contact first name', 'Prénom du contact'),
    ('Last Name:', true, 'Contact last name', 'Nom de famille du contact'),
    ('Job Title:', false, 'Position or role', 'Poste ou fonction'),
    ('Company:', false, 'Company or organisation', 'Société ou organisation'),
    (
      'Phone:',
      false,
      'Phone number (required if no email)',
      'Téléphone (obligatoire si pas d\'email)'
    ),
    (
      'Email:',
      false,
      'Email address (required if no phone)',
      'Email (obligatoire si pas de téléphone)'
    ),
    (
      'Status:',
      false,
      'Hot Lead / Warm Lead / Cold Lead',
      'Hot Lead / Warm Lead / Cold Lead'
    ),
    (
      'Source:',
      false,
      'Where the contact was met',
      'Lieu ou événement de rencontre'
    ),
    (
      'Tags:',
      false,
      'Comma-separated labels',
      'Étiquettes séparées par des virgules'
    ),
    ('Notes:', false, 'Free-form notes', 'Notes libres'),
  ];

  static const _template = '''--- Contact 1 ---
First Name: Jean
Last Name: Dupont
Job Title: CEO
Company: Acme Corp
Phone: +33 6 12 34 56 78
Email: jean.dupont@acme.com
Status: Hot Lead
Source: Tech Conference 2024
Tags: VIP, Partner
Notes: Met at the annual conference

--- Contact 2 ---
First Name: Marie
Last Name: Martin
Phone: +33 7 98 76 54 32
Status: Warm Lead''';

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(top: 4),
      decoration: BoxDecoration(
        color: AppColors.surfaceColor(context),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.warm.withOpacity(0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              color: AppColors.warm.withOpacity(0.08),
              borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(13),
                topRight: Radius.circular(13),
              ),
            ),
            child: Row(
              children: [
                const Icon(Icons.text_snippet_rounded,
                    color: AppColors.warm, size: 18),
                const SizedBox(width: 8),
                Text(
                  l10n.txtGuideTitle,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w800,
                    color: AppColors.onSurface(context),
                  ),
                ),
                const SizedBox(width: 6),
                Text(
                  '·  ${l10n.txtGuideSubtitle}',
                  style: TextStyle(
                    fontSize: 11,
                    color: AppColors.secondary(context),
                  ),
                ),
              ],
            ),
          ),

          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Template block
                _sectionLabel(context, l10n.txtGuideTemplateLabel),
                const SizedBox(height: 8),
                _templateBlock(context),

                const SizedBox(height: 16),

                // Fields reference
                _sectionLabel(context, l10n.txtGuideFieldsLabel),
                const SizedBox(height: 8),
                _fieldsTable(context),

                const SizedBox(height: 16),

                // Notes
                _noteRow(context, l10n.txtGuideSeparatorNote),
                const SizedBox(height: 6),
                _noteRow(context, l10n.txtGuidePhoneEmailNote),
                const SizedBox(height: 6),
                _noteRow(context, l10n.txtGuideStatusNote),
                const SizedBox(height: 6),
                _noteRow(context, l10n.txtGuideTagsNote),
                const SizedBox(height: 6),
                _noteRow(context, l10n.txtGuideMultiNote),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _sectionLabel(BuildContext context, String text) {
    return Text(
      text.toUpperCase(),
      style: TextStyle(
        fontSize: 10,
        fontWeight: FontWeight.w700,
        color: AppColors.hint(context),
        letterSpacing: 0.8,
      ),
    );
  }

  Widget _templateBlock(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.bg(context),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.borderColor(context)),
      ),
      child: SelectableText(
        _template,
        style: const TextStyle(
          fontFamily: 'monospace',
          fontSize: 11.5,
          height: 1.7,
          color: AppColors.primary,
          fontWeight: FontWeight.w500,
        ),
      ),
    );
  }

  Widget _fieldsTable(BuildContext context) {
    final isEn = l10n.isEnglish;
    return Column(
      children: _fields.map((f) {
        final name = f.$1;
        final required = f.$2;
        final desc = isEn ? f.$3 : f.$4;
        return Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Field name
              SizedBox(
                width: 120,
                child: Text(
                  name,
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 11.5,
                    fontWeight: FontWeight.w700,
                    color: AppColors.primary,
                  ),
                ),
              ),
              // Required / optional badge
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: required
                      ? AppColors.hot.withOpacity(0.1)
                      : AppColors.cold.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  required ? l10n.txtGuideRequired : l10n.txtGuideOptional,
                  style: TextStyle(
                    fontSize: 9,
                    fontWeight: FontWeight.w700,
                    color: required ? AppColors.hot : AppColors.cold,
                    letterSpacing: 0.4,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              // Description
              Expanded(
                child: Text(
                  desc,
                  style: TextStyle(
                    fontSize: 11.5,
                    color: AppColors.secondary(context),
                    height: 1.4,
                  ),
                ),
              ),
            ],
          ),
        );
      }).toList(),
    );
  }

  Widget _noteRow(BuildContext context, String text) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Padding(
          padding: EdgeInsets.only(top: 3),
          child: Icon(
            Icons.circle,
            size: 5,
            color: AppColors.warm,
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            text,
            style: TextStyle(
              fontSize: 12,
              color: AppColors.secondary(context),
              height: 1.5,
            ),
          ),
        ),
      ],
    );
  }
}

// ─── CSV format guide ─────────────────────────────────────────────────────────

class _CsvFormatGuide extends StatelessWidget {
  final AppL10n l10n;
  const _CsvFormatGuide({required this.l10n});

  // (field label, generic header, Salesforce header, Odoo header, SAP header, required)
  static const _columns = [
    ('First name', 'first_name', 'First Name', 'name *', 'FIRST_NAME', false),
    ('Last name', 'last_name', 'Last Name', 'name *', 'LAST_NAME', true),
    ('Job title', 'job_title', 'Title', 'function', 'POSITION', false),
    ('Company', 'company', 'Company', 'company_name', 'COMPANY', false),
    ('Phone', 'phone', 'Phone', 'phone', 'PHONE', false),
    ('Email', 'email', 'Email', 'email', 'EMAIL', false),
    ('Status', 'status', 'Rating', 'x_me2leads_status', 'PRIORITY', false),
    ('Notes', 'notes', 'Description', 'comment', 'NOTES', false),
    ('Source', 'source', 'Lead Source', 'source', 'SOURCE', false),
    ('Tags', 'tags', 'Tags', 'category_id', 'CATEGORY', false),
  ];

  static const _template =
      'first_name,last_name,job_title,company,phone,email,status,source,notes,tags\n'
      'Jean,Dupont,CEO,Acme Corp,+33612345678,jean@acme.com,hot,Conference,Notes here,VIP;Partner';

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(top: 4),
      decoration: BoxDecoration(
        color: AppColors.surfaceColor(context),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.success.withOpacity(0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              color: AppColors.success.withOpacity(0.08),
              borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(13),
                topRight: Radius.circular(13),
              ),
            ),
            child: Row(
              children: [
                const Icon(Icons.table_chart_rounded,
                    color: AppColors.success, size: 18),
                const SizedBox(width: 8),
                Text(
                  l10n.csvGuideTitle,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w800,
                    color: AppColors.onSurface(context),
                  ),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    '·  ${l10n.csvGuideSubtitle}',
                    style: TextStyle(
                        fontSize: 11, color: AppColors.secondary(context)),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _label(context, l10n.csvGuideTemplateLabel),
                const SizedBox(height: 8),
                _templateBlock(context),
                const SizedBox(height: 16),
                _label(context, l10n.csvGuideColumnsLabel),
                const SizedBox(height: 8),
                _columnsTable(context),
                const SizedBox(height: 16),
                _noteRow(context, l10n.csvGuideHeaderNote),
                const SizedBox(height: 6),
                _noteRow(context, l10n.csvGuideAutoDetectNote),
                const SizedBox(height: 6),
                _noteRow(context, l10n.csvGuidePhoneEmailNote),
                const SizedBox(height: 6),
                _noteRow(context, l10n.csvGuideFullNameNote),
                const SizedBox(height: 6),
                _noteRow(context, l10n.csvGuideStatusNote),
                const SizedBox(height: 6),
                _noteRow(context, l10n.csvGuideTsvNote),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _label(BuildContext context, String text) => Text(
        text.toUpperCase(),
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w700,
          color: AppColors.hint(context),
          letterSpacing: 0.8,
        ),
      );

  Widget _templateBlock(BuildContext context) => Container(
        width: double.infinity,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: AppColors.bg(context),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: AppColors.borderColor(context)),
        ),
        child: SelectableText(
          _template,
          style: const TextStyle(
            fontFamily: 'monospace',
            fontSize: 11,
            height: 1.7,
            color: AppColors.success,
            fontWeight: FontWeight.w500,
          ),
        ),
      );

  Widget _columnsTable(BuildContext context) {
    final isEn = l10n.isEnglish;
    final headerStyle = TextStyle(
      fontSize: 9,
      fontWeight: FontWeight.w700,
      color: AppColors.hint(context),
      letterSpacing: 0.5,
    );
    final cellStyle = TextStyle(
      fontFamily: 'monospace',
      fontSize: 10,
      color: AppColors.onSurface(context),
    );

    Widget hcell(String t) => Expanded(
        child: Text(t, style: headerStyle, overflow: TextOverflow.ellipsis));
    Widget dcell(String t) => Expanded(
        child: Text(t, style: cellStyle, overflow: TextOverflow.ellipsis));

    return Container(
      decoration: BoxDecoration(
        color: AppColors.bg(context),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.borderColor(context)),
      ),
      child: Column(
        children: [
          // Header row
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: AppColors.borderColor(context).withOpacity(0.5),
              borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(9),
                topRight: Radius.circular(9),
              ),
            ),
            child: Row(children: [
              hcell(isEn ? 'FIELD' : 'CHAMP'),
              hcell('GENERIC'),
              hcell('SALESFORCE'),
              hcell('ODOO'),
              hcell('SAP'),
            ]),
          ),
          // Data rows
          ...List.generate(_columns.length, (i) {
            final c = _columns[i];
            final isLast = i == _columns.length - 1;
            return Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: BoxDecoration(
                border: isLast
                    ? null
                    : Border(
                        bottom: BorderSide(
                          color: AppColors.borderColor(context),
                          width: 0.5,
                        ),
                      ),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Row(children: [
                      Text(
                        c.$1,
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.w600,
                          color: AppColors.secondary(context),
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                      if (c.$6) ...[
                        const SizedBox(width: 3),
                        const Text('*',
                            style: TextStyle(
                                fontSize: 10,
                                fontWeight: FontWeight.w800,
                                color: AppColors.hot)),
                      ],
                    ]),
                  ),
                  dcell(c.$2),
                  dcell(c.$3),
                  dcell(c.$4),
                  dcell(c.$5),
                ],
              ),
            );
          }),
        ],
      ),
    );
  }

  Widget _noteRow(BuildContext context, String text) => Padding(
        padding: const EdgeInsets.only(bottom: 0),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Padding(
              padding: EdgeInsets.only(top: 4),
              child: Icon(Icons.circle, size: 5, color: AppColors.success),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                text,
                style: TextStyle(
                  fontSize: 12,
                  color: AppColors.secondary(context),
                  height: 1.5,
                ),
              ),
            ),
          ],
        ),
      );
}

// ─── vCard format guide ───────────────────────────────────────────────────────

class _VcardFormatGuide extends StatelessWidget {
  final AppL10n l10n;
  const _VcardFormatGuide({required this.l10n});

  // (property, example, description_en, description_fr, required)
  static const _props = [
    ('FN:', 'Jean Dupont', 'Full display name', 'Nom complet affiché', false),
    (
      'N:',
      'Dupont;Jean;;;',
      'Structured name — N:Last;First;;;',
      'Nom structuré — N:Nom;Prénom;;;',
      false
    ),
    (
      'ORG:',
      'Acme Corp',
      'Company or organisation',
      'Société ou organisation',
      false
    ),
    ('TITLE:', 'CEO', 'Job title or role', 'Poste ou fonction', false),
    (
      'TEL;TYPE=WORK,VOICE:',
      '+33612345678',
      'Phone number',
      'Numéro de téléphone',
      false
    ),
    (
      'EMAIL;TYPE=WORK:',
      'jean@acme.com',
      'Email address',
      'Adresse email',
      false
    ),
    ('NOTE:', 'Met at conference', 'Free-form notes', 'Notes libres', false),
    (
      'CATEGORIES:',
      'VIP,Partner',
      'Tags, comma-separated',
      'Tags, séparés par des virgules',
      false
    ),
    (
      'X-ME2LEADS-STATUS:',
      'hot',
      'hot / warm / cold',
      'hot / warm / cold',
      false
    ),
    (
      'X-ME2LEADS-SOURCE:',
      'Conference 2024',
      'Contact source',
      'Source du contact',
      false
    ),
  ];

  static const _template = 'BEGIN:VCARD\n'
      'VERSION:3.0\n'
      'FN:Jean Dupont\n'
      'N:Dupont;Jean;;;\n'
      'ORG:Acme Corp\n'
      'TITLE:CEO\n'
      'TEL;TYPE=WORK,VOICE:+33612345678\n'
      'EMAIL;TYPE=WORK:jean@acme.com\n'
      'NOTE:Met at the annual conference\n'
      'CATEGORIES:VIP,Partner\n'
      'X-ME2LEADS-STATUS:hot\n'
      'X-ME2LEADS-SOURCE:Conference 2024\n'
      'END:VCARD';

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(top: 4),
      decoration: BoxDecoration(
        color: AppColors.surfaceColor(context),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.primary.withOpacity(0.25)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              color: AppColors.primary.withOpacity(0.07),
              borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(13),
                topRight: Radius.circular(13),
              ),
            ),
            child: Row(
              children: [
                const Icon(Icons.contact_page_rounded,
                    color: AppColors.primary, size: 18),
                const SizedBox(width: 8),
                Text(
                  l10n.vcardGuideTitle,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w800,
                    color: AppColors.onSurface(context),
                  ),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    '·  ${l10n.vcardGuideSubtitle}',
                    style: TextStyle(
                        fontSize: 11, color: AppColors.secondary(context)),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _label(context, l10n.vcardGuideTemplateLabel),
                const SizedBox(height: 8),
                _templateBlock(context),
                const SizedBox(height: 16),
                _label(context, l10n.vcardGuidePropsLabel),
                const SizedBox(height: 8),
                _propsTable(context),
                const SizedBox(height: 16),
                _noteRow(context, l10n.vcardGuideNameNote),
                const SizedBox(height: 6),
                _noteRow(context, l10n.vcardGuidePhoneEmailNote),
                const SizedBox(height: 6),
                _noteRow(context, l10n.vcardGuideStatusNote),
                const SizedBox(height: 6),
                _noteRow(context, l10n.vcardGuideFoldingNote),
                const SizedBox(height: 6),
                _noteRow(context, l10n.vcardGuideMultiNote),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _label(BuildContext context, String text) => Text(
        text.toUpperCase(),
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w700,
          color: AppColors.hint(context),
          letterSpacing: 0.8,
        ),
      );

  Widget _templateBlock(BuildContext context) => Container(
        width: double.infinity,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: AppColors.bg(context),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: AppColors.borderColor(context)),
        ),
        child: SelectableText(
          _template,
          style: const TextStyle(
            fontFamily: 'monospace',
            fontSize: 11,
            height: 1.7,
            color: AppColors.primary,
            fontWeight: FontWeight.w500,
          ),
        ),
      );

  Widget _propsTable(BuildContext context) {
    final isEn = l10n.isEnglish;
    return Container(
      decoration: BoxDecoration(
        color: AppColors.bg(context),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.borderColor(context)),
      ),
      child: Column(
        children: List.generate(_props.length, (i) {
          final p = _props[i];
          final isLast = i == _props.length - 1;
          return Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
            decoration: BoxDecoration(
              border: isLast
                  ? null
                  : Border(
                      bottom: BorderSide(
                        color: AppColors.borderColor(context),
                        width: 0.5,
                      ),
                    ),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 148,
                  child: Text(
                    p.$1,
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 10.5,
                      fontWeight: FontWeight.w700,
                      color: AppColors.primary,
                    ),
                  ),
                ),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        isEn ? p.$3 : p.$4,
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: AppColors.onSurface(context),
                        ),
                      ),
                      Text(
                        'e.g. ${p.$2}',
                        style: TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 10,
                          color: AppColors.secondary(context),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          );
        }),
      ),
    );
  }

  Widget _noteRow(BuildContext context, String text) => Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.only(top: 4),
            child: Icon(Icons.circle, size: 5, color: AppColors.primary),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                fontSize: 12,
                color: AppColors.secondary(context),
                height: 1.5,
              ),
            ),
          ),
        ],
      );
}

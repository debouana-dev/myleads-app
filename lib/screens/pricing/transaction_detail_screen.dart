import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

import '../../core/l10n/app_l10n.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_theme.dart';
import '../../models/organization.dart';
import '../../models/user_account.dart';
import '../../providers/currency_provider.dart';
import '../../providers/organization_provider.dart';
import '../../providers/settings_provider.dart';
import '../../services/encryption_service.dart';
import '../../services/storage_service.dart';

class TransactionDetailScreen extends ConsumerWidget {
  final PaymentRecord record;

  const TransactionDetailScreen({super.key, required this.record});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = ref.watch(l10nProvider);
    final currency = ref.watch(settingsProvider).currency;
    final eurToUsd = ref.watch(eurToUsdRateProvider);
    final orgState = ref.watch(organizationProvider);

    final user = StorageService.currentUser;
    final org = record.accountType == 'organization' ? orgState.organization : null;

    final paidAt = DateTime.tryParse(record.createdAt) ?? DateTime.now();
    final validUntil = _computeValidUntil(paidAt, org);
    final displayAmount = _formatAmount(record.amount, record.currency, currency, eurToUsd);
    final userEmail = user != null ? EncryptionService.decryptText(user.email) : '';
    final userName = user?.fullName ?? '';

    return Scaffold(
      backgroundColor: AppColors.bg(context),
      body: Column(
        children: [
          _Header(
            l10n: l10n,
            onExport: () => _exportPdf(
              context,
              l10n: l10n,
              user: user,
              userEmail: userEmail,
              org: org,
              paidAt: paidAt,
              validUntil: validUntil,
              displayAmount: displayAmount,
              currency: currency,
              eurToUsd: eurToUsd,
            ),
          ),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 40),
              child: _ReceiptCard(
                record: record,
                l10n: l10n,
                paidAt: paidAt,
                validUntil: validUntil,
                displayAmount: displayAmount,
                userName: userName,
                userEmail: userEmail,
                org: org,
                onExport: () => _exportPdf(
                  context,
                  l10n: l10n,
                  user: user,
                  userEmail: userEmail,
                  org: org,
                  paidAt: paidAt,
                  validUntil: validUntil,
                  displayAmount: displayAmount,
                  currency: currency,
                  eurToUsd: eurToUsd,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  DateTime _computeValidUntil(DateTime paidAt, Organization? org) {
    if (record.plan == 'business' && org?.orgPlanExpiresAt != null) {
      return org!.orgPlanExpiresAt!;
    }
    if (record.billingCycle == 'yearly') {
      return DateTime(paidAt.year + 1, paidAt.month, paidAt.day);
    }
    return DateTime(paidAt.year, paidAt.month + 1, paidAt.day);
  }

  String _formatAmount(
      double amt, String storedCurrency, AppCurrency pref, double rate) {
    final isEur = pref == AppCurrency.eur || storedCurrency != 'USD';
    return isEur
        ? '${amt.toStringAsFixed(2)}€'
        : '\$${(amt * rate).toStringAsFixed(2)}';
  }

  Future<void> _exportPdf(
    BuildContext context, {
    required AppL10n l10n,
    required UserAccount? user,
    required String userEmail,
    required Organization? org,
    required DateTime paidAt,
    required DateTime validUntil,
    required String displayAmount,
    required AppCurrency currency,
    required double eurToUsd,
  }) async {
    Uint8List? logoBytes;
    try {
      final data = await rootBundle.load('assets/icons/app_logo.png');
      logoBytes = data.buffer.asUint8List();
    } catch (_) {}

    final doc = pw.Document();
    doc.addPage(
      pw.Page(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.all(40),
        build: (pw.Context ctx) => _buildPdfContent(
          ctx,
          l10n: l10n,
          user: user,
          userEmail: userEmail,
          org: org,
          paidAt: paidAt,
          validUntil: validUntil,
          displayAmount: displayAmount,
          logoBytes: logoBytes,
        ),
      ),
    );

    final fileName =
        'me2leads_receipt_${record.id.substring(0, 8).toUpperCase()}.pdf';
    await Printing.sharePdf(bytes: await doc.save(), filename: fileName);
  }

  pw.Widget _buildPdfContent(
    pw.Context ctx, {
    required AppL10n l10n,
    required UserAccount? user,
    required String userEmail,
    required Organization? org,
    required DateTime paidAt,
    required DateTime validUntil,
    required String displayAmount,
    required Uint8List? logoBytes,
  }) {
    const navy = PdfColor.fromInt(0xFF0B3C5D);
    const gold = PdfColor.fromInt(0xFFD4AF37);
    const lightGrey = PdfColor.fromInt(0xFFF0F2F5);
    const textDark = PdfColor.fromInt(0xFF1A1A2E);
    const textMid = PdfColor.fromInt(0xFF5A5A7A);
    const borderCol = PdfColor.fromInt(0xFFE8EAF0);
    const successCol = PdfColor.fromInt(0xFF27AE60);
    const errorCol = PdfColor.fromInt(0xFFE74C3C);
    const warningCol = PdfColor.fromInt(0xFFF39C12);

    final statusColor = record.status == 'succeeded'
        ? successCol
        : record.status == 'failed'
            ? errorCol
            : warningCol;
    final statusLabel = record.status == 'succeeded'
        ? l10n.statusPaid.toUpperCase()
        : record.status == 'failed'
            ? l10n.statusFailed.toUpperCase()
            : l10n.statusPending.toUpperCase();
    final planLabel =
        record.plan[0].toUpperCase() + record.plan.substring(1);
    final cycleLabel = record.billingCycle == 'yearly'
        ? l10n.billingCycleYearly
        : l10n.billingCycleMonthly;
    final methodLabel = _methodLabelRaw(record.paymentMethod, l10n);
    final unitPrice = (org != null && org.licenseCount > 0)
        ? record.amount / org.licenseCount
        : record.amount;

    pw.Widget logoSection;
    if (logoBytes != null) {
      logoSection = pw.Row(
        crossAxisAlignment: pw.CrossAxisAlignment.center,
        children: [
          pw.Image(pw.MemoryImage(logoBytes), width: 40, height: 40),
          pw.SizedBox(width: 10),
          pw.Text(
            'Me2Leads',
            style: pw.TextStyle(
              fontSize: 22,
              fontWeight: pw.FontWeight.bold,
              color: navy,
            ),
          ),
        ],
      );
    } else {
      logoSection = pw.Text(
        'Me2Leads',
        style: pw.TextStyle(
            fontSize: 22, fontWeight: pw.FontWeight.bold, color: navy),
      );
    }

    pw.Widget divider() => pw.Container(
          height: 1,
          color: borderCol,
          margin: const pw.EdgeInsets.symmetric(vertical: 10),
        );

    pw.Widget infoRow(String label, String value, {bool bold = false}) =>
        pw.Padding(
          padding: const pw.EdgeInsets.symmetric(vertical: 5),
          child: pw.Row(
            mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
            children: [
              pw.Text(label,
                  style: pw.TextStyle(fontSize: 11, color: textMid)),
              pw.Text(value,
                  style: pw.TextStyle(
                      fontSize: 11,
                      color: textDark,
                      fontWeight: bold ? pw.FontWeight.bold : null)),
            ],
          ),
        );

    pw.Widget sectionHeader(String title) => pw.Padding(
          padding: const pw.EdgeInsets.only(top: 14, bottom: 6),
          child: pw.Text(
            title.toUpperCase(),
            style: pw.TextStyle(
              fontSize: 9,
              fontWeight: pw.FontWeight.bold,
              color: textMid,
              letterSpacing: 1,
            ),
          ),
        );

    final now = DateTime.now();
    final generatedOn =
        '${now.day.toString().padLeft(2, '0')}/${now.month.toString().padLeft(2, '0')}/${now.year}';

    return pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        // Header band
        pw.Container(
          padding: const pw.EdgeInsets.all(16),
          decoration: pw.BoxDecoration(
            color: navy,
            borderRadius: const pw.BorderRadius.all(pw.Radius.circular(8)),
          ),
          child: pw.Row(
            mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
            children: [
              logoSection,
              pw.Container(
                padding:
                    const pw.EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                decoration: pw.BoxDecoration(
                  color: statusColor,
                  borderRadius:
                      const pw.BorderRadius.all(pw.Radius.circular(4)),
                ),
                child: pw.Text(
                  statusLabel,
                  style: pw.TextStyle(
                    color: PdfColors.white,
                    fontWeight: pw.FontWeight.bold,
                    fontSize: 10,
                  ),
                ),
              ),
            ],
          ),
        ),
        pw.SizedBox(height: 20),

        // Amount
        pw.Container(
          width: double.infinity,
          padding: const pw.EdgeInsets.symmetric(vertical: 16),
          decoration: pw.BoxDecoration(
            color: lightGrey,
            borderRadius: const pw.BorderRadius.all(pw.Radius.circular(8)),
          ),
          child: pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.center,
            children: [
              pw.Text(
                displayAmount,
                style: pw.TextStyle(
                  fontSize: 32,
                  fontWeight: pw.FontWeight.bold,
                  color: navy,
                ),
              ),
              pw.SizedBox(height: 4),
              pw.Text(
                l10n.transactionDetails,
                style: pw.TextStyle(fontSize: 11, color: textMid),
              ),
            ],
          ),
        ),
        pw.SizedBox(height: 16),

        // Transaction info
        sectionHeader(l10n.transactionDetails),
        pw.Container(
          padding: const pw.EdgeInsets.all(12),
          decoration: pw.BoxDecoration(
            border: pw.Border.all(color: borderCol),
            borderRadius: const pw.BorderRadius.all(pw.Radius.circular(6)),
          ),
          child: pw.Column(
            children: [
              infoRow(l10n.plan, planLabel, bold: true),
              divider(),
              infoRow(
                  l10n.accountTypeLabel,
                  record.accountType == 'organization'
                      ? l10n.accountTypeOrganization
                      : l10n.accountTypeIndividual),
              divider(),
              infoRow(l10n.billingCycleLabel, cycleLabel),
              divider(),
              infoRow(l10n.date, _formatDateTimePdf(paidAt, l10n)),
              divider(),
              infoRow(l10n.validUntil, _formatDatePdf(validUntil, l10n)),
              divider(),
              infoRow(l10n.amount, displayAmount, bold: true),
              divider(),
              infoRow(l10n.paymentMethodLabel, methodLabel),
            ],
          ),
        ),
        pw.SizedBox(height: 12),

        // Payer info
        sectionHeader(org != null ? l10n.receiptAdministrator : l10n.paidBy),
        pw.Container(
          padding: const pw.EdgeInsets.all(12),
          decoration: pw.BoxDecoration(
            border: pw.Border.all(color: borderCol),
            borderRadius: const pw.BorderRadius.all(pw.Radius.circular(6)),
          ),
          child: pw.Column(
            children: [
              infoRow(l10n.fullName, user?.fullName ?? '—', bold: true),
              divider(),
              infoRow('Email', userEmail.isNotEmpty ? userEmail : '—'),
            ],
          ),
        ),

        // Org details (business only)
        if (org != null) ...[
          pw.SizedBox(height: 12),
          sectionHeader(l10n.organizationDetails),
          pw.Container(
            padding: const pw.EdgeInsets.all(12),
            decoration: pw.BoxDecoration(
              border: pw.Border.all(color: borderCol),
              borderRadius: const pw.BorderRadius.all(pw.Radius.circular(6)),
            ),
            child: pw.Column(
              children: [
                infoRow(l10n.organization, org.name, bold: true),
                divider(),
                infoRow(l10n.numberOfLicenses, org.licenseCount.toString()),
                divider(),
                infoRow(l10n.unitPrice, _formatAmountRaw(unitPrice, record.currency)),
              ],
            ),
          ),
        ],

        pw.SizedBox(height: 16),
        divider(),

        // Footer
        pw.Row(
          mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
          children: [
            pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: [
                pw.Text(
                  '${l10n.transactionId}: ${record.transactionId.isNotEmpty ? record.transactionId : record.id.substring(0, 10).toUpperCase()}',
                  style: pw.TextStyle(fontSize: 8, color: textMid),
                ),
                pw.SizedBox(height: 3),
                pw.Text(
                  'Generated by Me2Leads · $generatedOn',
                  style: pw.TextStyle(fontSize: 8, color: textMid),
                ),
              ],
            ),
            pw.Container(
              width: 10,
              height: 10,
              decoration: pw.BoxDecoration(
                  color: gold,
                  shape: pw.BoxShape.circle),
            ),
          ],
        ),
      ],
    );
  }

  String _formatDateTimePdf(DateTime d, AppL10n l10n) {
    return DateFormat('dd MMM yyyy · HH:mm', l10n.isEnglish ? 'en' : 'fr')
        .format(d);
  }

  String _formatDatePdf(DateTime d, AppL10n l10n) {
    return DateFormat('dd MMM yyyy', l10n.isEnglish ? 'en' : 'fr').format(d);
  }

  String _formatAmountRaw(double amt, String storedCurrency) {
    return storedCurrency == 'USD'
        ? '\$${amt.toStringAsFixed(2)}'
        : '${amt.toStringAsFixed(2)}€';
  }

  String _methodLabelRaw(String method, AppL10n l10n) {
    switch (method) {
      case 'card':
        return l10n.paymentMethodCard;
      case 'link':
        return l10n.paymentMethodLink;
      case 'amazon_pay':
        return l10n.paymentMethodAmazonPay;
      case 'apple_pay':
        return l10n.paymentMethodApplePay;
      case 'google_pay':
        return l10n.paymentMethodGooglePay;
      default:
        return method.isNotEmpty ? method : l10n.paymentMethodCard;
    }
  }
}

// ─── Header ───────────────────────────────────────────────────────────────────

class _Header extends StatelessWidget {
  final AppL10n l10n;
  final VoidCallback onExport;

  const _Header({required this.l10n, required this.onExport});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
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
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          GestureDetector(
            onTap: () => Navigator.of(context).pop(),
            child: Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.12),
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Icon(Icons.arrow_back_rounded,
                  color: Colors.white, size: 20),
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Text(
              l10n.transactionDetails,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 20,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
          GestureDetector(
            onTap: onExport,
            child: Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.12),
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Icon(Icons.picture_as_pdf_rounded,
                  color: Colors.white, size: 20),
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Receipt card ─────────────────────────────────────────────────────────────

class _ReceiptCard extends StatelessWidget {
  final PaymentRecord record;
  final AppL10n l10n;
  final DateTime paidAt;
  final DateTime validUntil;
  final String displayAmount;
  final String userName;
  final String userEmail;
  final Organization? org;
  final VoidCallback onExport;

  const _ReceiptCard({
    required this.record,
    required this.l10n,
    required this.paidAt,
    required this.validUntil,
    required this.displayAmount,
    required this.userName,
    required this.userEmail,
    required this.org,
    required this.onExport,
  });

  @override
  Widget build(BuildContext context) {
    final statusColor = _statusColor(record.status);
    final statusLabel = _statusLabel(record.status, l10n);
    final planLabel =
        record.plan[0].toUpperCase() + record.plan.substring(1);
    final cycleLabel = record.billingCycle == 'yearly'
        ? l10n.billingCycleYearly
        : l10n.billingCycleMonthly;
    final unitPrice = (org != null && org!.licenseCount > 0)
        ? record.amount / org!.licenseCount
        : record.amount;
    final txId = record.transactionId.isNotEmpty
        ? record.transactionId
        : record.id.substring(0, 10).toUpperCase();

    return Container(
      decoration: BoxDecoration(
        color: AppColors.surfaceColor(context),
        borderRadius: BorderRadius.circular(16),
        boxShadow: AppTheme.cardShadow,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Brand band ──
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              gradient: AppColors.primaryGradient,
              borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(16),
                topRight: Radius.circular(16),
              ),
            ),
            child: Row(
              children: [
                Image.asset(
                  'assets/icons/app_logo.png',
                  width: 36,
                  height: 36,
                  errorBuilder: (_, __, ___) => Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      color: Colors.white.withOpacity(0.2),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Icon(Icons.receipt_rounded,
                        color: Colors.white, size: 20),
                  ),
                ),
                const SizedBox(width: 10),
                const Expanded(
                  child: Text(
                    'Me2Leads',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 0.5,
                    ),
                  ),
                ),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                  decoration: BoxDecoration(
                    color: statusColor,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    statusLabel,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
          ),

          Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // ── Amount ──
                Center(
                  child: Column(
                    children: [
                      Text(
                        displayAmount,
                        style: TextStyle(
                          fontSize: 38,
                          fontWeight: FontWeight.w800,
                          color: AppColors.onSurface(context),
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        l10n.amount,
                        style: TextStyle(
                          fontSize: 12,
                          color: AppColors.hint(context),
                        ),
                      ),
                    ],
                  ),
                ),

                const SizedBox(height: 20),
                _divider(context),
                const SizedBox(height: 16),

                // ── Transaction info rows ──
                _infoRow(context, l10n.plan, planLabel, bold: true),
                _rowDivider(context),
                _infoRow(context, l10n.accountTypeLabel,
                    record.accountType == 'organization'
                        ? l10n.accountTypeOrganization
                        : l10n.accountTypeIndividual),
                _rowDivider(context),
                _infoRow(context, l10n.billingCycleLabel, cycleLabel),
                _rowDivider(context),
                _infoRow(context, l10n.date, _formatDateTime(paidAt, l10n)),
                _rowDivider(context),
                _infoRow(
                    context, l10n.validUntil, _formatDate(validUntil, l10n)),
                _rowDivider(context),
                _infoRow(
                    context,
                    l10n.paymentMethodLabel,
                    _methodLabel(record.paymentMethod, l10n)),

                const SizedBox(height: 16),
                _divider(context),
                const SizedBox(height: 16),

                // ── Paid by section ──
                _sectionHeader(context,
                    org != null ? l10n.receiptAdministrator : l10n.paidBy),
                const SizedBox(height: 10),
                _infoRow(context, l10n.fullName, userName.isNotEmpty ? userName : '—', bold: true),
                _rowDivider(context),
                _infoRow(context, 'Email',
                    userEmail.isNotEmpty ? userEmail : '—'),

                // ── Org section (business only) ──
                if (org != null) ...[
                  const SizedBox(height: 16),
                  _divider(context),
                  const SizedBox(height: 16),
                  _sectionHeader(context, l10n.organizationDetails),
                  const SizedBox(height: 10),
                  _infoRow(context, l10n.organization, org!.name,
                      bold: true),
                  _rowDivider(context),
                  _infoRow(context, l10n.numberOfLicenses,
                      org!.licenseCount.toString()),
                  _rowDivider(context),
                  _infoRow(
                    context,
                    l10n.unitPrice,
                    _formatAmountRaw(unitPrice, record.currency),
                  ),
                ],

                const SizedBox(height: 16),
                _divider(context),
                const SizedBox(height: 12),

                // ── Transaction ID ──
                Row(
                  children: [
                    Icon(Icons.tag_rounded,
                        size: 13, color: AppColors.hint(context)),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        txId,
                        style: TextStyle(
                          fontSize: 11,
                          color: AppColors.hint(context),
                          fontFamily: 'monospace',
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),

                const SizedBox(height: 24),

                // ── Export button ──
                SizedBox(
                  width: double.infinity,
                  height: 50,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: AppColors.accentGradient,
                      borderRadius: BorderRadius.circular(14),
                      boxShadow: AppTheme.accentShadow,
                    ),
                    child: ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.transparent,
                        shadowColor: Colors.transparent,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                      ),
                      onPressed: onExport,
                      icon: const Icon(Icons.picture_as_pdf_rounded,
                          color: Colors.white, size: 18),
                      label: Text(
                        l10n.exportAsPdf,
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w700,
                          fontSize: 14,
                        ),
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

  Widget _divider(BuildContext context) => Container(
        height: 1,
        color: AppColors.borderColor(context),
      );

  Widget _rowDivider(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Container(height: 1, color: AppColors.borderColor(context)),
      );

  Widget _sectionHeader(BuildContext context, String title) => Text(
        title.toUpperCase(),
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w700,
          color: AppColors.hint(context),
          letterSpacing: 1,
        ),
      );

  Widget _infoRow(BuildContext context, String label, String value,
      {bool bold = false}) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          label,
          style: TextStyle(
            fontSize: 13,
            color: AppColors.hint(context),
          ),
        ),
        Flexible(
          child: Text(
            value,
            textAlign: TextAlign.end,
            style: TextStyle(
              fontSize: 13,
              fontWeight: bold ? FontWeight.w700 : FontWeight.w600,
              color: AppColors.onSurface(context),
            ),
          ),
        ),
      ],
    );
  }

  Color _statusColor(String s) {
    switch (s) {
      case 'succeeded':
        return AppColors.success;
      case 'failed':
        return AppColors.error;
      default:
        return AppColors.warning;
    }
  }

  String _statusLabel(String s, AppL10n l10n) {
    switch (s) {
      case 'succeeded':
        return l10n.statusPaid.toUpperCase();
      case 'failed':
        return l10n.statusFailed.toUpperCase();
      default:
        return l10n.statusPending.toUpperCase();
    }
  }

  String _formatDateTime(DateTime d, AppL10n l10n) {
    return DateFormat('dd MMM yyyy · HH:mm', l10n.isEnglish ? 'en' : 'fr')
        .format(d);
  }

  String _formatDate(DateTime d, AppL10n l10n) {
    return DateFormat('dd MMM yyyy', l10n.isEnglish ? 'en' : 'fr').format(d);
  }

  String _formatAmountRaw(double amt, String storedCurrency) {
    return storedCurrency == 'USD'
        ? '\$${amt.toStringAsFixed(2)}'
        : '${amt.toStringAsFixed(2)}€';
  }

  String _methodLabel(String method, AppL10n l10n) {
    switch (method) {
      case 'card':
        return l10n.paymentMethodCard;
      case 'link':
        return l10n.paymentMethodLink;
      case 'amazon_pay':
        return l10n.paymentMethodAmazonPay;
      case 'apple_pay':
        return l10n.paymentMethodApplePay;
      case 'google_pay':
        return l10n.paymentMethodGooglePay;
      default:
        return method.isNotEmpty ? method : l10n.paymentMethodCard;
    }
  }
}

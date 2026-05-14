import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/l10n/app_l10n.dart';
import '../../core/theme/app_colors.dart';
import '../../models/user_account.dart';
import '../../providers/currency_provider.dart';
import '../../providers/settings_provider.dart';
import '../../services/database_service.dart';
import '../../services/storage_service.dart';

enum _DateFilter { allTime, thisMonth, last3Months, last6Months, thisYear, others }

class PaymentHistoryScreen extends ConsumerStatefulWidget {
  const PaymentHistoryScreen({super.key});

  @override
  ConsumerState<PaymentHistoryScreen> createState() =>
      _PaymentHistoryScreenState();
}

class _PaymentHistoryScreenState extends ConsumerState<PaymentHistoryScreen> {
  _DateFilter _filter = _DateFilter.allTime;
  late Future<List<PaymentRecord>> _recordsFuture;

  @override
  void initState() {
    super.initState();
    _recordsFuture =
        DatabaseService.getPaymentHistory(StorageService.currentUserId);
  }

  List<_Transaction> _toTransactions(List<PaymentRecord> records) {
    return records.map((r) {
      _TxStatus status;
      switch (r.status) {
        case 'succeeded':
          status = _TxStatus.paid;
          break;
        case 'failed':
          status = _TxStatus.failed;
          break;
        default:
          status = _TxStatus.pending;
      }
      return _Transaction(
        id: r.transactionId.isNotEmpty
            ? r.transactionId
            : r.id.substring(0, 8).toUpperCase(),
        plan: r.plan[0].toUpperCase() + r.plan.substring(1),
        billingCycle: r.billingCycle,
        amount: r.amount,
        currency: r.currency,
        date: DateTime.tryParse(r.createdAt) ?? DateTime.now(),
        status: status,
        paymentMethod: r.paymentMethod,
        accountType: r.accountType,
        record: r,
      );
    }).toList();
  }

  List<_Transaction> _filtered(List<_Transaction> all) {
    final now = DateTime.now();
    return all.where((tx) {
      switch (_filter) {
        case _DateFilter.allTime:
          return true;
        case _DateFilter.thisMonth:
          return tx.date.year == now.year && tx.date.month == now.month;
        case _DateFilter.last3Months:
          return tx.date.isAfter(now.subtract(const Duration(days: 90)));
        case _DateFilter.last6Months:
          return tx.date.isAfter(now.subtract(const Duration(days: 180)));
        case _DateFilter.thisYear:
          return tx.date.year == now.year;
        case _DateFilter.others:
          return tx.date.isBefore(now.subtract(const Duration(days: 365)));
      }
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = ref.watch(l10nProvider);
    final currency = ref.watch(settingsProvider).currency;
    final eurToUsd = ref.watch(eurToUsdRateProvider);

    return Scaffold(
      backgroundColor: AppColors.bg(context),
      body: Column(
        children: [
          // Header
          Container(
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
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
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
                const SizedBox(height: 16),
                Text(
                  l10n.paymentHistoryTitle,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 22,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  l10n.filterByDate,
                  style: TextStyle(
                    color: Colors.white.withOpacity(0.5),
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),

          // Filter chips
          Container(
            color: AppColors.bg(context),
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: _DateFilter.values.map((f) {
                  final label = _filterLabel(f, l10n);
                  final isSelected = _filter == f;
                  return Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: GestureDetector(
                      onTap: () => setState(() => _filter = f),
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 180),
                        padding: const EdgeInsets.symmetric(
                            horizontal: 14, vertical: 8),
                        decoration: BoxDecoration(
                          gradient:
                              isSelected ? AppColors.primaryGradient : null,
                          color: isSelected
                              ? null
                              : AppColors.surfaceColor(context),
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(
                            color: isSelected
                                ? AppColors.primary
                                : AppColors.borderColor(context),
                          ),
                        ),
                        child: Text(
                          label,
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                            color: isSelected
                                ? Colors.white
                                : AppColors.secondary(context),
                          ),
                        ),
                      ),
                    ),
                  );
                }).toList(),
              ),
            ),
          ),

          // Transactions list — loaded from SQLite
          Expanded(
            child: FutureBuilder<List<PaymentRecord>>(
              future: _recordsFuture,
              builder: (context, snapshot) {
                if (snapshot.connectionState == ConnectionState.waiting) {
                  return const Center(child: CircularProgressIndicator());
                }
                final all = _toTransactions(snapshot.data ?? []);
                final transactions = _filtered(all);

                if (transactions.isEmpty) {
                  return _EmptyState(l10n: l10n);
                }
                return ListView.separated(
                  padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
                  itemCount: transactions.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 10),
                  itemBuilder: (context, i) => _TransactionCard(
                    transaction: transactions[i],
                    currency: currency,
                    eurToUsd: eurToUsd,
                    l10n: l10n,
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  String _filterLabel(_DateFilter f, AppL10n l10n) {
    switch (f) {
      case _DateFilter.allTime:
        return l10n.allTime;
      case _DateFilter.thisMonth:
        return l10n.thisMonth;
      case _DateFilter.last3Months:
        return l10n.last3Months;
      case _DateFilter.last6Months:
        return l10n.last6Months;
      case _DateFilter.thisYear:
        return l10n.thisYear;
      case _DateFilter.others:
        return l10n.olderThanYear;
    }
  }
}

// ─── Empty state ─────────────────────────────────────────────────────────────

class _EmptyState extends StatelessWidget {
  final AppL10n l10n;
  const _EmptyState({required this.l10n});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 72,
              height: 72,
              decoration: BoxDecoration(
                color: AppColors.primary.withOpacity(0.08),
                borderRadius: BorderRadius.circular(24),
              ),
              child: const Icon(
                Icons.receipt_long_rounded,
                size: 36,
                color: AppColors.primary,
              ),
            ),
            const SizedBox(height: 20),
            Text(
              l10n.noPayments,
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w700,
                color: AppColors.onSurface(context),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              l10n.noPaymentsDesc,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 13,
                color: AppColors.secondary(context),
                height: 1.5,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Transaction card ─────────────────────────────────────────────────────────

class _TransactionCard extends StatelessWidget {
  final _Transaction transaction;
  final AppCurrency currency;
  final double eurToUsd;
  final AppL10n l10n;

  const _TransactionCard({
    required this.transaction,
    required this.currency,
    required this.eurToUsd,
    required this.l10n,
  });

  @override
  Widget build(BuildContext context) {
    final isEur = currency == AppCurrency.eur || transaction.currency != 'USD';
    final displayAmount = isEur
        ? '${transaction.amount.toStringAsFixed(2)}€'
        : '\$${(transaction.amount * eurToUsd).toStringAsFixed(2)}';
    final statusColor = _statusColor(transaction.status);
    final statusLabel = _statusLabel(transaction.status, l10n);
    final cycleLabel = transaction.billingCycle == 'yearly'
        ? l10n.billingCycleYearly
        : l10n.billingCycleMonthly;

    return GestureDetector(
      onTap: () =>
          context.push('/transaction-details', extra: transaction.record),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: AppColors.surfaceColor(context),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: AppColors.borderColor(context)),
        ),
        child: Row(
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: AppColors.primary.withOpacity(0.08),
                borderRadius: BorderRadius.circular(14),
              ),
              child: const Icon(
                Icons.receipt_rounded,
                size: 22,
                color: AppColors.primary,
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Row(
                        children: [
                          Text(
                            transaction.plan,
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w700,
                              color: AppColors.onSurface(context),
                            ),
                          ),
                          const SizedBox(width: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: AppColors.primary.withOpacity(0.08),
                              borderRadius: BorderRadius.circular(5),
                            ),
                            child: Text(
                              cycleLabel,
                              style: TextStyle(
                                fontSize: 9,
                                fontWeight: FontWeight.w700,
                                color: AppColors.primary,
                              ),
                            ),
                          ),
                          const SizedBox(width: 4),
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: transaction.accountType == 'organization'
                                  ? AppColors.accent.withOpacity(0.12)
                                  : AppColors.info.withOpacity(0.10),
                              borderRadius: BorderRadius.circular(5),
                            ),
                            child: Row(
                              children: [
                                Icon(
                                  transaction.accountType == 'organization'
                                      ? Icons.groups_rounded
                                      : Icons.person_rounded,
                                  size: 9,
                                  color:
                                      transaction.accountType == 'organization'
                                          ? AppColors.accent
                                          : AppColors.info,
                                ),
                                const SizedBox(width: 3),
                                Text(
                                  transaction.accountType == 'organization'
                                      ? l10n.accountTypeOrganization
                                      : l10n.accountTypeIndividual,
                                  style: TextStyle(
                                    fontSize: 9,
                                    fontWeight: FontWeight.w700,
                                    color: transaction.accountType ==
                                            'organization'
                                        ? AppColors.accent
                                        : AppColors.info,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Row(
                        children: [
                          Text(
                            displayAmount,
                            style: const TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w800,
                              color: AppColors.primary,
                            ),
                          ),
                        ],
                      ),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(
                          color: statusColor.withOpacity(0.12),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          statusLabel,
                          style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.w700,
                            color: statusColor,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    _formatDateTime(transaction.date),
                    style: TextStyle(
                      fontSize: 12,
                      color: AppColors.secondary(context),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Color _statusColor(_TxStatus s) {
    switch (s) {
      case _TxStatus.paid:
        return AppColors.success;
      case _TxStatus.failed:
        return AppColors.error;
      case _TxStatus.pending:
        return AppColors.warning;
    }
  }

  String _statusLabel(_TxStatus s, AppL10n l10n) {
    switch (s) {
      case _TxStatus.paid:
        return l10n.statusPaid.toUpperCase();
      case _TxStatus.failed:
        return l10n.statusFailed.toUpperCase();
      case _TxStatus.pending:
        return l10n.statusPending.toUpperCase();
    }
  }

  String _formatDateTime(DateTime d) {
    const months = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    final h = d.hour.toString().padLeft(2, '0');
    final m = d.minute.toString().padLeft(2, '0');
    return '${d.day} ${months[d.month - 1]} ${d.year} · $h:$m';
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

// ─── Models ───────────────────────────────────────────────────────────────────

enum _TxStatus { paid, failed, pending }

class _Transaction {
  final String id;
  final String plan;
  final String billingCycle;
  final double amount;
  final String currency;
  final DateTime date;
  final _TxStatus status;
  final String paymentMethod;
  final String accountType;
  final PaymentRecord record;

  const _Transaction({
    required this.id,
    required this.plan,
    required this.billingCycle,
    required this.amount,
    required this.currency,
    required this.date,
    required this.status,
    required this.record,
    this.paymentMethod = 'card',
    this.accountType = 'individual',
  });
}

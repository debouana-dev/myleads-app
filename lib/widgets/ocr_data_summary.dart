import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../core/l10n/app_l10n.dart';
import '../core/theme/app_colors.dart';
import '../services/ocr_parser.dart';

/// Display widget for OCR extraction confidence and field summary.
///
/// [mlKitConfidence] is the weighted average from the ML Kit element
/// hierarchy (0.0–1.0). [fieldConfidences] maps field names to the
/// per-field confidence level returned by [OcrParser]. Together they
/// produce a blended score: 60% ML Kit signal + 40% parser quality.
class OcrDataSummary extends ConsumerWidget {
  final Map<String, String> ocrData;
  final double mlKitConfidence;
  final Map<String, FieldConfidence> fieldConfidences;
  final bool showConfidenceBar;

  const OcrDataSummary({
    super.key,
    required this.ocrData,
    this.mlKitConfidence = 0.0,
    this.fieldConfidences = const {},
    this.showConfidenceBar = true,
  });

  double _calculateConfidence() {
    final mlPart = mlKitConfidence * 0.6;
    if (fieldConfidences.isEmpty) return (mlPart * 100).clamp(0, 100);
    final avg = fieldConfidences.values
            .map((c) => switch (c) {
                  FieldConfidence.high => 1.0,
                  FieldConfidence.fair => 0.6,
                  FieldConfidence.low => 0.25,
                })
            .reduce((a, b) => a + b) /
        fieldConfidences.length;
    return ((mlPart + avg * 0.4) * 100).clamp(0, 100);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = ref.watch(l10nProvider);
    final confidence = _calculateConfidence();
    final confidenceLabel = confidence >= 75
        ? l10n.confidenceHigh
        : confidence >= 50
            ? l10n.confidenceFair
            : l10n.confidenceLow;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (showConfidenceBar) ...[
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                confidenceLabel,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: confidence >= 75
                      ? AppColors.success
                      : confidence >= 50
                          ? AppColors.warm
                          : AppColors.hot,
                ),
              ),
              Text(
                '${confidence.toStringAsFixed(0)}%',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: AppColors.hint(context),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: confidence / 100,
              minHeight: 6,
              backgroundColor: AppColors.borderColor(context),
              valueColor: AlwaysStoppedAnimation<Color>(
                confidence >= 75
                    ? AppColors.success
                    : confidence >= 50
                        ? AppColors.warm
                        : AppColors.hot,
              ),
            ),
          ),
          const SizedBox(height: 12),
        ],
        Wrap(
          spacing: 8,
          runSpacing: 4,
          children: [
            if (ocrData['firstName']?.isNotEmpty ?? false)
              _buildTag('👤 ${ocrData['firstName']}'),
            if (ocrData['lastName']?.isNotEmpty ?? false)
              _buildTag('${ocrData['lastName']}'),
            if (ocrData['email']?.isNotEmpty ?? false) _buildTag('✉️ Email'),
            if (ocrData['phone']?.isNotEmpty ?? false) _buildTag('📞 Phone'),
            if (ocrData['company']?.isNotEmpty ?? false)
              _buildTag(
                  '🏢 ${ocrData['company']?.substring(0, ocrData['company']!.length.clamp(0, 15))}${ocrData['company']!.length > 15 ? '...' : ''}'),
            if (ocrData['jobTitle']?.isNotEmpty ?? false)
              _buildTag(
                  '💼 ${ocrData['jobTitle']?.substring(0, ocrData['jobTitle']!.length.clamp(0, 12))}${ocrData['jobTitle']!.length > 12 ? '...' : ''}'),
          ],
        ),
      ],
    );
  }

  Widget _buildTag(String label) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: AppColors.accent.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: AppColors.accent.withValues(alpha: 0.3),
          width: 0.5,
        ),
      ),
      child: Text(
        label,
        style: const TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w500,
          color: AppColors.accent,
        ),
      ),
    );
  }
}

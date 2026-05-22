import 'package:flutter/material.dart';
import '../../core/theme/app_colors.dart';

/// Display widget for OCR extraction confidence and summary
class OcrDataSummary extends StatelessWidget {
  final Map<String, String> ocrData;
  final bool showConfidenceBar;

  const OcrDataSummary({
    super.key,
    required this.ocrData,
    this.showConfidenceBar = true,
  });

  int _countExtractedFields() {
    int count = 0;
    if (ocrData['firstName']?.isNotEmpty ?? false) count++;
    if (ocrData['lastName']?.isNotEmpty ?? false) count++;
    if (ocrData['email']?.isNotEmpty ?? false) count++;
    if (ocrData['phone']?.isNotEmpty ?? false) count++;
    if (ocrData['jobTitle']?.isNotEmpty ?? false) count++;
    if (ocrData['company']?.isNotEmpty ?? false) count++;
    return count;
  }

  double _calculateConfidence() {
    // Confidence based on extracted fields (0-100%)
    return (_countExtractedFields() / 6 * 100).clamp(0, 100);
  }

  @override
  Widget build(BuildContext context) {
    final confidence = _calculateConfidence();
    final confidenceLabel = confidence >= 75
        ? 'High confidence'
        : confidence >= 50
            ? 'Fair confidence'
            : 'Low confidence';

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
        // Show quick summary
        Wrap(
          spacing: 8,
          runSpacing: 4,
          children: [
            if (ocrData['firstName']?.isNotEmpty ?? false)
              _buildTag('👤 ${ocrData['firstName']}'),
            if (ocrData['lastName']?.isNotEmpty ?? false)
              _buildTag('${ocrData['lastName']}'),
            if (ocrData['email']?.isNotEmpty ?? false)
              _buildTag('✉️ Email'),
            if (ocrData['phone']?.isNotEmpty ?? false)
              _buildTag('📞 Phone'),
            if (ocrData['company']?.isNotEmpty ?? false)
              _buildTag('🏢 ${ocrData['company']?.substring(0, 15)}${ocrData['company']!.length > 15 ? '...' : ''}'),
            if (ocrData['jobTitle']?.isNotEmpty ?? false)
              _buildTag('💼 ${ocrData['jobTitle']?.substring(0, 12)}${ocrData['jobTitle']!.length > 12 ? '...' : ''}'),
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


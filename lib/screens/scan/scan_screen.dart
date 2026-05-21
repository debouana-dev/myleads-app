import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../core/l10n/app_l10n.dart';
import '../../core/theme/app_colors.dart';
import '../../providers/auth_provider.dart';
import '../../providers/organization_provider.dart';
import '../../services/ocr_parser.dart';
import '../../services/ocr_service_stub.dart'
    if (dart.library.io) '../../services/ocr_service_mobile.dart'
    as ocr_service;

/// Scan modes available in the capture screen.
enum ScanMode { card, qr, nfc }

class ScanScreen extends ConsumerStatefulWidget {
  /// If true, starts directly in QR mode (default).
  final bool startWithQr;

  const ScanScreen({super.key, this.startWithQr = true});

  @override
  ConsumerState<ScanScreen> createState() => _ScanScreenState();
}

class _ScanScreenState extends ConsumerState<ScanScreen>
    with SingleTickerProviderStateMixin {
  late ScanMode _mode;
  bool _flashOn = false;
  bool _isCapturing = false;

  late AnimationController _scanLineController;
  late Animation<double> _scanLineAnimation;

  MobileScannerController? _cameraController;

  // ----------------------------------------------------------
  // Lifecycle
  // ----------------------------------------------------------

  @override
  void initState() {
    super.initState();
    _mode = widget.startWithQr ? ScanMode.qr : ScanMode.card;

    _scanLineController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2400),
    )..repeat(reverse: true);

    _scanLineAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _scanLineController, curve: Curves.easeInOut),
    );

    _initCameraController();
  }

  @override
  void dispose() {
    _scanLineController.dispose();
    _disposeCameraController();
    super.dispose();
  }

  // ----------------------------------------------------------
  // Camera controller helpers
  // ----------------------------------------------------------

  void _initCameraController() {
    _disposeCameraController();
    try {
      _cameraController = MobileScannerController(
        detectionSpeed: DetectionSpeed.normal,
        facing: CameraFacing.back,
        torchEnabled: _flashOn,
      );
    } catch (_) {
      // Camera unavailable (simulator / permissions denied).
      _cameraController = null;
    }
  }

  void _disposeCameraController() {
    try {
      _cameraController?.dispose();
    } catch (_) {
      // Ignore disposal errors.
    }
    _cameraController = null;
  }


  // ----------------------------------------------------------
  // Flash toggle
  // ----------------------------------------------------------

  void _toggleFlash() {
    setState(() => _flashOn = !_flashOn);
    try {
      _cameraController?.toggleTorch();
    } catch (_) {}
  }

  // ----------------------------------------------------------
  // Capture actions
  // ----------------------------------------------------------

  void _onCapture() {
    if (_isCapturing) return;
    showScanOptions(context, ref);
  }

  /// Unified detect callback used by [MobileScanner] in all modes.
  ///
  /// In card mode, barcode detections are silently ignored so they do not
  /// hijack the OCR flow. In QR mode, detections are forwarded to
  /// [_onQrDetected].
  void _onDetect(BarcodeCapture capture) {
    if (_mode != ScanMode.qr) return;
    _onQrDetected(capture);
  }

  void _onQrDetected(BarcodeCapture capture) {
    if (_isCapturing) return;
    final barcodes = capture.barcodes;
    if (barcodes.isEmpty) return;

    setState(() => _isCapturing = true);
    _showStaticDetectionToast(context, ref);

    // Parse QR/barcode data — could be vCard or plain text.
    final raw = barcodes.first.rawValue ?? '';
    final ocrData = raw.isNotEmpty ? OcrParser.parse(raw) : <String, String>{};

    Future.delayed(const Duration(seconds: 1), () {
      if (mounted) {
        setState(() => _isCapturing = false);
        context.push('/review', extra: ocrData);
      }
    });
  }


  // ----------------------------------------------------------
  // Build
  // ----------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final l10n = ref.watch(l10nProvider);
    final bottomInset = (88.0 + MediaQuery.of(context).padding.bottom) / 4;

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          // Live camera preview — active in card and QR modes.
          if (_mode != ScanMode.nfc && _cameraController != null)
            MobileScanner(
              controller: _cameraController!,
              onDetect: _onDetect,
              errorBuilder: (context, error) {
                return Center(
                  child: Text(
                    l10n.cameraUnavailable,
                    style: const TextStyle(color: AppColors.white),
                  ),
                );
              },
            ),

          // Solid black background for NFC mode (no camera needed).
          if (_mode == ScanMode.nfc) Container(color: Colors.black),

          // Top bar
          _buildTopBar(context, l10n),

          // Viewport + scan line
          Center(child: _buildViewport()),

          // Hint text
          Positioned(
            bottom: 240 + bottomInset,
            left: 0,
            right: 0,
            child: Text(
              l10n.scanHint,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w500,
                color: AppColors.white.withOpacity(0.7),
              ),
            ),
          ),


          // Capture button
          Positioned(
            bottom: 56 + bottomInset,
            left: 0,
            right: 0,
            child: Center(child: _buildCaptureButton()),
          ),
        ],
      ),
    );
  }

  // ----------------------------------------------------------
  // Top bar
  // ----------------------------------------------------------

  Widget _buildTopBar(BuildContext context, AppL10n l10n) {
    final topPadding = MediaQuery.of(context).padding.top;

    return Positioned(
      top: topPadding + 8,
      left: 16,
      right: 16,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          // Back
          _CircleButton(
            icon: Icons.arrow_back_rounded,
            onTap: () => context.pop(),
          ),
          // Title
          Text(
            l10n.scanTitle,
            style: const TextStyle(
              fontSize: 17,
              fontWeight: FontWeight.w700,
              color: AppColors.white,
            ),
          ),
          // Flash toggle
          _CircleButton(
            icon: _flashOn ? Icons.flash_on_rounded : Icons.flash_off_rounded,
            active: _flashOn,
            onTap: _toggleFlash,
          ),
        ],
      ),
    );
  }

  // ----------------------------------------------------------
  // Scan viewport with corner brackets + animated line
  // ----------------------------------------------------------

  Widget _buildViewport() {
    const double viewportSize = 280;

    return SizedBox(
      width: viewportSize,
      height: viewportSize,
      child: AnimatedBuilder(
        animation: _scanLineAnimation,
        builder: (context, child) {
          return Stack(
            clipBehavior: Clip.none,
            children: [
              // 4 corner brackets
              ..._buildCornerBrackets(viewportSize),

              // Animated scan line
              Positioned(
                top: _scanLineAnimation.value * (viewportSize - 4),
                left: 20,
                right: 20,
                child: Container(
                  height: 2,
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: [
                        AppColors.accent.withOpacity(0),
                        AppColors.accent,
                        AppColors.accent.withOpacity(0),
                      ],
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: AppColors.accent.withOpacity(0.5),
                        blurRadius: 12,
                        spreadRadius: 2,
                      ),
                    ],
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  List<Widget> _buildCornerBrackets(double size) {
    const double bracketLength = 32;
    const double bracketThickness = 3;

    Widget bracket({
      required double top,
      required double left,
      required double right,
      required double bottom,
      required bool flipH,
      required bool flipV,
    }) {
      return Positioned(
        top: top == -1 ? null : top,
        left: left == -1 ? null : left,
        right: right == -1 ? null : right,
        bottom: bottom == -1 ? null : bottom,
        child: Transform(
          alignment: Alignment.center,
          transform: Matrix4.identity()
            ..scale(flipH ? -1.0 : 1.0, flipV ? -1.0 : 1.0),
          child: SizedBox(
            width: bracketLength,
            height: bracketLength,
            child: CustomPaint(
              painter: _CornerBracketPainter(
                color: AppColors.accent,
                strokeWidth: bracketThickness,
                radius: 6,
              ),
            ),
          ),
        ),
      );
    }

    return [
      // Top-left
      bracket(
          top: 0, left: 0, right: -1, bottom: -1, flipH: false, flipV: false),
      // Top-right
      bracket(
          top: 0, left: -1, right: 0, bottom: -1, flipH: true, flipV: false),
      // Bottom-left
      bracket(
          top: -1, left: 0, right: -1, bottom: 0, flipH: false, flipV: true),
      // Bottom-right
      bracket(top: -1, left: -1, right: 0, bottom: 0, flipH: true, flipV: true),
    ];
  }


  // ----------------------------------------------------------
  // Capture button
  // ----------------------------------------------------------

  Widget _buildCaptureButton() {
    return GestureDetector(
      onTap: _isCapturing ? null : _onCapture,
      child: AnimatedOpacity(
        duration: const Duration(milliseconds: 200),
        opacity: _isCapturing ? 0.5 : 1.0,
        child: Container(
          width: 76,
          height: 76,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(color: AppColors.white, width: 4),
          ),
          padding: const EdgeInsets.all(4),
          child: Container(
            decoration: const BoxDecoration(
              shape: BoxShape.circle,
              gradient: AppColors.accentGradient,
            ),
          ),
        ),
      ),
    );
  }

}

// ===========================================================================
// Supporting widgets
// ===========================================================================

/// Translucent circle button used in the top bar.
class _CircleButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  final bool active;

  const _CircleButton({
    required this.icon,
    required this.onTap,
    this.active = false,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 42,
        height: 42,
        decoration: BoxDecoration(
          color: active
              ? AppColors.accent.withOpacity(0.25)
              : AppColors.white.withOpacity(0.12),
          shape: BoxShape.circle,
        ),
        child: Icon(
          icon,
          color: active ? AppColors.accent : AppColors.white,
          size: 22,
        ),
      ),
    );
  }
}

// ===========================================================================
// Scan Options Modal
// ===========================================================================

Future<void> showScanOptions(BuildContext context, WidgetRef ref) async {
  final l10n = ref.read(l10nProvider);
  final isFreePlan = ref.read(effectivePlanProvider).maybeWhen(
        data: (plan) => plan == 'free',
        orElse: () => true,
      );
  final orgState = ref.read(organizationProvider);
  final isInActiveOrg = orgState.organization != null &&
      !orgState.isOrgExpired &&
      !orgState.isOrgSuspended;

  return showModalBottomSheet(
    context: context,
    backgroundColor: AppColors.cardDark,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
    ),
    builder: (modalContext) {
      return SafeArea(
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: AppColors.white.withOpacity(0.2),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(height: 24),
              _BottomSheetOption(
                icon: Icons.credit_card_rounded,
                title: l10n.scanCard,
                onTap: () {
                  Navigator.pop(modalContext);
                  captureBusinessCard(context, ref);
                },
              ),
              const SizedBox(height: 8),
              _BottomSheetOption(
                icon: Icons.qr_code_scanner_rounded,
                title: l10n.scanQR,
                enabled: !(isFreePlan && !isInActiveOrg),
                onTap: (isFreePlan && !isInActiveOrg)
                    ? () {
                        Navigator.pop(context);
                        context.push('/subscription-plan');
                      }
                    : () {
                        Navigator.pop(context);
                        context.push('/scan');
                      },
              ),
              const SizedBox(height: 16),
            ],
          ),
        ),
      );
    },
  );
}

class _BottomSheetOption extends StatelessWidget {
  final IconData icon;
  final String title;
  final VoidCallback onTap;
  final bool enabled;

  const _BottomSheetOption({
    required this.icon,
    required this.title,
    required this.onTap,
    this.enabled = true,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      onTap: onTap,
      leading: Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: AppColors.accent.withOpacity(0.1),
          shape: BoxShape.circle,
        ),
        child: Icon(
          icon,
          color: enabled ? AppColors.accent : AppColors.white.withOpacity(0.3),
        ),
      ),
      title: Text(
        title,
        style: TextStyle(
          color: enabled ? AppColors.white : AppColors.white.withOpacity(0.3),
          fontWeight: FontWeight.w600,
          fontSize: 16,
        ),
      ),
      trailing: !enabled
          ? const Icon(Icons.lock_rounded, color: AppColors.accent, size: 20)
          : null,
    );
  }
}

/// Captures a photo via the device camera, runs OCR, and navigates to review.
/// This can be called from anywhere.
Future<void> captureBusinessCard(BuildContext context, WidgetRef ref) async {
  try {
    Map<String, String> ocrData = {};

    if (!kIsWeb) {
      final picker = ImagePicker();
      final XFile? photo = await picker.pickImage(
        source: ImageSource.camera,
        preferredCameraDevice: CameraDevice.rear,
        imageQuality: 90, // Slightly higher quality for better OCR
      );

      if (photo != null) {
        // Ensure context is still valid before showing loader
        if (!context.mounted) return;

        showDialog(
          context: context,
          barrierDismissible: false,
          builder: (ctx) => const Center(
            child: CircularProgressIndicator(color: AppColors.accent),
          ),
        );

        try {
          final rawText = await ocr_service.recognizeTextFromFile(photo.path);
          
          if (context.mounted) Navigator.pop(context); // Close loading indicator

          if (rawText.isNotEmpty) {
            ocrData = OcrParser.parse(rawText);
            ocrData['photoPath'] = photo.path;
            
            if (context.mounted) _showStaticDetectionToast(context, ref);
          }
        } catch (e) {
          debugPrint('OCR Error: $e');
          if (context.mounted) Navigator.pop(context); // Ensure dialog is closed
        }
      } else {
        return; // User cancelled
      }
    }

    if (context.mounted) context.push('/review', extra: ocrData);
  } catch (_) {
    if (context.mounted) {
      // If we are still showing the loading dialog, close it
      try {
        Navigator.pop(context);
      } catch (_) {}
      context.push('/review', extra: <String, String>{});
    }
  }
}

void _showStaticDetectionToast(BuildContext context, WidgetRef ref) {
  final l10n = ref.read(l10nProvider);
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        content: Row(
          children: [
            const Icon(Icons.check_circle_rounded,
                color: AppColors.white, size: 20),
            const SizedBox(width: 10),
            Text(
              l10n.cardDetected,
              style: const TextStyle(
                fontWeight: FontWeight.w600,
                color: AppColors.white,
              ),
            ),
          ],
        ),
        backgroundColor: AppColors.success,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        margin: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
        duration: const Duration(milliseconds: 900),
      ),
    );
}


// ===========================================================================
// Corner bracket painter
// ===========================================================================

class _CornerBracketPainter extends CustomPainter {
  final Color color;
  final double strokeWidth;
  final double radius;

  _CornerBracketPainter({
    required this.color,
    required this.strokeWidth,
    required this.radius,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = strokeWidth
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;

    final path = Path()
      ..moveTo(0, size.height)
      ..lineTo(0, radius)
      ..arcToPoint(
        Offset(radius, 0),
        radius: Radius.circular(radius),
      )
      ..lineTo(size.width, 0);

    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(_CornerBracketPainter oldDelegate) =>
      oldDelegate.color != color ||
      oldDelegate.strokeWidth != strokeWidth ||
      oldDelegate.radius != radius;
}

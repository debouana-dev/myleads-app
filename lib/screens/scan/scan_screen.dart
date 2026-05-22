import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

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

  const ScanScreen({super.key, this.startWithQr = false});

  @override
  ConsumerState<ScanScreen> createState() => _ScanScreenState();
}

class _ScanScreenState extends ConsumerState<ScanScreen>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late ScanMode _mode;
  bool _flashOn = false;
  bool _isCapturing = false;

  late AnimationController _scanLineController;
  late Animation<double> _scanLineAnimation;

  // Controllers for different modes
  MobileScannerController? _qrController;
  CameraController? _cardCameraController;
  bool _isCardCameraInitialized = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _mode = widget.startWithQr ? ScanMode.qr : ScanMode.card;

    _scanLineController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2400),
    )..repeat(reverse: true);

    _scanLineAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _scanLineController, curve: Curves.easeInOut),
    );

    _initControllers();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _scanLineController.dispose();
    _disposeControllers();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final CameraController? cameraController = _cardCameraController;

    // App state changed before we got the chance to initialize.
    if (cameraController == null || !cameraController.value.isInitialized) {
      return;
    }

    if (state == AppLifecycleState.inactive) {
      cameraController.dispose();
    } else if (state == AppLifecycleState.resumed) {
      _initCardCamera(cameraController.description);
    }
  }

  // ----------------------------------------------------------
  // Controllers lifecycle
  // ----------------------------------------------------------

  Future<void> _initControllers() async {
    if (_mode == ScanMode.qr) {
      _initQrController();
    } else if (_mode == ScanMode.card) {
      final cameras = await availableCameras();
      if (cameras.isNotEmpty) {
        await _initCardCamera(cameras.first);
      }
    }
  }

  void _disposeControllers() {
    _qrController?.dispose();
    _qrController = null;
    _cardCameraController?.dispose();
    _cardCameraController = null;
    _isCardCameraInitialized = false;
  }

  Future<void> _initQrController() async {
    _qrController?.dispose();
    _qrController = MobileScannerController(
      detectionSpeed: DetectionSpeed.normal,
      facing: CameraFacing.back,
      torchEnabled: _flashOn,
    );
    if (mounted) setState(() {});
  }

  Future<void> _initCardCamera(CameraDescription cameraDescription) async {
    await _cardCameraController?.dispose();
    _cardCameraController = CameraController(
      cameraDescription,
      ResolutionPreset.high,
      enableAudio: false,
    );

    try {
      await _cardCameraController!.initialize();
      if (mounted) {
        setState(() {
          _isCardCameraInitialized = true;
        });
      }
    } catch (e) {
      debugPrint('Camera init error: $e');
    }
  }

  // ----------------------------------------------------------
  // Flash toggle
  // ----------------------------------------------------------

  void _toggleFlash() {
    setState(() => _flashOn = !_flashOn);
    if (_mode == ScanMode.qr) {
      _qrController?.toggleTorch();
    } else if (_mode == ScanMode.card) {
      _cardCameraController?.setFlashMode(
        _flashOn ? FlashMode.torch : FlashMode.off,
      );
    }
  }

  // ----------------------------------------------------------
  // Mode Switch
  // ----------------------------------------------------------

  void _switchMode(ScanMode newMode) {
    if (_mode == newMode) return;
    setState(() {
      _mode = newMode;
      _disposeControllers();
    });
    _initControllers();
  }

  // ----------------------------------------------------------
  // Capture actions
  // ----------------------------------------------------------

  Future<void> _onCapture() async {
    if (_isCapturing) return;

    if (_mode == ScanMode.card) {
      await _captureAndProcessCard();
    } else if (_mode == ScanMode.qr) {
      // In QR mode, detection is usually automatic, but we can trigger it or show options
      // Actually, if we want a button for OCR in card mode, it's handled here.
    }
  }

  Future<void> _captureAndProcessCard() async {
    if (_cardCameraController == null || !_isCardCameraInitialized) return;

    setState(() => _isCapturing = true);

    try {
      // 1. Capture the photo
      final XFile photo = await _cardCameraController!.takePicture();

      if (!mounted) return;

      // 2. Show loading dialog
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => const Center(
          child: CircularProgressIndicator(color: AppColors.accent),
        ),
      );

      // 3. Process with OCR
      final rawText = await ocr_service.recognizeTextFromFile(photo.path);

      if (mounted) Navigator.pop(context); // Close loading indicator

      Map<String, String> ocrData = {};
      if (rawText.isNotEmpty) {
        ocrData = OcrParser.parse(rawText);
        ocrData['photoPath'] = photo.path;
        if (mounted) _showStaticDetectionToast(context, ref);
      }

      if (mounted) {
        context.push('/review', extra: ocrData);
      }
    } catch (e) {
      debugPrint('Capture error: $e');
      if (mounted) {
        // Try to close dialog if it was open
        try {
          Navigator.pop(context);
        } catch (_) {}
      }
    } finally {
      if (mounted) setState(() => _isCapturing = false);
    }
  }

  void _onQrDetect(BarcodeCapture capture) {
    if (_mode != ScanMode.qr || _isCapturing) return;
    final barcodes = capture.barcodes;
    if (barcodes.isEmpty) return;

    setState(() => _isCapturing = true);
    _showStaticDetectionToast(context, ref);

    final raw = barcodes.first.rawValue ?? '';
    final ocrData = raw.isNotEmpty ? OcrParser.parse(raw) : <String, String>{};

    Future.delayed(const Duration(milliseconds: 500), () {
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
          // Background Camera / UI
          if (_mode == ScanMode.qr && _qrController != null)
            MobileScanner(
              controller: _qrController!,
              onDetect: _onQrDetect,
            )
          else if (_mode == ScanMode.card && _isCardCameraInitialized)
            Center(
              child: CameraPreview(_cardCameraController!),
            )
          else if (_mode == ScanMode.nfc)
            Container(color: Colors.black)
          else
            const Center(child: CircularProgressIndicator(color: AppColors.accent)),

          // Top bar
          _buildTopBar(context, l10n),

          // Viewport + scan line
          Center(child: _buildViewport()),

          // Mode Selector
          Positioned(
            bottom: 160 + bottomInset,
            left: 0,
            right: 0,
            child: _buildModeSelector(l10n),
          ),

          // Hint text
          Positioned(
            bottom: 240 + bottomInset,
            left: 0,
            right: 0,
            child: Text(
              _mode == ScanMode.card ? l10n.scanHint : 'Aligner le QR Code',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w500,
                color: AppColors.white.withOpacity(0.7),
              ),
            ),
          ),

          // Capture button (Only for Card mode)
          if (_mode == ScanMode.card)
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

  Widget _buildModeSelector(AppL10n l10n) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        _ModeButton(
          label: l10n.scanCard,
          isSelected: _mode == ScanMode.card,
          onTap: () => _switchMode(ScanMode.card),
        ),
        const SizedBox(width: 24),
        _ModeButton(
          label: 'QR Code',
          isSelected: _mode == ScanMode.qr,
          onTap: () => _switchMode(ScanMode.qr),
        ),
      ],
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
            _mode == ScanMode.card ? l10n.scanTitle : 'Scanner QR',
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
      bracket(top: 0, left: 0, right: -1, bottom: -1, flipH: false, flipV: false),
      bracket(top: 0, left: -1, right: 0, bottom: -1, flipH: true, flipV: false),
      bracket(top: -1, left: 0, right: -1, bottom: 0, flipH: false, flipV: true),
      bracket(top: -1, left: -1, right: 0, bottom: 0, flipH: true, flipV: true),
    ];
  }

  // ----------------------------------------------------------
  // Capture button
  // ----------------------------------------------------------

  Widget _buildCaptureButton() {
    return GestureDetector(
      onTap: _onCapture,
      child: Container(
        width: 76,
        height: 76,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(color: AppColors.white, width: 4),
        ),
        padding: const EdgeInsets.all(4),
        child: Container(
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: _isCapturing ? AppColors.white.withOpacity(0.5) : AppColors.accent,
            gradient: _isCapturing ? null : AppColors.accentGradient,
          ),
          child: _isCapturing
              ? const Center(child: SizedBox(width: 24, height: 24, child: CircularProgressIndicator(color: AppColors.white, strokeWidth: 2)))
              : null,
        ),
      ),
    );
  }
}

class _ModeButton extends StatelessWidget {
  final String label;
  final bool isSelected;
  final VoidCallback onTap;

  const _ModeButton({
    required this.label,
    required this.isSelected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Column(
        children: [
          Text(
            label.toUpperCase(),
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: isSelected ? AppColors.accent : AppColors.white.withOpacity(0.5),
              letterSpacing: 1,
            ),
          ),
          const SizedBox(height: 4),
          if (isSelected)
            Container(
              width: 4,
              height: 4,
              decoration: const BoxDecoration(
                color: AppColors.accent,
                shape: BoxShape.circle,
              ),
            ),
        ],
      ),
    );
  }
}

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
                  context.push('/scan'); // Card mode is default
                },
              ),
              const SizedBox(height: 8),
              _BottomSheetOption(
                icon: Icons.qr_code_scanner_rounded,
                title: l10n.scanQR,
                enabled: !(isFreePlan && !isInActiveOrg),
                onTap: (isFreePlan && !isInActiveOrg)
                    ? () {
                        Navigator.pop(modalContext);
                        context.push('/subscription-plan');
                      }
                    : () {
                        Navigator.pop(modalContext);
                        // Navigate with a flag if we want QR mode directly
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

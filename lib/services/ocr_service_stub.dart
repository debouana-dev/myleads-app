/// Stub for web — OCR is not available in browser.
///
/// Mirrors the [OcrResult] type from ocr_service_mobile.dart so that the
/// conditional-import alias `as ocr_service` exposes consistent members on
/// every platform (each platform compiles only one of the two files).
class OcrResult {
  final String rawText;
  final double mlKitConfidence;
  final List<String> rawBlocks;

  const OcrResult({
    required this.rawText,
    required this.mlKitConfidence,
    required this.rawBlocks,
  });

  static const empty =
      OcrResult(rawText: '', mlKitConfidence: 0.0, rawBlocks: []);
}

Future<OcrResult> recognizeTextFromFile(String filePath) async =>
    OcrResult.empty;

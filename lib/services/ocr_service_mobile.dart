import 'dart:io';

import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';

/// Result from the ML Kit OCR pass.
///
/// [mlKitConfidence] is a character-count-weighted average of per-element
/// confidence scores (0.0–1.0). Returns 0.5 when the on-device model does
/// not emit per-element scores (common on Android).
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

/// Extracts text from a photo using Google ML Kit (Latin script).
///
/// Handles English, French, and other western European languages including
/// accented characters (é, è, ê, ç, à, ô, û, î, ï…).
Future<OcrResult> recognizeTextFromFile(String filePath) async {
  final inputImage = InputImage.fromFile(File(filePath));
  final recognizer = TextRecognizer(script: TextRecognitionScript.latin);
  try {
    final result = await recognizer.processImage(inputImage);

    double weightedSum = 0.0;
    double totalWeight = 0.0;

    for (final block in result.blocks) {
      for (final line in block.lines) {
        for (final element in line.elements) {
          // element.confidence is null on Android with the on-device model
          final confidence = element.confidence ?? 0.5;
          final weight = element.text.length.toDouble();
          weightedSum += confidence * weight;
          totalWeight += weight;
        }
      }
    }

    final mlConfidence =
        totalWeight > 0 ? (weightedSum / totalWeight) : 0.0;

    return OcrResult(
      rawText: result.text,
      mlKitConfidence: mlConfidence,
      rawBlocks: result.blocks.map((b) => b.text).toList(),
    );
  } finally {
    await recognizer.close();
  }
}

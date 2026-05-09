// ignore_for_file: constant_identifier_names

/// Application configuration with obfuscated credentials.
///
/// SMTP credentials are stored as XOR-obfuscated integer arrays.
/// The key cycles over each byte, so the plaintext never appears in the
/// compiled binary as a contiguous string literal.
///
/// Obfuscation method: XOR with a cycling key, so credentials never
/// appear as plaintext string literals in the compiled binary.
class AppConfig {
  AppConfig._();

  // ── SMTP ────────────────────────────────────────────────────────────────

  static String get smtpHost => _deobfuscate(const [
        62, 10, 32, 85, 79, 11, 5, 90, 30, 92, 83, 39,
      ]);

  static int get smtpPort => 465;

  static String get smtpUsername => _deobfuscate(const [
        46, 22, 33, 8, 20, 10, 26, 81, 81, 70, 95, 60, 11, 35, 22, 0,
        22, 36, 16, 24, 35, 24, 98, 6, 14, 9,
      ]);

  static String get smtpPassword => _deobfuscate(const [
        3, 57, 116, 80, 81, 81, 71, 0, 9, 7, 0, 107, 86, 87, 7, 31,
      ]);

  static bool get smtpSsl => true;

  // ── PostgreSQL remote sync ──────────────────────────────────────────────────

  static String get pgHost => _deobfuscate(const [
        122, 64, 98, 84, 82, 83, 93, 1, 4, 28, 7, 101, 80,
      ]);

  static int get pgPort => 5432;

  static String get pgUsername => _deobfuscate(const [
        32, 28, 126, 9, 4, 5, 23, 65,
      ]);

  static String get pgPassword => _deobfuscate(const [
        20, 90, 34, 41, 4, 5, 23, 11, 5, 103, 121, 119,
      ]);

  static String get pgDatabase => _deobfuscate(const [
        32, 28, 126, 9, 4, 5, 23, 65,
      ]);

  // ── FTP photo storage ───────────────────────────────────────────────────

  static String get ftpHost => _deobfuscate(const [
        43, 13, 44, 91, 2, 8, 6, 81, 68, 87, 84, 98, 85, 83, 92, 13,
        27, 56, 17, 16, 35, 30, 98, 10, 23, 12, 93, 92, 85, 70,
      ]);

  static int get ftpPort => 21;

  static String get ftpUsername => _deobfuscate(const [
        39, 26, 39, 4, 15, 28, 0, 31, 93, 87, 4, 63, 0, 2, 22, 22,
      ]);

  static String get ftpPassword => _deobfuscate(const [
        41, 77, 53, 4, 35, 51, 57, 2, 17, 94, 98, 17,
      ]);

  // ── Internal ────────────────────────────────────────────────────────────

  /// XOR deobfuscation. Key cycles over [data] by index modulo key length.
  static String _deobfuscate(List<int> data) {
    const key = 'MyLeads2026SecretKey';
    final result = StringBuffer();
    for (var i = 0; i < data.length; i++) {
      result.writeCharCode(data[i] ^ key.codeUnitAt(i % key.length));
    }
    return result.toString();
  }
}

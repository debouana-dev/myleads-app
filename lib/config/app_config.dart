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
        62,
        10,
        32,
        85,
        79,
        11,
        5,
        90,
        30,
        92,
        83,
        39,
      ]);

  static int get smtpPort => 465;

  static String get smtpUsername => _deobfuscate(const [
        46,
        22,
        33,
        8,
        20,
        10,
        26,
        81,
        81,
        70,
        95,
        60,
        11,
        35,
        22,
        0,
        22,
        36,
        16,
        24,
        35,
        24,
        98,
        6,
        14,
        9,
      ]);

  static String get smtpPassword => _deobfuscate(const [
        3,
        57,
        116,
        80,
        81,
        81,
        71,
        0,
        9,
        7,
        0,
        107,
        86,
        87,
        7,
        31,
      ]);

  static bool get smtpSsl => true;

  // ── PostgreSQL remote sync ──────────────────────────────────────────────────

  static String get pgHost => _deobfuscate(const [
        122,
        64,
        98,
        84,
        82,
        83,
        93,
        1,
        4,
        28,
        7,
        101,
        80,
      ]);

  static int get pgPort => 5432;

  static String get pgUsername => _deobfuscate(const [
        32,
        28,
        126,
        9,
        4,
        5,
        23,
        65,
      ]);

  static String get pgPassword => _deobfuscate(const [
        20,
        90,
        34,
        41,
        4,
        5,
        23,
        11,
        5,
        103,
        121,
        119,
      ]);

  static String get pgDatabase => _deobfuscate(const [
        32,
        28,
        126,
        9,
        4,
        5,
        23,
        65,
      ]);

  // ── SFTP photo storage ──────────────────────────────────────────────────

  static String get ftpHost => _deobfuscate(const [
        122,
        64,
        98,
        84,
        82,
        83,
        93,
        1,
        4,
        28,
        7,
        101,
        80,
      ]);

  static int get ftpPort => 22;

  static String get ftpUsername => _deobfuscate(const [
        32,
        28,
        126,
        9,
        4,
        5,
        23,
        65,
      ]);

  static String get ftpPassword => _deobfuscate(const [
        41,
        77,
        53,
        4,
        35,
        51,
        57,
        2,
        113,
        126,
        98,
        17,
      ]);

  // ── Stripe payment processing ────────────────────────────────────────────────
  // Replace the empty string with XOR-obfuscated bytes of your publishable key.
  // Obfuscate: python3 -c "k='MyLeads2026SecretKey';d='pk_live_...';print([ord(c)^ord(k[i%len(k)]) for i,c in enumerate(d)])"
  static String get stripePublishableKey => _deobfuscate(const [
        61,
        18,
        19,
        17,
        4,
        23,
        7,
        109,
        5,
        3,
        98,
        6,
        82,
        81,
        48,
        44,
        46,
        121,
        50,
        15,
        127,
        61,
        15,
        83,
        13,
        52,
        48,
        90,
        64,
        68,
        113,
        97,
        42,
        42,
        66,
        49,
        19,
        14,
        53,
        49,
        57,
        62,
        11,
        8,
        27,
        42,
        49,
        86,
        84,
        99,
        95,
        57,
        19,
        36,
        31,
        28,
        39,
        44,
        28,
        10,
        121,
        62,
        63,
        93,
        43,
        15,
        25,
        72,
        71,
        106,
        0,
        99,
        21,
        53,
        24,
        15,
        17,
        44,
        20,
        8,
        24,
        19,
        122,
        8,
        54,
        86,
        39,
        64,
        103,
        100,
        84,
        53,
        80,
        15,
        21,
        15,
        33,
        123,
        85,
        41,
        2,
        24,
        46,
        6,
        18,
        3,
        11
      ]);

  // ── RevenueCat payment processing (iOS) ──────────────────────────────────────
  // Replace the empty list with XOR-obfuscated bytes of your Apple API Key.
  static String get revenueCatApiKey => _deobfuscate(const [
        44,
        9,
        60,
        9,
        62,
        55,
        37,
        70,
        116,
        71,
        93,
        5,
        12,
        9,
        21,
        12,
        21,
        26,
        0,
        58,
        61,
        48,
        42,
        51,
        14,
        41,
        56,
        95,
        116,
        126,
        112,
        9
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

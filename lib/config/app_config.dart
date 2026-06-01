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
        20,
        56,
        21,
        79,
        3,
        30,
        83,
        89,
        94,
        24,
        48,
        10,
        14,
      ]);

  static int get smtpPort => 587;

  static String get smtpUsername => _deobfuscate(const [
        46,
        22,
        34,
        17,
        0,
        7,
        7,
        114,
        93,
        87,
        4,
        63,
        0,
        2,
        22,
        22,
        90,
        40,
        10,
        20,
      ]);

  static String get smtpPassword => _deobfuscate(const [
        61,
        17,
        57,
        4,
        65,
        8,
        17,
        69,
        82,
        18,
        85,
        34,
        13,
        23,
        82,
        15,
        22,
        37,
        7,
      ]);

  static bool get smtpSsl => false;

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
        9,
        8,
        18,
        22,
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
        18,
        25,
        80,
        84,
        10,
        100,
        31,
        0,
        20,
        11,
        13,
        53,
        8,
        4,
        55,
        0,
        24,
        125,
        85,
        11,
        42,
        43,
        92,
        64,
        87,
        2,
        1,
        18,
        45,
        75,
        4,
        34,
        59,
        41,
        50,
        53,
        65,
        56,
        82,
        84,
        7,
        20,
        117,
        124,
        94,
        114,
        30,
        23,
        47,
        65,
        6,
        35,
        115,
        83,
        75,
        125,
        20,
        63,
        14,
        51,
        52,
        54,
        101,
        64,
        96,
        2,
        9,
        93,
        4,
        55,
        51,
        14,
        123,
        85,
        35,
        11,
        74,
        2,
        9,
        3,
        39,
        42
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

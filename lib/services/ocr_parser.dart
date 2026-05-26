/// Confidence level for a parsed contact field.
///
/// Indicates how the field was extracted:
/// - [high]: structured source (regex match, vCard property, keyword-prefixed line)
/// - [fair]: heuristic keyword match (job title keyword, company suffix)
/// - [low]: fallback guess (leftover-line heuristic or failed post-parse validation)
enum FieldConfidence { high, fair, low }

/// Structured result from [OcrParser.parse].
class ParseResult {
  final Map<String, String> fields;
  final Map<String, FieldConfidence> fieldConfidences;

  const ParseResult({
    required this.fields,
    required this.fieldConfidences,
  });
}

/// Extracts contact fields from raw OCR text or QR code content.
///
/// Handles both business cards (name, email, phone, job title, company)
/// and handwritten / typed notes that carry extra project context
/// (source, project/budget pairs, tags, free-form notes).
///
/// Extraction strategy:
///   0. vCard / URL / mailto fast-path (structured QR codes).
///   1. Regex sweep for email, phone, website.
///   2. Keyword-prefixed lines ("Projet:", "Budget:", "Source:", "Tags:",
///      "Notes:"…) pull out business context. French + English keywords
///      are supported.
///   3. Remaining lines are classified as name / title / company using
///      job-title keyword heuristics.
///   4. Post-parse validation moves malformed fields to notes.
class OcrParser {
  OcrParser._();

  static ParseResult parse(String rawText) {
    final trimmed = rawText.trim();

    // ── 0. Structured QR fast-paths ────────────────────────────────────────
    if (trimmed.toUpperCase().startsWith('BEGIN:VCARD')) {
      return _parseVCard(trimmed);
    }
    if (trimmed.startsWith('mailto:')) {
      final email = trimmed.substring('mailto:'.length).split('?').first.trim();
      return ParseResult(
        fields: {'email': email},
        fieldConfidences: {'email': FieldConfidence.high},
      );
    }
    if (trimmed.startsWith('http://') || trimmed.startsWith('https://')) {
      return ParseResult(
        fields: {'notes': 'Web: $trimmed'},
        fieldConfidences: {'notes': FieldConfidence.high},
      );
    }

    // ── Heuristic pipeline ──────────────────────────────────────────────────
    final lines = trimmed
        .split('\n')
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .toList();
    final result = <String, String>{};
    final confidences = <String, FieldConfidence>{};

    String? email;
    String? phone;
    String? website;
    final leftover = <String>[];
    final tags = <String>[];
    final notes = <String>[];
    int projectIdx = 1;

    for (final line in lines) {
      // ── 1. Regex extractors ───────────────────────────────────────────────
      // Email
      final emailMatch =
          RegExp(r'[a-zA-Z0-9._%+\-]+@[a-zA-Z0-9.\-]+\.[a-zA-Z]{2,}')
              .firstMatch(line);
      if (emailMatch != null) {
        email ??= emailMatch.group(0);
        continue;
      }

      // Phone — anchored pattern prevents matching digit runs in street addresses
      final phoneMatch = RegExp(
        r'(?<!\d)(\+?[\d\s\-.\(\)]{6,20})(?!\d)',
      ).firstMatch(line);
      if (phoneMatch != null) {
        final digits = phoneMatch.group(0)!.replaceAll(RegExp(r'[^\d+]'), '');
        if (digits.length >= 6) {
          phone ??= phoneMatch.group(0)!.trim();
          if (line.replaceAll(phoneMatch.group(0)!, '').trim().length < 3) {
            continue;
          }
        }
      }

      // Website
      if (RegExp(r'(www\.|https?://|[a-z0-9]+\.[a-z]{2,}/)',
                  caseSensitive: false)
              .hasMatch(line) &&
          !line.contains('@')) {
        website ??= line;
        continue;
      }

      // ── 2. Keyword-prefixed fields ────────────────────────────────────────
      final kv = _matchKeyValue(line);
      if (kv != null) {
        final key = kv.$1;
        final value = kv.$2;

        if (RegExp(
                r'^(source|origine|via|referred by|referral|refere|referre)$',
                caseSensitive: false)
            .hasMatch(key)) {
          result['source'] = value;
          confidences['source'] = FieldConfidence.high;
          continue;
        }

        if (RegExp(r'^(projet|project)\s*(\d+)?$', caseSensitive: false)
            .hasMatch(key)) {
          final m = RegExp(r'(\d+)').firstMatch(key);
          final idx = m != null ? int.parse(m.group(0)!) : projectIdx++;
          if (idx == 1 || idx == 2) {
            result['project$idx'] = value;
            confidences['project$idx'] = FieldConfidence.high;
          }
          continue;
        }

        if (RegExp(r'^(budget|cout|coût|montant|price|prix)\s*(\d+)?$',
                caseSensitive: false)
            .hasMatch(key)) {
          final m = RegExp(r'(\d+)').firstMatch(key);
          final idx = m != null ? int.parse(m.group(0)!) : 1;
          if (idx == 1 || idx == 2) {
            result['project${idx}Budget'] = value;
            confidences['project${idx}Budget'] = FieldConfidence.high;
          }
          continue;
        }

        if (RegExp(r'^(tags?|etiquettes?|labels?)$', caseSensitive: false)
            .hasMatch(key)) {
          tags.addAll(value
              .split(RegExp(r'[,;]'))
              .map((t) => t.trim())
              .where((t) => t.isNotEmpty));
          continue;
        }

        if (RegExp(r'^(notes?|remarques?|commentaires?|comments?)$',
                caseSensitive: false)
            .hasMatch(key)) {
          notes.add(value);
          continue;
        }

        if (RegExp(r'^(poste|fonction|title|role|titre)$', caseSensitive: false)
            .hasMatch(key)) {
          result.putIfAbsent('jobTitle', () => value);
          confidences.putIfAbsent('jobTitle', () => FieldConfidence.high);
          continue;
        }

        if (RegExp(r'^(entreprise|societe|société|company|organisation|org)$',
                caseSensitive: false)
            .hasMatch(key)) {
          result.putIfAbsent('company', () => value);
          confidences.putIfAbsent('company', () => FieldConfidence.high);
          continue;
        }

        // First name (explicit label)
        if (RegExp(r'^(prénom|prenom|first\.?name|firstname|given\.?name)$',
                caseSensitive: false)
            .hasMatch(key)) {
          result.putIfAbsent('firstName', () => value);
          confidences.putIfAbsent('firstName', () => FieldConfidence.high);
          continue;
        }

        // Last name (explicit label)
        if (RegExp(
                r'^(nom de famille|surname|last\.?name|lastname|family\.?name)$',
                caseSensitive: false)
            .hasMatch(key)) {
          result.putIfAbsent('lastName', () => value);
          confidences.putIfAbsent('lastName', () => FieldConfidence.high);
          continue;
        }

        // Full name (explicit label)
        if (RegExp(r'^(nom|name|fn)$', caseSensitive: false).hasMatch(key)) {
          final parts = value.split(RegExp(r'\s+'));
          if (parts.length >= 2) {
            result['firstName'] = parts.first;
            result['lastName'] = parts.sublist(1).join(' ');
          } else {
            result['lastName'] = value;
          }
          confidences['firstName'] = FieldConfidence.high;
          confidences['lastName'] = FieldConfidence.high;
          continue;
        }

        // Nickname / alias → firstName if not already set
        if (RegExp(r'^(surnom|nickname|pseudo|alias)$', caseSensitive: false)
            .hasMatch(key)) {
          result.putIfAbsent('firstName', () => value);
          confidences.putIfAbsent('firstName', () => FieldConfidence.fair);
          continue;
        }

        // Phone (labeled — value goes through digit count validation)
        if (RegExp(
                r'^(téléphone|telephone|tél|tel|portable|mobile|gsm|cell|cellulaire|phone|cell\.?phone)$',
                caseSensitive: false)
            .hasMatch(key)) {
          if (phone == null) {
            final digits = value.replaceAll(RegExp(r'[^\d]'), '');
            if (digits.length >= 6) phone = value.trim();
          }
          continue;
        }

        // Website (labeled)
        if (RegExp(
                r'^(site\.?web|site\.?internet|website|webpage|web|url|lien)$',
                caseSensitive: false)
            .hasMatch(key)) {
          website ??= value;
          continue;
        }

        // Social networks / professional profiles → notes
        if (RegExp(
                r'^(linkedin|twitter|facebook|instagram|réseau|reseau|social|profil)$',
                caseSensitive: false)
            .hasMatch(key)) {
          notes.add('$key: $value');
          continue;
        }

        // Industry / sector → notes
        if (RegExp(
                r'^(secteur|industrie|domaine|domain|activité|activite|industry|sector)$',
                caseSensitive: false)
            .hasMatch(key)) {
          notes.add(value);
          continue;
        }

        // Address / location → discard (no Contact field for this data)
        if (RegExp(
                r'^(adresse|address|ville|city|pays|country|région|region|code\.?postal|cp|zip|localité|localite)$',
                caseSensitive: false)
            .hasMatch(key)) {
          continue;
        }

        // Unknown label: send only the value to the heuristic, not "label: value"
        leftover.add(kv.$2);
        continue;
      }

      // Hashtag-style tags
      final hashtagMatches =
          RegExp(r'#([\p{L}\p{N}_\-]+)', unicode: true).allMatches(line);
      if (hashtagMatches.isNotEmpty) {
        for (final m in hashtagMatches) {
          tags.add(m.group(1)!);
        }
        final stripped = line
            .replaceAll(RegExp(r'#([\p{L}\p{N}_\-]+)', unicode: true), '')
            .trim();
        if (stripped.isEmpty) continue;
      }

      // Skip obvious address lines
      if (RegExp(
              r'\b(rue|avenue|boulevard|bp|boîte|cedex|street|road|box|chemin|route|allée|impasse|place|square|parc|quartier|ville|pays|city|country|state|zip|postal|cedex)\b',
              caseSensitive: false)
          .hasMatch(line)) {
        continue;
      }
      if (RegExp(r'\b\d{4,6}\b').hasMatch(line) && line.length > 15) {
        continue;
      }

      leftover.add(line);
    }

    if (email != null) {
      result['email'] = email;
      confidences['email'] = FieldConfidence.high;
    }
    if (phone != null) {
      result['phone'] = phone;
      confidences['phone'] = FieldConfidence.high;
    }

    // ── 3. Name / title / company from leftover lines ─────────────────────
    final titleKeywords = RegExp(
      r'\b(ceo|cto|cfo|coo|cmo|directeur|directrice|manager|head|chef|responsable|ingenieur|ingénieur|engineer|consultant|partner|founder|president|président|associate|analyst|developer|designer|vp|vice|commercial|sales|marketing|account|expert|specialist|spécialiste|architecte|architect|fondateur|co-fondateur|fondatrice|co-fondatrice|gérant|gérante|directeur général|dg|pdg)\b',
      caseSensitive: false,
    );

    final companySuffixes = RegExp(
      r'\b(sarl|sas|sas u|eurl|sa|inc|ltd|co|gmbh|llc|corp|corporation|group|groupe|solutions|technologies|services|associés|associés|university|université|école|institute|association|ngo|ong)\b',
      caseSensitive: false,
    );

    String? detectedName;
    String? detectedTitle;
    String? detectedCompany;

    final remaining = <String>[];

    for (final line in leftover) {
      if (titleKeywords.hasMatch(line)) {
        detectedTitle ??= line;
      } else if (companySuffixes.hasMatch(line)) {
        detectedCompany ??= line;
      } else {
        remaining.add(line);
      }
    }

    // Heuristic: 2–4 words, no digits → likely a name
    for (var i = 0; i < remaining.length; i++) {
      final line = remaining[i];
      final words = line.split(RegExp(r'\s+'));
      final hasDigits = line.contains(RegExp(r'\d'));
      if (words.length >= 2 &&
          words.length <= 4 &&
          !hasDigits &&
          detectedName == null) {
        detectedName = line;
        remaining.removeAt(i);
        break;
      }
    }

    // Fallback: first remaining line
    FieldConfidence nameConfidence = FieldConfidence.fair;
    if (detectedName == null && remaining.isNotEmpty) {
      detectedName = remaining.removeAt(0);
      nameConfidence = FieldConfidence.low;
    }

    // Fallback: next remaining line for company
    FieldConfidence companyConfidence = FieldConfidence.fair;
    if (detectedCompany == null && remaining.isNotEmpty) {
      detectedCompany = remaining.removeAt(0);
      companyConfidence = FieldConfidence.low;
    }

    if (detectedName != null) {
      final parts = detectedName.split(RegExp(r'\s+'));
      if (parts.length >= 2) {
        result['firstName'] = parts.first;
        result['lastName'] = parts.sublist(1).join(' ');
      } else {
        result['lastName'] = detectedName;
      }
      confidences.putIfAbsent('firstName', () => nameConfidence);
      confidences.putIfAbsent('lastName', () => nameConfidence);
    }

    if (detectedTitle != null) {
      result['jobTitle'] = detectedTitle;
      confidences.putIfAbsent('jobTitle', () => FieldConfidence.fair);
    }
    if (detectedCompany != null) {
      result['company'] = detectedCompany;
      confidences.putIfAbsent('company', () => companyConfidence);
    }

    if (remaining.isNotEmpty) notes.insert(0, remaining.join('\n'));
    if (website != null) notes.add('Web: $website');

    if (tags.isNotEmpty) {
      final seen = <String>{};
      final uniq = tags.where((t) => seen.add(t.toLowerCase())).toList();
      result['tags'] = uniq.join(',');
    }
    if (notes.isNotEmpty) result['notes'] = notes.join('\n');

    // ── 4. Post-parse validation ──────────────────────────────────────────
    _validate(result, confidences, notes);

    return ParseResult(fields: result, fieldConfidences: confidences);
  }

  // ── vCard parser ──────────────────────────────────────────────────────────

  static ParseResult _parseVCard(String content) {
    final fields = <String, String>{};
    final confidences = <String, FieldConfidence>{};
    final extraNotes = <String>[];

    for (final raw in content.split('\n')) {
      final line = raw.trim();
      if (line.isEmpty ||
          line.toUpperCase() == 'BEGIN:VCARD' ||
          line.toUpperCase() == 'END:VCARD' ||
          line.toUpperCase().startsWith('VERSION:')) {
        continue;
      }

      // Property name may include TYPE params: TEL;TYPE=CELL:+1234
      final colonIdx = line.indexOf(':');
      if (colonIdx < 0) continue;
      final prop = line.substring(0, colonIdx).split(';').first.toUpperCase();
      final value = line.substring(colonIdx + 1).trim();
      if (value.isEmpty) continue;

      switch (prop) {
        case 'FN':
          // Full name — split on first space
          final parts = value.split(RegExp(r'\s+'));
          if (parts.length >= 2) {
            fields['firstName'] = parts.first;
            fields['lastName'] = parts.sublist(1).join(' ');
          } else {
            fields['lastName'] = value;
          }
          confidences['firstName'] = FieldConfidence.high;
          confidences['lastName'] = FieldConfidence.high;
        case 'N':
          // Structured name: LastName;FirstName;Additional;Prefix;Suffix
          if (!fields.containsKey('lastName')) {
            final parts = value.split(';');
            if (parts.isNotEmpty && parts[0].trim().isNotEmpty) {
              fields['lastName'] = parts[0].trim();
              confidences['lastName'] = FieldConfidence.high;
            }
            if (parts.length > 1 && parts[1].trim().isNotEmpty) {
              fields['firstName'] = parts[1].trim();
              confidences['firstName'] = FieldConfidence.high;
            }
          }
        case 'ORG':
          fields.putIfAbsent('company', () => value);
          confidences.putIfAbsent('company', () => FieldConfidence.high);
        case 'TITLE':
          fields.putIfAbsent('jobTitle', () => value);
          confidences.putIfAbsent('jobTitle', () => FieldConfidence.high);
        case 'TEL':
          fields.putIfAbsent('phone', () => value);
          confidences.putIfAbsent('phone', () => FieldConfidence.high);
        case 'EMAIL':
          fields.putIfAbsent('email', () => value);
          confidences.putIfAbsent('email', () => FieldConfidence.high);
        case 'URL':
          extraNotes.add('Web: $value');
        case 'NOTE':
          extraNotes.add(value);
        default:
          break;
      }
    }

    if (extraNotes.isNotEmpty) fields['notes'] = extraNotes.join('\n');

    // vCard content is structured — fall back to heuristic parser only if no
    // name was found (e.g. malformed vCard with only TITLE/ORG/TEL).
    if (!fields.containsKey('lastName') && !fields.containsKey('firstName')) {
      final fallback = parse(fields.values.join('\n'));
      for (final e in fallback.fields.entries) {
        fields.putIfAbsent(e.key, () => e.value);
      }
      for (final e in fallback.fieldConfidences.entries) {
        confidences.putIfAbsent(e.key, () => e.value);
      }
    }

    return ParseResult(fields: fields, fieldConfidences: confidences);
  }

  // ── Post-parse validation ─────────────────────────────────────────────────

  static final _emailRegex =
      RegExp(r'^[a-zA-Z0-9._%+\-]+@[a-zA-Z0-9.\-]+\.[a-zA-Z]{2,}$');
  static final _urlFragmentRegex = RegExp(r'https?://|www\.');
  static final _allDigitsRegex = RegExp(r'^\d+$');

  static void _validate(
    Map<String, String> result,
    Map<String, FieldConfidence> confidences,
    List<String> notes,
  ) {
    // Email: must match regex
    final email = result['email'];
    if (email != null && !_emailRegex.hasMatch(email)) {
      notes.add(email);
      result.remove('email');
      confidences.remove('email');
      if (notes.isNotEmpty) result['notes'] = notes.join('\n');
    }

    // Phone: stripped digits must be at least 6
    final phone = result['phone'];
    if (phone != null) {
      final digits = phone.replaceAll(RegExp(r'[^\d]'), '');
      if (digits.length < 6) {
        notes.add(phone);
        result.remove('phone');
        confidences.remove('phone');
        if (notes.isNotEmpty) result['notes'] = notes.join('\n');
      }
    }

    // Name: downgrade confidence if value looks like digits or a URL fragment
    for (final key in ['firstName', 'lastName']) {
      final val = result[key];
      if (val == null) continue;
      if (_allDigitsRegex.hasMatch(val) || _urlFragmentRegex.hasMatch(val)) {
        confidences[key] = FieldConfidence.low;
      }
    }
  }

  // ── Helpers ───────────────────────────────────────────────────────────────

  static (String, String)? _matchKeyValue(String line) {
    final m = RegExp(r'^([\p{L}][\p{L}\p{N}\s\-]{0,30}?)\s*[:\-]\s*(.+)$',
            unicode: true)
        .firstMatch(line);
    if (m == null) return null;
    final key = m.group(1)!.trim();
    final value = m.group(2)!.trim();
    if (value.isEmpty) return null;
    return (key, value);
  }
}

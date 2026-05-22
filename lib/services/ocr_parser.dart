/// Extracts contact fields from raw OCR text.
///
/// Handles both business cards (name, email, phone, job title, company)
/// and handwritten / typed notes that carry extra project context
/// (source, project/budget pairs, tags, free-form notes).
///
/// Extraction strategy:
///   1. Regex sweep for email, phone, website.
///   2. Keyword-prefixed lines ("Projet:", "Budget:", "Source:", "Tags:",
///      "Notes:"…) pull out business context. French + English keywords
///      are supported.
///   3. Remaining lines are classified as name / title / company using
///      job-title keyword heuristics.
class OcrParser {
  OcrParser._();

  static Map<String, String> parse(String rawText) {
    final lines = rawText
        .split('\n')
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .toList();
    final result = <String, String>{};

    String? email;
    String? phone;
    String? website;
    final leftover = <String>[];
    final tags = <String>[];
    final notes = <String>[];
    int projectIdx = 1;

    for (final line in lines) {
      // ── 1. Regex extractors ─────────────────────────────────────────────
      // Email
      final emailMatch = RegExp(
              r'[a-zA-Z0-9._%+\-]+@[a-zA-Z0-9.\-]+\.[a-zA-Z]{2,}')
          .firstMatch(line);
      if (emailMatch != null) {
        email ??= emailMatch.group(0);
        continue;
      }

      // Phone
      final phoneMatch = RegExp(
        r'(?:\+?\d{1,3}[\s\-.]?)?\(?\d{2,4}\)?[\s\-.]?\d{2,4}[\s\-.]?\d{2,4}[\s\-.]?\d{0,4}',
      ).firstMatch(line);
      if (phoneMatch != null) {
        final digits =
            phoneMatch.group(0)!.replaceAll(RegExp(r'[^\d+]'), '');
        if (digits.length >= 8) {
          phone ??= phoneMatch.group(0)!.trim();
          // If the line contains more than just the phone, keep it for other checks
          if (line.replaceAll(phoneMatch.group(0)!, '').trim().length < 3) {
            continue;
          }
        }
      }

      // Website
      if (RegExp(r'(www\.|https?://|[a-z0-9]+\.[a-z]{2,}/)', caseSensitive: false).hasMatch(line) &&
          !line.contains('@')) {
        website ??= line;
        continue;
      }

      // ── 2. Keyword-prefixed fields ─────────────────────────────────────
      final kv = _matchKeyValue(line);
      if (kv != null) {
        final key = kv.$1;
        final value = kv.$2;

        // Source / lead origin
        if (RegExp(r'^(source|origine|via|referred by|referral|refere|referre)$',
                caseSensitive: false)
            .hasMatch(key)) {
          result['source'] = value;
          continue;
        }

        // Project (1..N)
        if (RegExp(r'^(projet|project)\s*(\d+)?$', caseSensitive: false)
            .hasMatch(key)) {
          final m = RegExp(r'(\d+)').firstMatch(key);
          final idx = m != null ? int.parse(m.group(0)!) : projectIdx++;
          if (idx == 1 || idx == 2) {
            result['project$idx'] = value;
          }
          continue;
        }

        // Budget (1..N)
        if (RegExp(r'^(budget|cout|coût|montant|price|prix)\s*(\d+)?$',
                caseSensitive: false)
            .hasMatch(key)) {
          final m = RegExp(r'(\d+)').firstMatch(key);
          final idx = m != null ? int.parse(m.group(0)!) : 1;
          if (idx == 1 || idx == 2) {
            result['project${idx}Budget'] = value;
          }
          continue;
        }

        // Tags (comma/semicolon separated)
        if (RegExp(r'^(tags?|etiquettes?|labels?)$', caseSensitive: false)
            .hasMatch(key)) {
          tags.addAll(value
              .split(RegExp(r'[,;]'))
              .map((t) => t.trim())
              .where((t) => t.isNotEmpty));
          continue;
        }

        // Notes
        if (RegExp(r'^(notes?|remarques?|commentaires?|comments?)$',
                caseSensitive: false)
            .hasMatch(key)) {
          notes.add(value);
          continue;
        }

        // Job title explicit
        if (RegExp(r'^(poste|fonction|title|role|titre)$', caseSensitive: false)
            .hasMatch(key)) {
          result.putIfAbsent('jobTitle', () => value);
          continue;
        }

        // Company explicit
        if (RegExp(r'^(entreprise|societe|société|company|organisation|org)$',
                caseSensitive: false)
            .hasMatch(key)) {
          result.putIfAbsent('company', () => value);
          continue;
        }

        // Name explicit (vCard or labeled)
        if (RegExp(r'^(nom|name|fn)$', caseSensitive: false).hasMatch(key)) {
          final parts = value.split(RegExp(r'\s+'));
          if (parts.length >= 2) {
            result['firstName'] = parts.first;
            result['lastName'] = parts.sublist(1).join(' ');
          } else {
            result['lastName'] = value;
          }
          continue;
        }
      }

      // Hashtag-style tags anywhere in the line
      final hashtagMatches =
          RegExp(r'#([\p{L}\p{N}_\-]+)', unicode: true).allMatches(line);
      if (hashtagMatches.isNotEmpty) {
        for (final m in hashtagMatches) {
          tags.add(m.group(1)!);
        }
        final stripped =
            line.replaceAll(RegExp(r'#([\p{L}\p{N}_\-]+)', unicode: true), '')
                .trim();
        if (stripped.isEmpty) continue;
      }

      // Skip obvious address lines
      if (RegExp(r'\b(rue|avenue|boulevard|bp|boîte|cedex|street|road|box|chemin|route|allée|impasse|place|square|parc|quartier|ville|pays|city|country|state|zip|postal|cedex)\b',
              caseSensitive: false)
          .hasMatch(line)) {
        continue;
      }
      if (RegExp(r'\b\d{4,6}\b').hasMatch(line) && line.length > 15) {
        continue;
      }

      leftover.add(line);
    }

    if (email != null) result['email'] = email;
    if (phone != null) result['phone'] = phone;

    // ── 3. Name / title / company from leftover lines ────────────────────
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

    // Heuristic for name: usually 2 or 3 words, no digits.
    for (var i = 0; i < remaining.length; i++) {
      final line = remaining[i];
      final words = line.split(RegExp(r'\s+'));
      final hasDigits = line.contains(RegExp(r'\d'));
      if (words.length >= 2 && words.length <= 4 && !hasDigits && detectedName == null) {
        detectedName = line;
        remaining.removeAt(i);
        break;
      }
    }

    // If still no name, take the first remaining line that's not too long
    if (detectedName == null && remaining.isNotEmpty) {
      detectedName = remaining.removeAt(0);
    }

    // If no company, take the next remaining line
    if (detectedCompany == null && remaining.isNotEmpty) {
      detectedCompany = remaining.removeAt(0);
    }

    // Set results
    if (detectedName != null) {
      final parts = detectedName.split(RegExp(r'\s+'));
      if (parts.length >= 2) {
        result['firstName'] = parts.first;
        result['lastName'] = parts.sublist(1).join(' ');
      } else {
        result['lastName'] = detectedName;
      }
    }

    if (detectedTitle != null) result['jobTitle'] = detectedTitle;
    if (detectedCompany != null) result['company'] = detectedCompany;

    // Remaining lines go to notes
    if (remaining.isNotEmpty) {
      notes.insert(0, remaining.join('\n'));
    }

    if (website != null) notes.add('Web: $website');

    if (tags.isNotEmpty) {
      // Deduplicate preserving order.
      final seen = <String>{};
      final uniq = tags.where((t) => seen.add(t.toLowerCase())).toList();
      result['tags'] = uniq.join(',');
    }
    if (notes.isNotEmpty) result['notes'] = notes.join('\n');

    return result;
  }

  /// Split "Key: value" or "Key - value" into the two sides.
  /// Returns null if the line doesn't look like a labelled field.
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

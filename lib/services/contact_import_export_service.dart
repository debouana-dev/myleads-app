import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';
import '../models/contact.dart';

/// CRM format to use when exporting CSV files.
enum CrmExportFormat { generic, salesforce, odoo, sap }

/// Handles import and export of contacts in CSV, vCard, and TXT formats.
///
/// CSV export headers match the standard import templates of Salesforce,
/// Odoo, and SAP so the exported file can be loaded directly into those
/// platforms without manual column mapping.
class ContactImportExportService {
  static const _uuid = Uuid();

  // ─── Export ───────────────────────────────────────────────────────────────

  static String exportToCsv(
    List<Contact> contacts, {
    CrmExportFormat format = CrmExportFormat.generic,
  }) {
    final buffer = StringBuffer();
    switch (format) {
      case CrmExportFormat.salesforce:
        buffer.writeln(_sfHeaders);
        for (final c in contacts) {
          buffer.writeln(_toSfRow(c));
        }
      case CrmExportFormat.odoo:
        buffer.writeln(_odooHeaders);
        for (final c in contacts) {
          buffer.writeln(_toOdooRow(c));
        }
      case CrmExportFormat.sap:
        buffer.writeln(_sapHeaders);
        for (final c in contacts) {
          buffer.writeln(_toSapRow(c));
        }
      case CrmExportFormat.generic:
        buffer.writeln(_genericHeaders);
        for (final c in contacts) {
          buffer.writeln(_toGenericRow(c));
        }
    }
    return buffer.toString();
  }

  static String exportToVCard(List<Contact> contacts) {
    final buf = StringBuffer();
    for (final c in contacts) {
      buf.write(_toVCard(c));
    }
    return buf.toString();
  }

  static String exportToTxt(List<Contact> contacts) {
    final buf = StringBuffer();
    for (int i = 0; i < contacts.length; i++) {
      buf.write(_toTxtBlock(contacts[i], i + 1));
    }
    return buf.toString();
  }

  // ─── CSV row builders ─────────────────────────────────────────────────────

  // Salesforce Lead import format
  // https://help.salesforce.com/s/articleView?id=sf.importing_leads.htm
  static const _sfHeaders =
      'First Name,Last Name,Company,Title,Phone,Email,Rating,'
      'Lead Source,Description,Status,Tags,Created Date';

  static String _toSfRow(Contact c) {
    final rating = _sfRating(c.status);
    return _joinCsv([
      c.firstName, c.lastName, c.company ?? '', c.jobTitle ?? '',
      c.phone ?? '', c.email ?? '', rating,
      c.source ?? '', c.notes ?? '', 'Open - Not Contacted',
      c.tags.join('; '), c.createdAt.toIso8601String(),
    ]);
  }

  static String _sfRating(String status) =>
      status == 'hot' ? 'Hot' : status == 'warm' ? 'Warm' : 'Cold';

  // Odoo res.partner / crm.lead compatible
  // https://www.odoo.com/documentation/17.0/applications/general/export_import_data.html
  static const _odooHeaders =
      'id,name,company_name,function,phone,email,'
      'comment,category_id,source,x_me2leads_status,x_me2leads_created';

  static String _toOdooRow(Contact c) => _joinCsv([
        c.id, c.fullName, c.company ?? '', c.jobTitle ?? '',
        c.phone ?? '', c.email ?? '', c.notes ?? '',
        c.tags.join(', '), c.source ?? '',
        c.status, c.createdAt.toIso8601String(),
      ]);

  // SAP CRM Individual Account / Business Partner format
  static const _sapHeaders =
      'FIRST_NAME,LAST_NAME,COMPANY,POSITION,PHONE,EMAIL,'
      'NOTES,SOURCE,CATEGORY,PRIORITY,EXTERNAL_ID,CREATED_DATE';

  static String _toSapRow(Contact c) => _joinCsv([
        c.firstName, c.lastName, c.company ?? '', c.jobTitle ?? '',
        c.phone ?? '', c.email ?? '', c.notes ?? '',
        c.source ?? '', c.tags.join('; '), _sapPriority(c.status),
        c.id, c.createdAt.toIso8601String(),
      ]);

  static String _sapPriority(String status) =>
      status == 'hot' ? 'HIGH' : status == 'warm' ? 'MEDIUM' : 'LOW';

  // Generic – all fields, round-trips cleanly back into import
  static const _genericHeaders =
      'id,first_name,last_name,job_title,company,phone,email,'
      'status,source,notes,tags,created_date,last_contact_date,capture_method';

  static String _toGenericRow(Contact c) => _joinCsv([
        c.id, c.firstName, c.lastName, c.jobTitle ?? '', c.company ?? '',
        c.phone ?? '', c.email ?? '', c.status, c.source ?? '',
        c.notes ?? '', c.tags.join('; '),
        c.createdAt.toIso8601String(),
        c.lastContactDate?.toIso8601String() ?? '',
        c.captureMethod,
      ]);

  // ─── vCard builder (RFC 6350 / v3) ───────────────────────────────────────

  static String _toVCard(Contact c) {
    final lines = <String>[
      'BEGIN:VCARD',
      'VERSION:3.0',
      'FN:${_ve(c.fullName)}',
      'N:${_ve(c.lastName)};${_ve(c.firstName)};;;',
    ];
    if (c.company?.isNotEmpty == true) lines.add('ORG:${_ve(c.company!)}');
    if (c.jobTitle?.isNotEmpty == true) lines.add('TITLE:${_ve(c.jobTitle!)}');
    if (c.phone?.isNotEmpty == true) {
      lines.add('TEL;TYPE=WORK,VOICE:${c.phone}');
    }
    if (c.email?.isNotEmpty == true) {
      lines.add('EMAIL;TYPE=WORK:${c.email}');
    }
    if (c.notes?.isNotEmpty == true) lines.add('NOTE:${_ve(c.notes!)}');
    if (c.tags.isNotEmpty) lines.add('CATEGORIES:${c.tags.join(',')}');
    if (c.source?.isNotEmpty == true) {
      lines.add('X-ME2LEADS-SOURCE:${_ve(c.source!)}');
    }
    lines
      ..add('X-ME2LEADS-STATUS:${c.status}')
      ..add('X-ME2LEADS-CAPTURE:${c.captureMethod}')
      ..add('REV:${c.createdAt.toUtc().toIso8601String()}')
      ..add('UID:${c.id}')
      ..add('END:VCARD')
      ..add('');
    return lines.join('\r\n');
  }

  // ─── TXT builder ─────────────────────────────────────────────────────────

  static String _toTxtBlock(Contact c, int index) {
    final lines = <String>[
      '--- Contact $index ---',
      'First Name: ${c.firstName}',
      'Last Name: ${c.lastName}',
    ];
    if (c.jobTitle?.isNotEmpty == true) lines.add('Job Title: ${c.jobTitle}');
    if (c.company?.isNotEmpty == true) lines.add('Company: ${c.company}');
    if (c.phone?.isNotEmpty == true) lines.add('Phone: ${c.phone}');
    if (c.email?.isNotEmpty == true) lines.add('Email: ${c.email}');
    lines.add('Status: ${_capitalize(c.status)} Lead');
    if (c.source?.isNotEmpty == true) lines.add('Source: ${c.source}');
    if (c.tags.isNotEmpty) lines.add('Tags: ${c.tags.join(', ')}');
    if (c.notes?.isNotEmpty == true) lines.add('Notes: ${c.notes}');
    lines.add('Created: ${c.createdAt.toIso8601String()}');
    if (c.lastContactDate != null) {
      lines.add('Last Contact: ${c.lastContactDate!.toIso8601String()}');
    }
    lines
      ..add('Capture Method: ${c.captureMethod}')
      ..add('');
    return lines.join('\n');
  }

  // ─── Import ───────────────────────────────────────────────────────────────

  /// Parses a CSV file (Salesforce / Odoo / SAP / generic) into Contact list.
  /// Header detection is case-insensitive; unknown columns are ignored.
  static List<Contact> importFromCsv(String content, String ownerId) {
    final lines = _splitLines(content);
    if (lines.isEmpty) return [];

    final headers =
        _parseCsvRow(lines[0]).map((h) => h.trim().toLowerCase()).toList();
    if (headers.isEmpty) return [];

    final contacts = <Contact>[];
    for (int i = 1; i < lines.length; i++) {
      final line = lines[i].trim();
      if (line.isEmpty) continue;
      final row = _parseCsvRow(line);
      final map = <String, String>{};
      for (int j = 0; j < headers.length && j < row.length; j++) {
        map[headers[j]] = row[j].trim();
      }
      final c = _contactFromFlatMap(map, ownerId);
      if (c != null) contacts.add(c);
    }
    return contacts;
  }

  /// Parses a vCard file (.vcf) into Contact list.
  /// Supports vCard 2.1, 3.0 and 4.0; handles line folding.
  static List<Contact> importFromVCard(String content, String ownerId) {
    final contacts = <Contact>[];
    final normalized = content
        .replaceAll('\r\n', '\n')
        .replaceAll('\r', '\n')
        // Unfold continued lines (line beginning with SPACE or TAB)
        .replaceAll('\n ', '')
        .replaceAll('\n\t', '');

    for (final block in normalized.split(RegExp('BEGIN:VCARD', caseSensitive: false))) {
      if (block.trim().isEmpty) continue;
      final endIdx = block.toUpperCase().indexOf('END:VCARD');
      final body = endIdx >= 0 ? block.substring(0, endIdx) : block;
      final c = _parseVCard(body.trim(), ownerId);
      if (c != null) contacts.add(c);
    }
    return contacts;
  }

  /// Parses a Me2Leads TXT export back into Contact list.
  static List<Contact> importFromTxt(String content, String ownerId) {
    final contacts = <Contact>[];
    final normalized =
        content.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    final blocks = normalized.split(RegExp(r'--- Contact \d+ ---'));
    for (final block in blocks) {
      if (block.trim().isEmpty) continue;
      final c = _parseTxtBlock(block.trim(), ownerId);
      if (c != null) contacts.add(c);
    }
    return contacts;
  }

  // ─── Import – map → Contact ───────────────────────────────────────────────

  static Contact? _contactFromFlatMap(
      Map<String, String> map, String ownerId) {
    // --- Name resolution ---
    // Prefer explicit first/last; fall back to splitting a full-name field.
    String firstName =
        _pick(map, ['first_name', 'firstname', 'first name', 'prénom']);
    String lastName =
        _pick(map, ['last_name', 'lastname', 'last name', 'nom']);

    if (firstName.isEmpty && lastName.isEmpty) {
      final full = _pick(map, [
        'name', 'full_name', 'fullname', 'full name',
        'cardname', 'contact_name', 'contact',
      ]);
      if (full.isNotEmpty) {
        final parts = full.trim().split(RegExp(r'\s+'));
        firstName = parts.first;
        lastName = parts.length > 1 ? parts.sublist(1).join(' ') : '';
      }
    }

    // Need at least a last name
    if (firstName.isEmpty && lastName.isEmpty) return null;
    if (lastName.isEmpty) {
      lastName = firstName;
      firstName = '';
    }

    final phone = _pick(map, [
      'phone', 'phone1', 'mobile', 'tel', 'telephone',
      'business phone', 'business_phone', 'téléphone',
    ]);
    final email = _pick(map, [
      'email', 'email_from', 'business email', 'business_email', 'e-mail',
    ]);

    if (phone.isEmpty && email.isEmpty) return null;

    return Contact(
      id: _uuid.v4(),
      firstName: firstName,
      lastName: lastName,
      jobTitle: _n(_pick(map, [
        'title', 'job_title', 'jobtitle', 'job title',
        'position', 'function', 'fonction',
      ])),
      company: _n(_pick(map, [
        'company', 'company_name', 'account name', 'account_name',
        'cardname', 'société',
      ])),
      phone: _n(phone),
      email: _n(email),
      notes: _n(_pick(map, [
        'description', 'notes', 'comment', 'commentaire', 'note',
      ])),
      source: _n(_pick(map, [
        'lead source', 'source', 'lead_source', 'source_id',
      ])),
      tags: _parseTags(_pick(map, [
        'tags', 'tag_ids', 'category_id', 'category', 'categories',
        'catégorie',
      ])),
      status: _resolveStatus(_pick(map, [
        'status', 'rating', 'priority', 'lead_status', 'x_me2leads_status',
      ])),
      ownerId: ownerId,
      captureMethod: 'imported',
    );
  }

  // ─── Import – vCard parser ────────────────────────────────────────────────

  static Contact? _parseVCard(String body, String ownerId) {
    String firstName = '', lastName = '';
    String? jobTitle, company, phone, email, notes, source;
    String status = 'warm';
    List<String> tags = [];

    for (final rawLine in body.split('\n')) {
      final line = rawLine.trim();
      if (line.isEmpty) continue;
      final colon = line.indexOf(':');
      if (colon < 0) continue;
      final key = line.substring(0, colon).toUpperCase();
      final val = _vu(line.substring(colon + 1).trim());

      if (key == 'FN' && firstName.isEmpty && lastName.isEmpty) {
        final parts = val.split(RegExp(r'\s+'));
        firstName = parts.first;
        lastName = parts.length > 1 ? parts.sublist(1).join(' ') : '';
      } else if (key == 'N') {
        final p = val.split(';');
        if (p.isNotEmpty) lastName = p[0];
        if (p.length > 1) firstName = p[1];
      } else if (key == 'ORG') {
        company = val.split(';').first;
      } else if (key == 'TITLE') {
        jobTitle = val;
      } else if (key.startsWith('TEL') && phone == null) {
        phone = val;
      } else if (key.startsWith('EMAIL') && email == null) {
        email = val;
      } else if (key == 'NOTE') {
        notes = val;
      } else if (key == 'CATEGORIES') {
        tags = val.split(',').map((t) => t.trim()).where((t) => t.isNotEmpty).toList();
      } else if (key == 'X-ME2LEADS-STATUS') {
        status = _resolveStatus(val);
      } else if (key == 'X-ME2LEADS-SOURCE') {
        source = val;
      }
    }

    if (firstName.isEmpty && lastName.isEmpty) return null;
    if (phone == null && email == null) return null;

    return Contact(
      id: _uuid.v4(),
      firstName: firstName,
      lastName: lastName,
      jobTitle: _n(jobTitle),
      company: _n(company),
      phone: _n(phone),
      email: _n(email),
      notes: _n(notes),
      source: _n(source),
      tags: tags,
      status: status,
      ownerId: ownerId,
      captureMethod: 'imported',
    );
  }

  // ─── Import – TXT parser ──────────────────────────────────────────────────

  static Contact? _parseTxtBlock(String block, String ownerId) {
    final map = <String, String>{};
    for (final line in block.split('\n')) {
      final colon = line.indexOf(':');
      if (colon < 0) continue;
      final key = line.substring(0, colon).trim().toLowerCase();
      final val = line.substring(colon + 1).trim();
      if (val.isNotEmpty) map[key] = val;
    }

    final firstName = map['first name'] ?? map['prénom'] ?? '';
    final lastName = map['last name'] ?? map['nom'] ?? '';
    if (firstName.isEmpty && lastName.isEmpty) return null;

    final phone = map['phone'] ?? map['téléphone'] ?? '';
    final email = map['email'] ?? '';
    if (phone.isEmpty && email.isEmpty) return null;

    DateTime? createdAt;
    final createdRaw = map['created'];
    if (createdRaw != null) {
      try {
        createdAt = DateTime.parse(createdRaw);
      } catch (_) {}
    }

    return Contact(
      id: _uuid.v4(),
      firstName: firstName,
      lastName: lastName,
      jobTitle: _n(map['job title']),
      company: _n(map['company'] ?? map['société']),
      phone: _n(phone),
      email: _n(email),
      notes: _n(map['notes']),
      source: _n(map['source']),
      tags: _parseTags(map['tags'] ?? ''),
      status: _resolveStatus(map['status'] ?? ''),
      ownerId: ownerId,
      captureMethod: 'imported',
      createdAt: createdAt,
    );
  }

  // ─── File helpers ─────────────────────────────────────────────────────────

  static Future<File> writeExportFile(String content, String filename) async {
    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}/$filename');
    await file.writeAsString(content, flush: true);
    return file;
  }

  // ─── Utility ──────────────────────────────────────────────────────────────

  static String _joinCsv(List<String> fields) =>
      fields.map(_csvQuote).join(',');

  static String _csvQuote(String v) {
    if (v.contains(',') || v.contains('"') || v.contains('\n') || v.contains('\r')) {
      return '"${v.replaceAll('"', '""')}"';
    }
    return v;
  }

  // Case-insensitive field lookup across a list of candidate keys.
  static String _pick(Map<String, String> map, List<String> keys) {
    for (final k in keys) {
      final v = map[k];
      if (v != null && v.isNotEmpty) return v;
    }
    return '';
  }

  static String? _n(String? v) => (v == null || v.isEmpty) ? null : v;

  // vCard escape / unescape
  static String _ve(String v) => v
      .replaceAll('\\', '\\\\')
      .replaceAll('\n', '\\n')
      .replaceAll(',', '\\,')
      .replaceAll(';', '\\;');

  static String _vu(String v) => v
      .replaceAll('\\n', '\n')
      .replaceAll('\\N', '\n')
      .replaceAll('\\,', ',')
      .replaceAll('\\;', ';')
      .replaceAll('\\\\', '\\');

  static String _capitalize(String s) =>
      s.isEmpty ? s : '${s[0].toUpperCase()}${s.substring(1)}';

  /// Maps various CRM status/rating/priority strings to hot/warm/cold.
  static String _resolveStatus(String raw) {
    final s = raw.toLowerCase();
    if (s.contains('hot') || s.contains('high') || s.contains('chaud') ||
        s.contains('very_important') || s.contains('très')) {
      return 'hot';
    }
    if (s.contains('cold') || s.contains('low') || s.contains('froid')) {
      return 'cold';
    }
    return 'warm';
  }

  static List<String> _parseTags(String raw) {
    if (raw.isEmpty) return [];
    return raw
        .split(RegExp(r'[;,]'))
        .map((t) => t.trim())
        .where((t) => t.isNotEmpty)
        .toList();
  }

  static List<String> _splitLines(String content) =>
      content.replaceAll('\r\n', '\n').replaceAll('\r', '\n').split('\n');

  /// RFC-4180 compliant CSV row parser.
  static List<String> _parseCsvRow(String line) {
    final fields = <String>[];
    final buf = StringBuffer();
    bool inQuotes = false;

    for (int i = 0; i < line.length; i++) {
      final ch = line[i];
      if (ch == '"') {
        if (inQuotes && i + 1 < line.length && line[i + 1] == '"') {
          buf.write('"');
          i++;
        } else {
          inQuotes = !inQuotes;
        }
      } else if (ch == ',' && !inQuotes) {
        fields.add(buf.toString());
        buf.clear();
      } else {
        buf.write(ch);
      }
    }
    fields.add(buf.toString());
    return fields;
  }
}

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/l10n/app_l10n.dart';
import '../core/utils/validators.dart';
import '../models/contact.dart';
import 'action_tracker.dart';

/// Centralized actions for interacting with a contact:
/// call, SMS, WhatsApp, email, share.
///
/// Each method opens the corresponding default app on the user's device.
/// Returns false (and shows a SnackBar) if the action cannot be performed
/// because the contact is missing the required field.
class ContactActions {
  ContactActions._();

  /// Open the default phone app with the contact's number ready to call.
  static Future<bool> call(BuildContext context, Contact contact) async {
    if (contact.phone == null || contact.phone!.trim().isEmpty) {
      final l10n = ProviderScope.containerOf(context).read(l10nProvider);
      _toast(context, l10n.contactNoPhone);
      return false;
    }
    final uri = Uri(scheme: 'tel', path: _cleanPhone(contact.phone!));
    ActionTracker.markPendingAction(contact.id, 'call');
    return _launch(context, uri, 'Impossible d\'ouvrir l\'application Téléphone');
  }

  /// Open the default SMS app with the contact's number ready to send a message.
  static Future<bool> sms(BuildContext context, Contact contact) async {
    if (contact.phone == null || contact.phone!.trim().isEmpty) {
      final l10n = ProviderScope.containerOf(context).read(l10nProvider);
      _toast(context, l10n.contactNoPhone);
      return false;
    }
    final uri = Uri(scheme: 'sms', path: _cleanPhone(contact.phone!));
    ActionTracker.markPendingAction(contact.id, 'sms');
    return _launch(context, uri, 'Impossible d\'ouvrir l\'application SMS');
  }

  /// Open WhatsApp with the contact's number ready to chat.
  static Future<bool> whatsapp(BuildContext context, Contact contact) async {
    if (contact.phone == null || contact.phone!.trim().isEmpty) {
      final l10n = ProviderScope.containerOf(context).read(l10nProvider);
      _toast(context, l10n.contactNoPhone);
      return false;
    }
    // WhatsApp expects digits only, no leading + or spaces.
    final digits = contact.phone!.replaceAll(RegExp(r'[^0-9]'), '');
    if (digits.isEmpty) {
      final l10n = ProviderScope.containerOf(context).read(l10nProvider);
      _toast(context, l10n.contactInvalidPhone);
      return false;
    }
    final uri = Uri.parse('https://wa.me/$digits');
    ActionTracker.markPendingAction(contact.id, 'whatsapp');
    return _launch(
      context,
      uri,
      'Impossible d\'ouvrir WhatsApp',
      mode: LaunchMode.externalApplication,
    );
  }

  /// Open the default email app with a new message addressed to the contact.
  static Future<bool> email(BuildContext context, Contact contact) async {
    if (contact.email == null || contact.email!.trim().isEmpty) {
      final l10n = ProviderScope.containerOf(context).read(l10nProvider);
      _toast(context, l10n.contactNoEmail);
      return false;
    }
    final uri = Uri(
      scheme: 'mailto',
      path: contact.email!.trim(),
    );
    ActionTracker.markPendingAction(contact.id, 'email');
    return _launch(context, uri, 'Impossible d\'ouvrir l\'application Email');
  }

  /// Share the contact profile as text via the system share sheet.
  static Future<void> share(BuildContext context, Contact contact) async {
    final buf = StringBuffer();
    buf.writeln(contact.fullName);
    if (contact.jobTitle != null && contact.jobTitle!.isNotEmpty) {
      buf.writeln(contact.jobTitle);
    }
    if (contact.company != null && contact.company!.isNotEmpty) {
      buf.writeln(contact.company);
    }
    buf.writeln();
    if (contact.phone != null && contact.phone!.isNotEmpty) {
      buf.writeln('Téléphone : ${contact.phone}');
    }
    if (contact.email != null && contact.email!.isNotEmpty) {
      buf.writeln('Email : ${contact.email}');
    }
    if (contact.source != null && contact.source!.isNotEmpty) {
      buf.writeln('Source : ${contact.source}');
    }
    if (contact.project1 != null && contact.project1!.isNotEmpty) {
      buf.write('Projet 1 : ${contact.project1}');
      if (contact.project1Budget != null && contact.project1Budget!.isNotEmpty) {
        buf.write(' (${contact.project1Budget})');
      }
      buf.writeln();
    }
    if (contact.project2 != null && contact.project2!.isNotEmpty) {
      buf.write('Projet 2 : ${contact.project2}');
      if (contact.project2Budget != null && contact.project2Budget!.isNotEmpty) {
        buf.write(' (${contact.project2Budget})');
      }
      buf.writeln();
    }
    if (contact.notes != null && contact.notes!.isNotEmpty) {
      buf.writeln();
      buf.writeln('Notes : ${contact.notes}');
    }
    buf.writeln();
    buf.writeln('Partagé via Me2Leads');

    await SharePlus.instance.share(
      ShareParams(
        text: buf.toString(),
        subject: 'Contact : ${contact.fullName}',
      ),
    );
  }

  // ---------------- helpers ----------------

  static Future<bool> _launch(
    BuildContext context,
    Uri uri,
    String errorMessage, {
    LaunchMode mode = LaunchMode.externalApplication,
  }) async {
    try {
      final ok = await launchUrl(uri, mode: mode);
      if (!ok) _toast(context, errorMessage);
      return ok;
    } catch (_) {
      _toast(context, errorMessage);
      return false;
    }
  }

  static String _cleanPhone(String phone) {
    // tel: scheme accepts + and digits; strip everything else.
    final normalized = Validators.normalizePhone(phone);
    return normalized.isEmpty ? phone : normalized;
  }

  static void _toast(BuildContext context, String message) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 2),
      ),
    );
  }
}

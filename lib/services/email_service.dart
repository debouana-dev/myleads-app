import 'package:flutter/foundation.dart';
import 'package:mailer/mailer.dart';
import 'package:mailer/smtp_server.dart';

import '../config/app_config.dart';

/// Handles all outbound email delivery via SMTP.
///
/// All methods are fire-and-return — they never throw. A `false` return
/// value means the email could not be sent (network error, quota, etc.)
/// but the calling code should still treat the operation as continuing;
/// verification / recovery codes are held in-memory regardless.
class EmailService {
  EmailService._();

  static const _timeout = Duration(seconds: 20);

  static SmtpServer get _smtpServer => SmtpServer(
        AppConfig.smtpHost,
        port: AppConfig.smtpPort,
        username: AppConfig.smtpUsername,
        password: AppConfig.smtpPassword,
        ssl: AppConfig.smtpSsl,
      );

  // ── Public API ──────────────────────────────────────────────────────────

  /// Sends a 6-digit email-verification code to [toEmail].
  ///
  /// Returns `true` if the SMTP transaction succeeded.
  static Future<bool> sendVerificationEmail(
      String toEmail, String code) async {
    final htmlBody = '''
<div style="font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif; max-width: 600px; margin: 0 auto; padding: 20px; color: #333;">
  <div style="text-align: center; margin-bottom: 30px;">
    <h1 style="color: #0B3C5D; margin: 0;">Me2Leads</h1>
    <p style="color: #666; font-size: 14px;">Votre assistant de prospection intelligent</p>
  </div>
  
  <div style="background-color: #f9f9f9; border-radius: 8px; padding: 30px; border: 1px solid #eee;">
    <h2 style="margin-top: 0; color: #333; font-size: 20px;">Vérification de votre compte</h2>
    <p>Bonjour,</p>
    <p>Merci d'avoir rejoint Me2Leads ! Pour activer votre compte, veuillez utiliser le code de vérification suivant :</p>
    
    <div style="margin: 30px 0; text-align: center;">
      <span style="display: inline-block; background-color: #0B3C5D; color: white; padding: 15px 30px; font-size: 32px; font-weight: bold; letter-spacing: 8px; border-radius: 6px; box-shadow: 0 4px 6px rgba(0,0,0,0.1);">
        $code
      </span>
    </div>
    
    <p style="font-size: 14px; color: #666;">Ce code est valide pendant <strong>10 minutes</strong>. Passé ce délai, vous devrez en demander un nouveau.</p>
  </div>
  
  <div style="margin-top: 30px; font-size: 12px; color: #999; text-align: center;">
    <p>Si vous n'avez pas créé de compte Me2Leads, vous pouvez ignorer cet email en toute sécurité.</p>
    <p>&copy; ${DateTime.now().year} Me2Leads. Tous droits réservés.</p>
  </div>
</div>
''';

    return _sendEmail(
      to: toEmail,
      subject: 'Code de vérification Me2Leads : $code',
      body: 'Votre code de vérification Me2Leads est : $code\n\nCe code expire dans 10 minutes.',
      htmlBody: htmlBody,
    );
  }

  /// Sends a 6-digit password-recovery code to [toEmail].
  ///
  /// Returns `true` if the SMTP transaction succeeded.
  static Future<bool> sendRecoveryEmail(String toEmail, String code) async {
    final htmlBody = '''
<div style="font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif; max-width: 600px; margin: 0 auto; padding: 20px; color: #333;">
  <div style="text-align: center; margin-bottom: 30px;">
    <h1 style="color: #0B3C5D; margin: 0;">Me2Leads</h1>
  </div>
  
  <div style="background-color: #f9f9f9; border-radius: 8px; padding: 30px; border: 1px solid #eee;">
    <h2 style="margin-top: 0; color: #333; font-size: 20px;">Réinitialisation de votre mot de passe</h2>
    <p>Bonjour,</p>
    <p>Vous avez demandé la réinitialisation de votre mot de passe Me2Leads. Voici votre code de récupération :</p>
    
    <div style="margin: 30px 0; text-align: center;">
      <span style="display: inline-block; background-color: #d32f2f; color: white; padding: 15px 30px; font-size: 32px; font-weight: bold; letter-spacing: 8px; border-radius: 6px;">
        $code
      </span>
    </div>
    
    <p style="font-size: 14px; color: #666;">Ce code est valide pendant <strong>10 minutes</strong>.</p>
  </div>
  
  <div style="margin-top: 30px; font-size: 12px; color: #999; text-align: center;">
    <p>Si vous n'avez pas demandé de réinitialisation, veuillez ignorer cet email.</p>
    <p>&copy; ${DateTime.now().year} Me2Leads.</p>
  </div>
</div>
''';

    return _sendEmail(
      to: toEmail,
      subject: 'Code de récupération Me2Leads : $code',
      body: 'Votre code de récupération Me2Leads est : $code\n\nCe code expire dans 10 minutes.',
      htmlBody: htmlBody,
    );
  }

  // ── Internal ────────────────────────────────────────────────────────────

  static Future<bool> _sendEmail({
    required String to,
    required String subject,
    required String body,
    String? htmlBody,
  }) async {
    try {
      final message = Message()
        ..from = Address(AppConfig.smtpUsername, 'Me2Leads')
        ..recipients.add(to)
        ..subject = subject
        ..text = body;
        
      if (htmlBody != null) {
        message.html = htmlBody;
      }

      await send(message, _smtpServer, timeout: _timeout);
      return true;
    } catch (e) {
      // Email sending failed — the in-memory code is still valid.
      // Callers should not surface this error directly; the code flow
      // continues normally.
      debugPrint('EmailService: SMTP delivery failed — $e');
      return false;
    }
  }
}

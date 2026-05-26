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

  /// Notifies [toEmail] that they have become the owner of [orgName].
  /// [outgoingOwnerName] is the display name of the previous owner.
  /// Returns true if SMTP delivery succeeded; callers must not depend on the result.
  static Future<bool> sendOwnershipTransferNotification({
    required String toEmail,
    required String orgName,
    required String outgoingOwnerName,
  }) async {
    final year = DateTime.now().year;
    final htmlBody = '''
<div style="font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif; max-width: 600px; margin: 0 auto; padding: 20px; color: #333;">
  <div style="text-align: center; margin-bottom: 30px;">
    <h1 style="color: #0B3C5D; margin: 0;">Me2Leads</h1>
    <p style="color: #666; font-size: 14px;">Votre assistant de prospection intelligent</p>
  </div>

  <div style="background-color: #f9f9f9; border-radius: 8px; padding: 30px; border: 1px solid #eee;">
    <h2 style="margin-top: 0; color: #333; font-size: 20px;">Vous êtes maintenant propriétaire de l\'organisation</h2>
    <p>Bonjour,</p>
    <p><strong>$outgoingOwnerName</strong> vous a transféré la propriété de l\'organisation <strong>$orgName</strong> sur Me2Leads.</p>
    <p>Vous disposez désormais de tous les droits de propriétaire, notamment :</p>
    <ul style="color: #444;">
      <li>Gérer les membres et leurs rôles</li>
      <li>Renommer ou supprimer l\'organisation</li>
      <li>Gérer les licences et les abonnements</li>
    </ul>
    <p style="font-size: 14px; color: #666;">Connectez-vous à l\'application Me2Leads pour accéder à votre tableau de bord d\'organisation.</p>
  </div>

  <div style="margin-top: 30px; font-size: 12px; color: #999; text-align: center;">
    <p>Si vous pensez avoir reçu cet email par erreur, contactez le support Me2Leads.</p>
    <p>&copy; $year Me2Leads. Tous droits réservés.</p>
  </div>
</div>
''';

    return _sendEmail(
      to: toEmail,
      subject: 'Me2Leads — Vous êtes maintenant propriétaire de $orgName',
      body: 'Bonjour,\n\n$outgoingOwnerName vous a transféré la propriété de'
          ' l\'organisation "$orgName" sur Me2Leads.\n\n'
          'Connectez-vous à l\'application pour gérer votre organisation.\n\n'
          '© $year Me2Leads.',
      htmlBody: htmlBody,
    );
  }

  /// Notifies the org owner that [memberName] has voluntarily left [orgName].
  /// Returns true if SMTP delivery succeeded; callers must not depend on the result.
  static Future<bool> sendMemberLeaveNotification({
    required String toEmail,
    required String orgName,
    required String memberName,
  }) async {
    final year = DateTime.now().year;
    final htmlBody = '''
<div style="font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif; max-width: 600px; margin: 0 auto; padding: 20px; color: #333;">
  <div style="text-align: center; margin-bottom: 30px;">
    <h1 style="color: #0B3C5D; margin: 0;">Me2Leads</h1>
    <p style="color: #666; font-size: 14px;">Votre assistant de prospection intelligent</p>
  </div>

  <div style="background-color: #f9f9f9; border-radius: 8px; padding: 30px; border: 1px solid #eee;">
    <h2 style="margin-top: 0; color: #333; font-size: 20px;">Un membre a quitté votre organisation</h2>
    <p>Bonjour,</p>
    <p><strong>$memberName</strong> a quitté l'organisation <strong>$orgName</strong>.</p>
    <p>Les contacts qu'il/elle avait apportés à l'organisation ont été copiés dans votre compte. Les contacts créés pendant son appartenance à l'organisation ont été transférés à votre compte.</p>
    <p style="font-size: 14px; color: #666;">Connectez-vous à l'application Me2Leads pour consulter et gérer vos contacts.</p>
  </div>

  <div style="margin-top: 30px; font-size: 12px; color: #999; text-align: center;">
    <p>Si vous pensez avoir reçu cet email par erreur, contactez le support Me2Leads.</p>
    <p>&copy; $year Me2Leads. Tous droits réservés.</p>
  </div>
</div>
''';

    return _sendEmail(
      to: toEmail,
      subject: 'Me2Leads — $memberName a quitté $orgName',
      body: 'Bonjour,\n\n$memberName a quitté l\'organisation "$orgName".\n\n'
          'Les contacts apportés lors de son adhésion ont été copiés dans votre compte. '
          'Les contacts créés pendant son appartenance ont été transférés à votre compte.\n\n'
          '© $year Me2Leads.',
      htmlBody: htmlBody,
    );
  }

  /// Notifies the org owner/admins that [memberName] has joined [orgName].
  /// Returns true if SMTP delivery succeeded; callers must not depend on the result.
  static Future<bool> sendMemberJoinNotification({
    required String toEmail,
    required String orgName,
    required String memberName,
  }) async {
    final year = DateTime.now().year;
    final htmlBody = '''
<div style="font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif; max-width: 600px; margin: 0 auto; padding: 20px; color: #333;">
  <div style="text-align: center; margin-bottom: 30px;">
    <h1 style="color: #0B3C5D; margin: 0;">Me2Leads</h1>
    <p style="color: #666; font-size: 14px;">Votre assistant de prospection intelligent</p>
  </div>

  <div style="background-color: #f9f9f9; border-radius: 8px; padding: 30px; border: 1px solid #eee;">
    <h2 style="margin-top: 0; color: #333; font-size: 20px;">Un nouveau membre a rejoint votre organisation</h2>
    <p>Bonjour,</p>
    <p><strong>$memberName</strong> a rejoint l\'organisation <strong>$orgName</strong>.</p>
    <p style="font-size: 14px; color: #666;">Connectez-vous à l\'application Me2Leads pour gérer les membres et leurs privilèges.</p>
  </div>

  <div style="margin-top: 30px; font-size: 12px; color: #999; text-align: center;">
    <p>Si vous pensez avoir reçu cet email par erreur, contactez le support Me2Leads.</p>
    <p>&copy; $year Me2Leads. Tous droits réservés.</p>
  </div>
</div>
''';

    return _sendEmail(
      to: toEmail,
      subject: 'Me2Leads — $memberName a rejoint $orgName',
      body: 'Bonjour,\n\n$memberName a rejoint votre organisation "$orgName".\n\n'
          'Connectez-vous à l\'application pour gérer vos membres.\n\n'
          '© $year Me2Leads.',
      htmlBody: htmlBody,
    );
  }

  /// Notifies [toEmail] that their access to [orgName] has been suspended.
  /// Returns true if SMTP delivery succeeded; callers must not depend on the result.
  static Future<bool> sendMemberSuspendedNotification({
    required String toEmail,
    required String orgName,
    required String memberName,
  }) async {
    final year = DateTime.now().year;
    final htmlBody = '''
<div style="font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif; max-width: 600px; margin: 0 auto; padding: 20px; color: #333;">
  <div style="text-align: center; margin-bottom: 30px;">
    <h1 style="color: #0B3C5D; margin: 0;">Me2Leads</h1>
    <p style="color: #666; font-size: 14px;">Votre assistant de prospection intelligent</p>
  </div>
  <div style="background-color: #f9f9f9; border-radius: 8px; padding: 30px; border: 1px solid #eee;">
    <h2 style="margin-top: 0; color: #333; font-size: 20px;">Votre accès à l'organisation a été suspendu</h2>
    <p>Bonjour $memberName,</p>
    <p>Votre accès à l'organisation <strong>$orgName</strong> sur Me2Leads a été suspendu par un administrateur.</p>
    <p>Vos contacts personnels restent accessibles dans votre compte.</p>
    <p style="font-size: 14px; color: #666;">Si vous pensez qu'il s'agit d'une erreur, veuillez contacter l'administrateur de votre organisation.</p>
  </div>
  <div style="margin-top: 30px; font-size: 12px; color: #999; text-align: center;">
    <p>&copy; $year Me2Leads. Tous droits réservés.</p>
  </div>
</div>
''';
    return _sendEmail(
      to: toEmail,
      subject: 'Me2Leads — Votre accès à $orgName a été suspendu',
      body: 'Bonjour $memberName,\n\nVotre accès à l\'organisation "$orgName" a été suspendu par un administrateur.\n\nVos contacts personnels restent accessibles.\n\n© $year Me2Leads.',
      htmlBody: htmlBody,
    );
  }

  /// Notifies [toEmail] that they have been removed from [orgName].
  /// Returns true if SMTP delivery succeeded; callers must not depend on the result.
  static Future<bool> sendMemberRemovedNotification({
    required String toEmail,
    required String orgName,
    required String memberName,
  }) async {
    final year = DateTime.now().year;
    final htmlBody = '''
<div style="font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif; max-width: 600px; margin: 0 auto; padding: 20px; color: #333;">
  <div style="text-align: center; margin-bottom: 30px;">
    <h1 style="color: #0B3C5D; margin: 0;">Me2Leads</h1>
    <p style="color: #666; font-size: 14px;">Votre assistant de prospection intelligent</p>
  </div>
  <div style="background-color: #f9f9f9; border-radius: 8px; padding: 30px; border: 1px solid #eee;">
    <h2 style="margin-top: 0; color: #333; font-size: 20px;">Vous avez été retiré de l'organisation</h2>
    <p>Bonjour $memberName,</p>
    <p>Vous avez été retiré de l'organisation <strong>$orgName</strong> sur Me2Leads par un administrateur.</p>
    <p>Les contacts que vous aviez apportés lors de votre adhésion restent disponibles dans votre compte personnel.</p>
    <p style="font-size: 14px; color: #666;">Si vous pensez qu'il s'agit d'une erreur, veuillez contacter l'administrateur de votre organisation.</p>
  </div>
  <div style="margin-top: 30px; font-size: 12px; color: #999; text-align: center;">
    <p>&copy; $year Me2Leads. Tous droits réservés.</p>
  </div>
</div>
''';
    return _sendEmail(
      to: toEmail,
      subject: 'Me2Leads — Vous avez été retiré de $orgName',
      body: 'Bonjour $memberName,\n\nVous avez été retiré de l\'organisation "$orgName" par un administrateur.\n\nLes contacts apportés lors de votre adhésion restent dans votre compte personnel.\n\n© $year Me2Leads.',
      htmlBody: htmlBody,
    );
  }

  /// Notifies [toEmail] that their access to [orgName] has been reactivated.
  /// Returns true if SMTP delivery succeeded; callers must not depend on the result.
  static Future<bool> sendMemberReactivatedNotification({
    required String toEmail,
    required String orgName,
    required String memberName,
  }) async {
    final year = DateTime.now().year;
    final htmlBody = '''
<div style="font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif; max-width: 600px; margin: 0 auto; padding: 20px; color: #333;">
  <div style="text-align: center; margin-bottom: 30px;">
    <h1 style="color: #0B3C5D; margin: 0;">Me2Leads</h1>
    <p style="color: #666; font-size: 14px;">Votre assistant de prospection intelligent</p>
  </div>
  <div style="background-color: #f9f9f9; border-radius: 8px; padding: 30px; border: 1px solid #eee;">
    <h2 style="margin-top: 0; color: #333; font-size: 20px;">Votre accès à l'organisation a été réactivé</h2>
    <p>Bonjour $memberName,</p>
    <p>Votre accès à l'organisation <strong>$orgName</strong> sur Me2Leads a été réactivé par un administrateur.</p>
    <p>Vous pouvez à nouveau accéder aux contacts et fonctionnalités de l'organisation.</p>
    <p style="font-size: 14px; color: #666;">Si vous avez des questions, veuillez contacter l'administrateur de votre organisation.</p>
  </div>
  <div style="margin-top: 30px; font-size: 12px; color: #999; text-align: center;">
    <p>&copy; $year Me2Leads. Tous droits réservés.</p>
  </div>
</div>
''';
    return _sendEmail(
      to: toEmail,
      subject: 'Me2Leads — Votre accès à $orgName a été réactivé',
      body: 'Bonjour $memberName,\n\nVotre accès à l\'organisation "$orgName" a été réactivé par un administrateur.\n\nVous pouvez à nouveau accéder aux contacts et fonctionnalités de l\'organisation.\n\n© $year Me2Leads.',
      htmlBody: htmlBody,
    );
  }

  /// Notifies [toEmail] that they have been promoted to admin in [orgName].
  /// Returns true if SMTP delivery succeeded; callers must not depend on the result.
  static Future<bool> sendAdminPromotedNotification({
    required String toEmail,
    required String orgName,
    required String memberName,
  }) async {
    final year = DateTime.now().year;
    final htmlBody = '''
<div style="font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif; max-width: 600px; margin: 0 auto; padding: 20px; color: #333;">
  <div style="text-align: center; margin-bottom: 30px;">
    <h1 style="color: #0B3C5D; margin: 0;">Me2Leads</h1>
    <p style="color: #666; font-size: 14px;">Votre assistant de prospection intelligent</p>
  </div>
  <div style="background-color: #f9f9f9; border-radius: 8px; padding: 30px; border: 1px solid #eee;">
    <h2 style="margin-top: 0; color: #333; font-size: 20px;">Vous êtes désormais administrateur</h2>
    <p>Bonjour $memberName,</p>
    <p>Vous avez été promu(e) <strong>administrateur</strong> de l'organisation <strong>$orgName</strong> sur Me2Leads.</p>
    <p>En tant qu'administrateur, vous disposez désormais de tous les droits de gestion : création, modification, historique, rappels et export des contacts.</p>
    <p style="font-size: 14px; color: #666;">Si vous avez des questions, veuillez contacter le propriétaire de votre organisation.</p>
  </div>
  <div style="margin-top: 30px; font-size: 12px; color: #999; text-align: center;">
    <p>&copy; $year Me2Leads. Tous droits réservés.</p>
  </div>
</div>
''';
    return _sendEmail(
      to: toEmail,
      subject: 'Me2Leads — Vous êtes désormais administrateur de $orgName',
      body:
          'Bonjour $memberName,\n\nVous avez été promu(e) administrateur de l\'organisation "$orgName" sur Me2Leads.\n\nVous disposez désormais de tous les droits de gestion de l\'organisation.\n\n© $year Me2Leads.',
      htmlBody: htmlBody,
    );
  }

  /// Notifies [toEmail] that their admin role in [orgName] has been revoked.
  /// Returns true if SMTP delivery succeeded; callers must not depend on the result.
  static Future<bool> sendAdminDemotedNotification({
    required String toEmail,
    required String orgName,
    required String memberName,
  }) async {
    final year = DateTime.now().year;
    final htmlBody = '''
<div style="font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif; max-width: 600px; margin: 0 auto; padding: 20px; color: #333;">
  <div style="text-align: center; margin-bottom: 30px;">
    <h1 style="color: #0B3C5D; margin: 0;">Me2Leads</h1>
    <p style="color: #666; font-size: 14px;">Votre assistant de prospection intelligent</p>
  </div>
  <div style="background-color: #f9f9f9; border-radius: 8px; padding: 30px; border: 1px solid #eee;">
    <h2 style="margin-top: 0; color: #333; font-size: 20px;">Votre rôle d'administrateur a été révoqué</h2>
    <p>Bonjour $memberName,</p>
    <p>Votre rôle d'<strong>administrateur</strong> dans l'organisation <strong>$orgName</strong> sur Me2Leads a été révoqué par le propriétaire.</p>
    <p>Vous êtes désormais membre standard et disposez des droits qui vous ont été attribués par l'administration.</p>
    <p style="font-size: 14px; color: #666;">Si vous avez des questions, veuillez contacter le propriétaire de votre organisation.</p>
  </div>
  <div style="margin-top: 30px; font-size: 12px; color: #999; text-align: center;">
    <p>&copy; $year Me2Leads. Tous droits réservés.</p>
  </div>
</div>
''';
    return _sendEmail(
      to: toEmail,
      subject:
          'Me2Leads — Votre rôle d\'administrateur dans $orgName a été révoqué',
      body:
          'Bonjour $memberName,\n\nVotre rôle d\'administrateur dans l\'organisation "$orgName" sur Me2Leads a été révoqué par le propriétaire.\n\nVous êtes désormais membre standard.\n\n© $year Me2Leads.',
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

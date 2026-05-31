import 'package:flutter_test/flutter_test.dart';

import 'package:me2leads/services/email_service.dart';

void main() {
  const email = 'debouana.dev@gmail.com';
  const orgName = 'Me2Leads Test Org';
  const memberName = 'Test Member';
  const ownerName = 'Test Owner';

  group('EmailService – SMTP integration', () {
    test('sends verification email', () async {
      final result = await EmailService.sendVerificationEmail(email, '123456');
      expect(result, isTrue);
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('sends recovery email', () async {
      final result = await EmailService.sendRecoveryEmail(email, '654321');
      expect(result, isTrue);
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('sends ownership transfer notification', () async {
      final result = await EmailService.sendOwnershipTransferNotification(
        toEmail: email,
        orgName: orgName,
        outgoingOwnerName: ownerName,
      );
      expect(result, isTrue);
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('sends member leave notification', () async {
      final result = await EmailService.sendMemberLeaveNotification(
        toEmail: email,
        orgName: orgName,
        memberName: memberName,
      );
      expect(result, isTrue);
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('sends member join notification', () async {
      final result = await EmailService.sendMemberJoinNotification(
        toEmail: email,
        orgName: orgName,
        memberName: memberName,
      );
      expect(result, isTrue);
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('sends member suspended notification', () async {
      final result = await EmailService.sendMemberSuspendedNotification(
        toEmail: email,
        orgName: orgName,
        memberName: memberName,
      );
      expect(result, isTrue);
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('sends member removed notification', () async {
      final result = await EmailService.sendMemberRemovedNotification(
        toEmail: email,
        orgName: orgName,
        memberName: memberName,
      );
      expect(result, isTrue);
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('sends member reactivated notification', () async {
      final result = await EmailService.sendMemberReactivatedNotification(
        toEmail: email,
        orgName: orgName,
        memberName: memberName,
      );
      expect(result, isTrue);
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('sends admin promoted notification', () async {
      final result = await EmailService.sendAdminPromotedNotification(
        toEmail: email,
        orgName: orgName,
        memberName: memberName,
      );
      expect(result, isTrue);
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('sends admin demoted notification', () async {
      final result = await EmailService.sendAdminDemotedNotification(
        toEmail: email,
        orgName: orgName,
        memberName: memberName,
      );
      expect(result, isTrue);
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('sends email change verification email', () async {
      final result =
          await EmailService.sendEmailChangeVerificationEmail(email, '789012');
      expect(result, isTrue);
    }, timeout: const Timeout(Duration(seconds: 30)));
  });
}

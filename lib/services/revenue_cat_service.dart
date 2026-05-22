import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:purchases_flutter/purchases_flutter.dart';
import '../config/app_config.dart';

/// Result of a completed RevenueCat checkout.
class RevenueCatCheckoutResult {
  final bool success;
  final String? customerId;
  final String? errorCode; // 'cancelled' | 'failed' | 'not_found'

  const RevenueCatCheckoutResult({
    required this.success,
    this.customerId,
    this.errorCode,
  });
}

/// Service to handle in-app purchases via RevenueCat (purchases_flutter).
/// Used on iOS for App Store compliance.
class RevenueCatService {
  RevenueCatService._();

  /// Initialize RevenueCat SDK.
  static Future<void> init() async {
    if (!Platform.isIOS) return;

    try {
      await Purchases.setLogLevel(kDebugMode ? LogLevel.debug : LogLevel.error);

      final apiKey = AppConfig.revenueCatApiKey;
      if (apiKey.isEmpty) {
        debugPrint(
            'RevenueCatService: API Key is empty. Skipping initialization.');
        return;
      }

      PurchasesConfiguration configuration = PurchasesConfiguration(apiKey);
      await Purchases.configure(configuration);
      debugPrint('RevenueCatService: Initialized successfully');
    } catch (e) {
      debugPrint('RevenueCatService: Initialization failed: $e');
    }
  }

  /// Performs a purchase for the given plan and billing cycle.
  /// Maps to RevenueCat Package ID: {plan}_{billingCycle} (e.g., premium_monthly).
  static Future<RevenueCatCheckoutResult> purchasePlan(
      String plan, String billingCycle) async {
    try {
      final normalizedCycle =
          billingCycle == 'yearly' ? 'annual' : billingCycle;
      final packageId = '\$rc_$normalizedCycle';
      Offerings offerings = await Purchases.getOfferings();

      Package? package;
      if (offerings.current != null) {
        for (var p in offerings.current!.availablePackages) {
          if (p.identifier == packageId ||
              p.packageType.toString().split('.').last == billingCycle) {
            // Priority to exact match if packageId matches custom identifier
            if (p.identifier == packageId) {
              package = p;
              break;
            }
            package ??= p;
          }
        }
      }
      if (package == null) {
        debugPrint(
            'RevenueCatService: Package $packageId not found in current offering');
        return const RevenueCatCheckoutResult(
            success: false, errorCode: 'not_found');
      }

      PurchaseResult purchaseResult = await Purchases.purchase(
        PurchaseParams.package(package),
      );
      CustomerInfo customerInfo = purchaseResult.customerInfo;

      // Check if the entitlement for the plan is active.
      // Entitlement ID should match the plan name (e.g., 'premium', 'business').
      final entitlement = customerInfo.entitlements.all[plan];
      if (entitlement != null && entitlement.isActive) {
        return RevenueCatCheckoutResult(
          success: true,
          customerId: customerInfo.originalAppUserId,
        );
      }
      return const RevenueCatCheckoutResult(
          success: false, errorCode: 'failed');
    } on PlatformException catch (e) {
      final errorCode = PurchasesErrorHelper.getErrorCode(e);
      if (errorCode == PurchasesErrorCode.purchaseCancelledError) {
        return const RevenueCatCheckoutResult(
            success: false, errorCode: 'cancelled');
      }
      debugPrint('RevenueCatService: Purchase failed: ${e.message}');
      return const RevenueCatCheckoutResult(
          success: false, errorCode: 'failed');
    } catch (e) {
      debugPrint('RevenueCatService: Unexpected error: $e');
      return const RevenueCatCheckoutResult(
          success: false, errorCode: 'failed');
    }
  }

  /// Restores previous purchases.
  static Future<bool> restorePurchases(String plan) async {
    try {
      CustomerInfo customerInfo = await Purchases.restorePurchases();
      return customerInfo.entitlements.all[plan]?.isActive ?? false;
    } catch (e) {
      debugPrint('RevenueCatService: Restore failed: $e');
      return false;
    }
  }

  /// Synchronizes user identity with RevenueCat.
  static Future<void> logIn(String userId) async {
    if (!Platform.isIOS) return;
    try {
      await Purchases.logIn(userId);
    } catch (e) {
      debugPrint('RevenueCatService: LogIn failed: $e');
    }
  }

  /// Logs out the user from RevenueCat.
  static Future<void> logOut() async {
    if (!Platform.isIOS) return;
    try {
      await Purchases.logOut();
    } catch (e) {
      debugPrint('RevenueCatService: LogOut failed: $e');
    }
  }
}

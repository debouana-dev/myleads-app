import 'package:flutter/foundation.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_stripe/flutter_stripe.dart';

import 'notification_service.dart';

const _kPiKey = 'stripe_pending_pi_id';
const _kPlanKey = 'stripe_pending_plan';
const _kCycleKey = 'stripe_pending_cycle';
const _kSecretKey = 'stripe_pending_client_secret';

// Price map (EUR cents) — matches the Firebase Cloud Function.
const _monthlyPrices = {'premium': 359, 'business': 719};
const _yearlyPrices = {'premium': 3588, 'business': 7188};

/// Result of a completed Stripe checkout.
class PaymentCheckoutResult {
  final bool success;
  final String? paymentIntentId;
  final String?
      errorCode; // 'cancelled' | 'failed' | 'network_error' | 'invalid_plan'
  final String paymentMethod; // 'card' | 'link' | 'amazon_pay' | 'unknown'

  const PaymentCheckoutResult({
    required this.success,
    this.paymentIntentId,
    this.errorCode,
    this.paymentMethod = 'card',
  });
}

/// Carries a recovered pending payment's plan details alongside its result.
/// Returned by [StripeService.checkPendingPayment] when a previously started
/// payment is found in secure storage (e.g. after a Link browser flow).
class PendingPaymentRecovery {
  final PaymentCheckoutResult result;
  final String plan;
  final String billingCycle;

  const PendingPaymentRecovery({
    required this.result,
    required this.plan,
    required this.billingCycle,
  });
}

/// Wraps the Stripe PaymentSheet flow via Firebase Cloud Functions.
///
/// The Stripe secret key never leaves the server — only the publishable key
/// is in the app. The Cloud Function `createPaymentIntent` creates the
/// Payment Intent server-side and returns only the client secret.
///
/// Deploy the Cloud Function from the `functions/` directory before use.
class StripeService {
  StripeService._();

  static const _storage = FlutterSecureStorage();

  static FirebaseFunctions get _functions =>
      FirebaseFunctions.instanceFor(region: 'europe-west1');

  // Cached recovery result from the startup check in main.dart.
  // Consumed exactly once by SubscriptionPlanScreen on initState.
  static PendingPaymentRecovery? _startupRecovery;

  static Future<void> _savePending(
    String piId,
    String plan,
    String billingCycle,
    String clientSecret,
  ) async {
    await _storage.write(key: _kPiKey, value: piId);
    await _storage.write(key: _kPlanKey, value: plan);
    await _storage.write(key: _kCycleKey, value: billingCycle);
    await _storage.write(key: _kSecretKey, value: clientSecret);
  }

  static Future<void> _clearPending() async {
    await _storage.delete(key: _kPiKey);
    await _storage.delete(key: _kPlanKey);
    await _storage.delete(key: _kCycleKey);
    await _storage.delete(key: _kSecretKey);
  }

  /// Called once from [main] right after [Stripe.instance.applySettings].
  ///
  /// Checks SecureStorage for a pending payment and caches the result in
  /// [_startupRecovery]. This covers the cold-start scenario where the OS
  /// killed the app process while the user was completing payment in an
  /// external browser: the fresh process starts, runs this check, and
  /// [consumeStartupRecovery] delivers the result to [SubscriptionPlanScreen]
  /// without requiring [didChangeAppLifecycleState] to fire.
  static Future<void> checkAtStartup() async {
    try {
      _startupRecovery = await checkPendingPayment();
    } catch (e) {
      debugPrint('StripeService.checkAtStartup: $e');
    }
  }

  /// Returns the cached startup-recovery result WITHOUT clearing it.
  /// Used by [main] to apply the plan to the DB before the widget tree builds.
  /// [consumeStartupRecovery] should still be called by [SubscriptionPlanScreen]
  /// for the snackbar and any remaining Riverpod state update.
  static PendingPaymentRecovery? peekStartupRecovery() => _startupRecovery;

  /// Returns the cached startup-recovery result and clears it so it is only
  /// consumed once (by [SubscriptionPlanScreen.initState]).
  static PendingPaymentRecovery? consumeStartupRecovery() {
    final r = _startupRecovery;
    _startupRecovery = null;
    return r;
  }

  /// Checks whether a Stripe payment completed while the app was in the
  /// background — for example, the user paid via Stripe Link in an external
  /// browser and Android paused or killed the process before the deep link
  /// returned.
  ///
  /// **Primary path** — `Stripe.instance.retrievePaymentIntent(clientSecret)`:
  /// uses the publishable key already in the app to query Stripe directly. No
  /// Cloud Function deployment is required for this path.
  ///
  /// **Fallback path** — `getPaymentStatus` Cloud Function: used when the
  /// client-side call throws (e.g. Stripe SDK not yet initialised on cold start).
  ///
  /// Returns `null` when there is no pending payment or all status checks fail
  /// (transient error — the record is kept for the next resume).
  /// Clears the pending record on any definitive Stripe status.
  static Future<PendingPaymentRecovery?> checkPendingPayment() async {
    final piId = await _storage.read(key: _kPiKey);
    if (piId == null) return null;

    final plan = await _storage.read(key: _kPlanKey) ?? '';
    final billingCycle = await _storage.read(key: _kCycleKey) ?? '';
    final clientSecret = await _storage.read(key: _kSecretKey) ?? '';

    // ── Primary: client-side retrievePaymentIntent ──────────────────────────
    if (clientSecret.isNotEmpty) {
      try {
        final pi = await Stripe.instance
            .retrievePaymentIntent(clientSecret)
            .timeout(const Duration(seconds: 10));

        await _clearPending();

        if (pi.status == PaymentIntentsStatus.Succeeded) {
          debugPrint(
            'StripeService: recovery — payment succeeded (client check)',
          );
          return PendingPaymentRecovery(
            result: PaymentCheckoutResult(
              success: true,
              paymentIntentId: piId,
            ),
            plan: plan,
            billingCycle: billingCycle,
          );
        }
        debugPrint(
          'StripeService: recovery — payment not succeeded: ${pi.status}',
        );
        return PendingPaymentRecovery(
          result: const PaymentCheckoutResult(
            success: false,
            errorCode: 'failed',
          ),
          plan: plan,
          billingCycle: billingCycle,
        );
      } catch (e) {
        // SDK not ready (cold start before Stripe.applySettings) or network
        // error — fall through to the Cloud Function fallback.
        debugPrint(
          'StripeService: client-side check failed ($e) — trying CF fallback',
        );
      }
    }

    // ── Fallback: getPaymentStatus Cloud Function ───────────────────────────
    try {
      final callable = _functions.httpsCallable('getPaymentStatus');
      final response = await callable
          .call(<String, dynamic>{'paymentIntentId': piId}).timeout(
              const Duration(seconds: 10));
      final status =
          (response.data as Map<String, dynamic>)['status'] as String;

      await _clearPending();

      if (status == 'succeeded') {
        debugPrint('StripeService: recovery — payment succeeded (CF check)');
        return PendingPaymentRecovery(
          result: PaymentCheckoutResult(success: true, paymentIntentId: piId),
          plan: plan,
          billingCycle: billingCycle,
        );
      }
      debugPrint('StripeService: recovery — CF status: $status');
      return PendingPaymentRecovery(
        result: const PaymentCheckoutResult(
          success: false,
          errorCode: 'failed',
        ),
        plan: plan,
        billingCycle: billingCycle,
      );
    } catch (_) {
      // Both checks failed — leave the record so the next resume retries.
      debugPrint(
        'StripeService: recovery — both checks failed, keeping pending record',
      );
      return null;
    }
  }

  static Future<PaymentCheckoutResult> startCheckout({
    required String plan,
    required String billingCycle,
    required String userEmail,
    int licenseCount = 1,
    double? amount,
  }) async {
    final unitAmount = billingCycle == 'yearly'
        ? (_yearlyPrices[plan] ?? 0)
        : (_monthlyPrices[plan] ?? 0);
    final rentAmount = amount ?? unitAmount * licenseCount;

    if (rentAmount == 0) {
      return const PaymentCheckoutResult(
        success: false,
        errorCode: 'invalid_plan',
      );
    }

    String? paymentIntentId;
    String? clientSecret;

    try {
      // 1. Call Firebase Cloud Function to create a Payment Intent.
      final callable = _functions.httpsCallable('createPaymentIntent');
      final result = await callable.call(<String, dynamic>{
        'plan': plan,
        'billingCycle': billingCycle,
        'amount': rentAmount,
        'currency': 'eur',
        'licenseCount': licenseCount,
      });
      final data = result.data as Map<String, dynamic>;
      clientSecret = data['clientSecret'] as String;
      paymentIntentId = data['paymentIntentId'] as String?;

      // 2. Persist the pending payment BEFORE presenting the sheet so that a
      //    process kill during a Link/Amazon Pay browser flow can be recovered
      //    on the next startup via checkAtStartup() → retrievePaymentIntent().
      if (paymentIntentId != null) {
        await _savePending(paymentIntentId, plan, billingCycle, clientSecret);
      }

      // 3. Initialize the PaymentSheet.
      await Stripe.instance.initPaymentSheet(
        paymentSheetParameters: SetupPaymentSheetParameters(
          paymentIntentClientSecret: clientSecret,
          merchantDisplayName: 'Me2Leads',
          billingDetails: BillingDetails(email: userEmail),
          style: ThemeMode.system,
          appearance: const PaymentSheetAppearance(
            colors: PaymentSheetAppearanceColors(primary: Color(0xFF0B3C5D)),
          ),
          googlePay: const PaymentSheetGooglePay(
            merchantCountryCode: 'FR',
            currencyCode: 'EUR',
            testEnv: kDebugMode,
          ),
          /*applePay: PaymentSheetApplePay(
            merchantCountryCode: 'FR',
            //merchantIdentifier: 'merchant.com.debouana.myleads',
          ),*/
          // Required for redirect-based methods (Link, Amazon Pay, bank
          // redirects). Android declares this scheme in the intent-filter
          // so the deep link routes back to MainActivity.
          returnURL: 'me2leads://stripe-redirect',
        ),
      );

      // 4. Show a persistent notification BEFORE presenting the sheet.
      //    While a Chrome Custom Tab is in the foreground, Android may
      //    consider this process lower priority and kill it. Keeping a
      //    visible notification raises the process priority in the LMK
      //    table, significantly reducing the chance of being killed.
      await NotificationService.showPaymentProgressNotification();

      // 5. Present the PaymentSheet.
      await Stripe.instance.presentPaymentSheet();

      // 6. Sheet completed normally (card payment or redirect return).
      await NotificationService.dismissPaymentProgressNotification();
      await _clearPending();
      return PaymentCheckoutResult(
        success: true,
        paymentIntentId: paymentIntentId,
      );
    } on StripeException catch (e) {
      await NotificationService.dismissPaymentProgressNotification();

      if (e.error.code == FailureCode.Canceled && paymentIntentId != null) {
        // The PaymentSheet was dismissed. For Link/Amazon Pay redirect flows
        // this fires while the payment is still being processed in the
        // external browser — the final status is NOT yet known. We must NOT
        // query Stripe here: the PI status may still be "processing" or
        // "requires_action", and clearing the pending record at this point
        // would prevent recovery when the user returns.
        //
        // Instead, preserve the pending record. WidgetsBindingObserver in
        // SubscriptionPlanScreen will call checkPendingPayment() once the
        // app resumes, at which point Stripe has a definitive answer. For
        // genuine cancellations (user pressed back without paying),
        // retrievePaymentIntent() will return requires_payment_method and
        // _clearPending() will be called by the recovery path.
        debugPrint(
          'StripeService: PaymentSheet dismissed — pending record kept for resume check',
        );
        return const PaymentCheckoutResult(
          success: false,
          errorCode: 'cancelled',
        );
      }

      final code =
          e.error.code == FailureCode.Canceled ? 'cancelled' : 'failed';
      debugPrint('StripeService: payment $code — ${e.error.message}');
      await _clearPending();
      return PaymentCheckoutResult(success: false, errorCode: code);
    } on FirebaseFunctionsException catch (e) {
      await NotificationService.dismissPaymentProgressNotification();
      debugPrint(
        'StripeService: Cloud Function error [${e.code}]: ${e.message}',
      );
      await _clearPending();
      return const PaymentCheckoutResult(
        success: false,
        errorCode: 'network_error',
      );
    } catch (e) {
      await NotificationService.dismissPaymentProgressNotification();
      debugPrint('StripeService: unexpected error: $e');
      await _clearPending();
      return const PaymentCheckoutResult(
        success: false,
        errorCode: 'network_error',
      );
    }
  }
}

import 'package:firebase_app_check/firebase_app_check.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_stripe/flutter_stripe.dart';
import 'package:uuid/uuid.dart';

import 'config/app_config.dart';
import 'core/theme/app_theme.dart';
import 'core/router/app_router.dart';
import 'firebase_options.dart';
import 'models/user_account.dart';
import 'providers/settings_provider.dart';
import 'services/action_tracker.dart';
import 'services/background_task.dart';
import 'services/database_service.dart';
import 'services/notification_service.dart';
import 'services/remote_sync_service.dart';
import 'services/storage_service.dart';
import 'services/stripe_service.dart';

const _uuid = Uuid();

// Price map duplicated from StripeService so main() can compute the amount
// without depending on the screen layer.
const _coldStartPrices = {
  'premium_monthly': 3.59,
  'premium_yearly': 35.88,
  'business_monthly': 7.19,
  'business_yearly': 71.88,
};

/// Activates a plan that was paid while the process was killed during a
/// Link / Amazon Pay redirect.  Runs after [StorageService.init] so the
/// DB is open; runs before [runApp] so [AuthNotifier] reads the correct
/// plan on first construction.
Future<void> _applyStartupPaymentRecovery() async {
  final recovery = StripeService.peekStartupRecovery();
  if (recovery == null || !recovery.result.success) return;

  final user = StorageService.currentUser;
  if (user == null) return; // no session yet — nothing to update

  // Update plan in the local DB and session so AuthNotifier starts correctly.
  if (user.plan != recovery.plan) {
    final updated = user.copyWith(plan: recovery.plan);
    await DatabaseService.updateUser(updated);
    await StorageService.setCurrentSession(updated, user.sessionToken ?? '');
    debugPrint(
      '_applyStartupPaymentRecovery: plan updated to ${recovery.plan}',
    );
  }

  // Insert the payment record. ConflictAlgorithm.ignore in insertPaymentRecord
  // makes this safe to call even if SubscriptionPlanScreen later tries to
  // insert the same record (identified by the payment intent ID as primary key).
  final piId = recovery.result.paymentIntentId ?? '';
  final key = '${recovery.plan}_${recovery.billingCycle}';
  final amount = _coldStartPrices[key] ?? 0.0;
  if (amount > 0) {
    await DatabaseService.insertPaymentRecord(PaymentRecord(
      id: piId.isNotEmpty ? piId : _uuid.v4(),
      userId: user.id,
      plan: recovery.plan,
      billingCycle: recovery.billingCycle,
      amount: amount,
      currency: 'EUR',
      status: 'succeeded',
      stripePaymentIntentId: piId,
      createdAt: DateTime.now().toIso8601String(),
    ));
  }
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  try {
    await Firebase.initializeApp(
      options: DefaultFirebaseOptions.currentPlatform,
    );
    await FirebaseAppCheck.instance.activate(
      androidProvider: AndroidProvider.debug,
      appleProvider: AppleProvider.debug,
    );
  } catch (e, st) {
    debugPrint('Firebase.initializeApp failed: $e\n$st');
  }

  final stripeKey = AppConfig.stripePublishableKey;
  if (stripeKey.isNotEmpty) {
    try {
      Stripe.publishableKey = stripeKey;
      await Stripe.instance.applySettings().timeout(const Duration(seconds: 5));
      // Check for a payment that completed while the app was killed during a
      // Link / Amazon Pay redirect. The result is cached in StripeService and
      // consumed by SubscriptionPlanScreen.initState() via consumeStartupRecovery().
      await StripeService.checkAtStartup();
    } catch (e, st) {
      debugPrint('Stripe.applySettings failed: $e\n$st');
    }
  }

  // Attach the app-lifecycle observer used to infer completed
  // call/SMS/WhatsApp/email actions when the user comes back after
  // leaving the app for ≥10 s (doc v7).
  ActionTracker.init();

  // System chrome calls are no-ops on web; safe to call unconditionally.
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.light,
    systemNavigationBarColor: Colors.white,
    systemNavigationBarIconBrightness: Brightness.dark,
  ));

  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ]);

  // Initialize encrypted SQLite storage and restore session if any.
  // Wrapped in a guard so the app still boots if a platform-specific
  // backend (e.g. browser IndexedDB) fails — we'd rather show the UI
  // in a degraded state than a permanently white page.
  try {
    await StorageService.init();
    RemoteSyncService.wireDatabase();
    RemoteSyncService.startUserSync();
    // If a payment completed while the process was killed during a redirect
    // (Link / Amazon Pay), apply the plan to the local DB NOW — before
    // runApp() — so AuthNotifier initialises with the correct plan and every
    // screen shows the right plan badge on first render.
    await _applyStartupPaymentRecovery();
  } catch (e, st) {
    debugPrint('StorageService.init failed: $e\n$st');
  }

  try {
    await NotificationService.init();
  } catch (e, st) {
    debugPrint('NotificationService.init failed: $e\n$st');
  }

  try {
    await initBackgroundTasks();
  } catch (e, st) {
    debugPrint('initBackgroundTasks failed: $e\n$st');
  }

  runApp(const ProviderScope(child: Me2LeadsApp()));
}

class Me2LeadsApp extends ConsumerWidget {
  const Me2LeadsApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider);
    return MaterialApp.router(
      title: 'Me2Leads',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light,
      darkTheme: AppTheme.dark,
      themeMode: settings.themeMode,
      routerConfig: appRouter,
    );
  }
}

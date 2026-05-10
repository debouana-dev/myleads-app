import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'core/theme/app_theme.dart';
import 'core/router/app_router.dart';
import 'firebase_options.dart';
import 'providers/settings_provider.dart';
import 'services/action_tracker.dart';
import 'services/background_task.dart';
import 'services/notification_service.dart';
import 'services/remote_sync_service.dart';
import 'services/storage_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );
  await dotenv.load(fileName: '.env');

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

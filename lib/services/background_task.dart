import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:timezone/data/latest_all.dart' as tz;
import 'package:workmanager/workmanager.dart';

import 'database_service.dart';
import 'notification_service.dart';
import 'remote_sync_service.dart';
import 'storage_service.dart';

const _kPeriodicTaskName    = 'myleads_notification_check';
const _kBusinessSyncTaskName = 'myleads_business_sync';

/// Entry point called by WorkManager in a background isolate.
/// Must be a top-level function annotated with @pragma('vm:entry-point').
@pragma('vm:entry-point')
void callbackDispatcher() {
  Workmanager().executeTask((task, _) async {
    try {
      WidgetsFlutterBinding.ensureInitialized();
      tz.initializeTimeZones();

      await StorageService.init();

      final ownerId = StorageService.currentUserId;
      if (ownerId.isEmpty) return true;

      if (task == _kBusinessSyncTaskName) {
        // Belt-and-suspenders plan check — skip silently if plan was downgraded.
        if (StorageService.userPlan != 'business') return true;
        await RemoteSyncService.push(ownerId);
        await RemoteSyncService.pull(ownerId);
        return true;
      }

      final reminders = await DatabaseService.getAllRemindersForOwner(ownerId);
      final contacts  = await DatabaseService.getAllContactsForOwner(ownerId);

      await NotificationService.runPeriodicCheck(
        reminders: reminders,
        contacts: contacts,
      );
      return true;
    } catch (_) {
      return false;
    }
  });
}

/// Registers WorkManager and the periodic notification-check task.
/// Only runs on Android — iOS background refresh is OS-controlled.
Future<void> initBackgroundTasks() async {
  if (kIsWeb || !Platform.isAndroid) return;
  try {
    await Workmanager().initialize(callbackDispatcher, isInDebugMode: false);
    await Workmanager().registerPeriodicTask(
      _kPeriodicTaskName,
      _kPeriodicTaskName,
      frequency: const Duration(hours: 1),
      existingWorkPolicy: ExistingPeriodicWorkPolicy.keep,
      constraints: Constraints(networkType: NetworkType.notRequired),
    );
    if (StorageService.userPlan == 'business') {
      await scheduleBusinessSync();
    }
  } catch (_) {}
}

/// Schedules the periodic Business-plan background sync task.
/// Safe to call multiple times — `replace` policy re-registers without
/// creating duplicates. The task only executes when the device has an
/// active internet connection (enforced by WorkManager constraints).
Future<void> scheduleBusinessSync() async {
  if (kIsWeb || !Platform.isAndroid) return;
  try {
    await Workmanager().registerPeriodicTask(
      _kBusinessSyncTaskName,
      _kBusinessSyncTaskName,
      frequency: const Duration(minutes: 15),
      existingWorkPolicy: ExistingPeriodicWorkPolicy.replace,
      constraints: Constraints(networkType: NetworkType.connected),
    );
  } catch (_) {}
}

/// Cancels the periodic Business-plan background sync task.
/// Called on logout or when the user's plan is downgraded from Business.
Future<void> cancelBusinessSync() async {
  if (kIsWeb || !Platform.isAndroid) return;
  try {
    await Workmanager().cancelByUniqueName(_kBusinessSyncTaskName);
  } catch (_) {}
}

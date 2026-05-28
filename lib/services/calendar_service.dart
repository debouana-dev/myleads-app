import 'package:add_2_calendar/add_2_calendar.dart';
import '../models/app_task.dart';
import '../models/reminder.dart';

/// Adds a [Reminder] or [AppTask] to the device's native calendar app.
class CalendarService {
  CalendarService._();

  static Future<void> addReminderToCalendar(Reminder reminder) async {
    final event = Event(
      title: reminder.note,
      description: reminder.note,
      location: '',
      startDate: reminder.startDateTime,
      endDate: reminder.endDateTime ?? reminder.startDateTime.add(const Duration(hours: 1)),
      allDay: false,
      iosParams: const IOSParams(reminder: Duration(minutes: 15)),
      androidParams: const AndroidParams(emailInvites: []),
    );
    Add2Calendar.addEvent2Cal(event);
  }

  static Future<void> addTaskToCalendar(AppTask task) async {
    final event = Event(
      title: task.note,
      description: task.note,
      location: '',
      startDate: task.startDateTime,
      endDate: task.endDateTime ?? task.startDateTime.add(const Duration(hours: 1)),
      allDay: false,
      iosParams: const IOSParams(reminder: Duration(minutes: 15)),
      androidParams: const AndroidParams(emailInvites: []),
    );
    Add2Calendar.addEvent2Cal(event);
  }
}

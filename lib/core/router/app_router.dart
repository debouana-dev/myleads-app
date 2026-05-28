import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../../screens/splash/splash_screen.dart';
import '../../screens/auth/login_screen.dart';
import '../../screens/auth/signup_screen.dart';
import '../../screens/auth/forgot_password_screen.dart';
import '../../screens/auth/email_verification_screen.dart';
import '../../screens/auth/recovery_code_screen.dart';
import '../../screens/auth/reset_password_screen.dart';
import '../../screens/home/main_shell.dart';
import '../../screens/review/review_screen.dart';
import '../../screens/contacts/contact_detail_screen.dart';
import '../../screens/contacts/contact_edit_screen.dart';
import '../../screens/contacts/contact_history_screen.dart';
import '../../screens/contacts/contact_reminders_screen.dart';
import '../../screens/pricing/pricing_screen.dart';
import '../../screens/scan/scan_screen.dart';
import '../../screens/profile/my_profile_screen.dart';
import '../../screens/profile/account_security_screen.dart';
import '../../screens/reminders/create_reminder_screen.dart';
import '../../screens/reminders/reminder_detail_screen.dart';
import '../../screens/notifications/notifications_screen.dart';
import '../../screens/settings/settings_screen.dart';
import '../../screens/pricing/subscription_plan_screen.dart';
import '../../screens/pricing/payment_history_screen.dart';
import '../../screens/pricing/transaction_detail_screen.dart';
import '../../models/user_account.dart';
import '../../screens/organization/create_organization_screen.dart';
import '../../screens/organization/join_organization_screen.dart';
import '../../screens/organization/organization_admin_screen.dart';
import '../../screens/profile/import_export_screen.dart';
import '../../screens/profile/sync_screen.dart';
import '../../screens/tasks/tasks_screen.dart';
import '../../screens/tasks/create_task_screen.dart';
import '../../screens/tasks/task_detail_screen.dart';
import '../../models/app_task.dart';

final appRouter = GoRouter(
  initialLocation: '/',
  routes: [
    GoRoute(
      path: '/',
      builder: (context, state) => const SplashScreen(),
    ),
    GoRoute(
      path: '/login',
      pageBuilder: (context, state) => CustomTransitionPage(
        key: state.pageKey,
        child: const LoginScreen(),
        transitionsBuilder: (context, animation, secondaryAnimation, child) {
          return FadeTransition(opacity: animation, child: child);
        },
      ),
    ),
    GoRoute(
      path: '/signup',
      pageBuilder: (context, state) => CustomTransitionPage(
        key: state.pageKey,
        child: const SignupScreen(),
        transitionsBuilder: (context, animation, secondaryAnimation, child) {
          const begin = Offset(1.0, 0.0);
          const end = Offset.zero;
          final tween = Tween(begin: begin, end: end)
              .chain(CurveTween(curve: Curves.easeInOut));
          return SlideTransition(
            position: animation.drive(tween),
            child: child,
          );
        },
      ),
    ),
    GoRoute(
      path: '/forgot-password',
      pageBuilder: (context, state) => CustomTransitionPage(
        key: state.pageKey,
        child: const ForgotPasswordScreen(),
        transitionsBuilder: (context, animation, secondaryAnimation, child) {
          const begin = Offset(1.0, 0.0);
          const end = Offset.zero;
          final tween = Tween(begin: begin, end: end)
              .chain(CurveTween(curve: Curves.easeInOut));
          return SlideTransition(
            position: animation.drive(tween),
            child: child,
          );
        },
      ),
    ),
    GoRoute(
      path: '/email-verification',
      pageBuilder: (context, state) {
        final email = state.extra as String? ?? '';
        return CustomTransitionPage(
          key: state.pageKey,
          child: EmailVerificationScreen(email: email),
          transitionsBuilder: (context, animation, secondaryAnimation, child) {
            const begin = Offset(1.0, 0.0);
            const end = Offset.zero;
            final tween = Tween(begin: begin, end: end)
                .chain(CurveTween(curve: Curves.easeInOut));
            return SlideTransition(
              position: animation.drive(tween),
              child: child,
            );
          },
        );
      },
    ),
    GoRoute(
      path: '/recovery-code',
      pageBuilder: (context, state) {
        final email = state.extra as String? ?? '';
        return CustomTransitionPage(
          key: state.pageKey,
          child: RecoveryCodeScreen(email: email),
          transitionsBuilder: (context, animation, secondaryAnimation, child) {
            const begin = Offset(1.0, 0.0);
            const end = Offset.zero;
            final tween = Tween(begin: begin, end: end)
                .chain(CurveTween(curve: Curves.easeInOut));
            return SlideTransition(
              position: animation.drive(tween),
              child: child,
            );
          },
        );
      },
    ),
    GoRoute(
      path: '/reset-password',
      pageBuilder: (context, state) {
        final extra = state.extra as Map<String, dynamic>? ?? {};
        final email = extra['email'] as String? ?? '';
        final code = extra['code'] as String? ?? '';
        return CustomTransitionPage(
          key: state.pageKey,
          child: ResetPasswordScreen(email: email, code: code),
          transitionsBuilder: (context, animation, secondaryAnimation, child) {
            const begin = Offset(1.0, 0.0);
            const end = Offset.zero;
            final tween = Tween(begin: begin, end: end)
                .chain(CurveTween(curve: Curves.easeInOut));
            return SlideTransition(
              position: animation.drive(tween),
              child: child,
            );
          },
        );
      },
    ),
    GoRoute(
      path: '/main',
      pageBuilder: (context, state) => CustomTransitionPage(
        key: state.pageKey,
        child: const MainShell(),
        transitionsBuilder: (context, animation, secondaryAnimation, child) {
          return FadeTransition(opacity: animation, child: child);
        },
      ),
    ),
    GoRoute(
      path: '/scan',
      pageBuilder: (context, state) => CustomTransitionPage(
        key: state.pageKey,
        child: const ScanScreen(),
        transitionsBuilder: (context, animation, secondaryAnimation, child) {
          return FadeTransition(opacity: animation, child: child);
        },
      ),
    ),
    GoRoute(
      path: '/review',
      pageBuilder: (context, state) {
        final ocrData = state.extra as Map<String, String>? ?? const {};
        return CustomTransitionPage(
        key: state.pageKey,
        child: ReviewScreen(ocrData: ocrData),
        transitionsBuilder: (context, animation, secondaryAnimation, child) {
          const begin = Offset(1.0, 0.0);
          const end = Offset.zero;
          final tween = Tween(begin: begin, end: end)
              .chain(CurveTween(curve: Curves.easeInOut));
          return SlideTransition(
            position: animation.drive(tween),
            child: child,
          );
        },
      );
      },
    ),
    GoRoute(
      path: '/contact/new',
      pageBuilder: (context, state) => CustomTransitionPage(
        key: state.pageKey,
        child: const ContactEditScreen(),
        transitionsBuilder: (context, animation, secondaryAnimation, child) {
          const begin = Offset(1.0, 0.0);
          const end = Offset.zero;
          final tween = Tween(begin: begin, end: end)
              .chain(CurveTween(curve: Curves.easeInOut));
          return SlideTransition(
            position: animation.drive(tween),
            child: child,
          );
        },
      ),
    ),
    GoRoute(
      path: '/contact/:id',
      pageBuilder: (context, state) {
        final contactId = state.pathParameters['id']!;
        return CustomTransitionPage(
          key: state.pageKey,
          child: ContactDetailScreen(contactId: contactId),
          transitionsBuilder: (context, animation, secondaryAnimation, child) {
            const begin = Offset(1.0, 0.0);
            const end = Offset.zero;
            final tween = Tween(begin: begin, end: end)
                .chain(CurveTween(curve: Curves.easeInOut));
            return SlideTransition(
              position: animation.drive(tween),
              child: child,
            );
          },
        );
      },
    ),
    GoRoute(
      path: '/contact/:id/edit',
      pageBuilder: (context, state) {
        final contactId = state.pathParameters['id']!;
        return CustomTransitionPage(
          key: state.pageKey,
          child: ContactEditScreen(contactId: contactId),
          transitionsBuilder: (context, animation, secondaryAnimation, child) {
            const begin = Offset(1.0, 0.0);
            const end = Offset.zero;
            final tween = Tween(begin: begin, end: end)
                .chain(CurveTween(curve: Curves.easeInOut));
            return SlideTransition(
              position: animation.drive(tween),
              child: child,
            );
          },
        );
      },
    ),
    GoRoute(
      path: '/contact/:id/history',
      pageBuilder: (context, state) {
        final contactId = state.pathParameters['id']!;
        return CustomTransitionPage(
          key: state.pageKey,
          child: ContactHistoryScreen(contactId: contactId),
          transitionsBuilder: (context, animation, secondaryAnimation, child) {
            const begin = Offset(1.0, 0.0);
            const end = Offset.zero;
            final tween = Tween(begin: begin, end: end)
                .chain(CurveTween(curve: Curves.easeInOut));
            return SlideTransition(
              position: animation.drive(tween),
              child: child,
            );
          },
        );
      },
    ),
    GoRoute(
      path: '/contact/:id/reminders',
      pageBuilder: (context, state) {
        final contactId = state.pathParameters['id']!;
        return CustomTransitionPage(
          key: state.pageKey,
          child: ContactRemindersScreen(contactId: contactId),
          transitionsBuilder: (context, animation, secondaryAnimation, child) {
            const begin = Offset(1.0, 0.0);
            const end = Offset.zero;
            final tween = Tween(begin: begin, end: end)
                .chain(CurveTween(curve: Curves.easeInOut));
            return SlideTransition(
              position: animation.drive(tween),
              child: child,
            );
          },
        );
      },
    ),
    GoRoute(
      path: '/pricing',
      pageBuilder: (context, state) => CustomTransitionPage(
        key: state.pageKey,
        child: const PricingScreen(),
        transitionsBuilder: (context, animation, secondaryAnimation, child) {
          const begin = Offset(0.0, 1.0);
          const end = Offset.zero;
          final tween = Tween(begin: begin, end: end)
              .chain(CurveTween(curve: Curves.easeInOut));
          return SlideTransition(
            position: animation.drive(tween),
            child: child,
          );
        },
      ),
    ),
    GoRoute(
      path: '/my-profile',
      pageBuilder: (context, state) => CustomTransitionPage(
        key: state.pageKey,
        child: const MyProfileScreen(),
        transitionsBuilder: (context, animation, secondaryAnimation, child) {
          const begin = Offset(1.0, 0.0);
          const end = Offset.zero;
          final tween = Tween(begin: begin, end: end)
              .chain(CurveTween(curve: Curves.easeInOut));
          return SlideTransition(
            position: animation.drive(tween),
            child: child,
          );
        },
      ),
    ),
    GoRoute(
      path: '/account-security',
      pageBuilder: (context, state) => CustomTransitionPage(
        key: state.pageKey,
        child: const AccountSecurityScreen(),
        transitionsBuilder: (context, animation, secondaryAnimation, child) {
          const begin = Offset(1.0, 0.0);
          const end = Offset.zero;
          final tween = Tween(begin: begin, end: end)
              .chain(CurveTween(curve: Curves.easeInOut));
          return SlideTransition(
            position: animation.drive(tween),
            child: child,
          );
        },
      ),
    ),
    GoRoute(
      path: '/reminder/new',
      pageBuilder: (context, state) => CustomTransitionPage(
        key: state.pageKey,
        child: const CreateReminderScreen(),
        transitionsBuilder: (context, animation, secondaryAnimation, child) {
          const begin = Offset(1.0, 0.0);
          const end = Offset.zero;
          final tween = Tween(begin: begin, end: end).chain(CurveTween(curve: Curves.easeInOut));
          return SlideTransition(position: animation.drive(tween), child: child);
        },
      ),
    ),
    GoRoute(
      path: '/notifications',
      pageBuilder: (context, state) => CustomTransitionPage(
        key: state.pageKey,
        child: const NotificationsScreen(),
        transitionsBuilder: (context, animation, secondaryAnimation, child) {
          const begin = Offset(1.0, 0.0);
          const end = Offset.zero;
          final tween = Tween(begin: begin, end: end).chain(CurveTween(curve: Curves.easeInOut));
          return SlideTransition(position: animation.drive(tween), child: child);
        },
      ),
    ),
    GoRoute(
      path: '/settings',
      pageBuilder: (context, state) => CustomTransitionPage(
        key: state.pageKey,
        child: const SettingsScreen(),
        transitionsBuilder: (context, animation, secondaryAnimation, child) {
          const begin = Offset(1.0, 0.0);
          const end = Offset.zero;
          final tween = Tween(begin: begin, end: end)
              .chain(CurveTween(curve: Curves.easeInOut));
          return SlideTransition(position: animation.drive(tween), child: child);
        },
      ),
    ),
    GoRoute(
      path: '/subscription-plan',
      pageBuilder: (context, state) => CustomTransitionPage(
        key: state.pageKey,
        child: const SubscriptionPlanScreen(),
        transitionsBuilder: (context, animation, secondaryAnimation, child) {
          const begin = Offset(1.0, 0.0);
          const end = Offset.zero;
          final tween = Tween(begin: begin, end: end)
              .chain(CurveTween(curve: Curves.easeInOut));
          return SlideTransition(position: animation.drive(tween), child: child);
        },
      ),
    ),
    GoRoute(
      path: '/payment-history',
      pageBuilder: (context, state) => CustomTransitionPage(
        key: state.pageKey,
        child: const PaymentHistoryScreen(),
        transitionsBuilder: (context, animation, secondaryAnimation, child) {
          const begin = Offset(1.0, 0.0);
          const end = Offset.zero;
          final tween = Tween(begin: begin, end: end)
              .chain(CurveTween(curve: Curves.easeInOut));
          return SlideTransition(position: animation.drive(tween), child: child);
        },
      ),
    ),
    GoRoute(
      path: '/transaction-details',
      pageBuilder: (context, state) {
        final record = state.extra as PaymentRecord;
        return CustomTransitionPage(
          key: state.pageKey,
          child: TransactionDetailScreen(record: record),
          transitionsBuilder: (context, animation, secondaryAnimation, child) {
            const begin = Offset(1.0, 0.0);
            const end = Offset.zero;
            final tween = Tween(begin: begin, end: end)
                .chain(CurveTween(curve: Curves.easeInOut));
            return SlideTransition(
                position: animation.drive(tween), child: child);
          },
        );
      },
    ),
    GoRoute(
      path: '/organization',
      pageBuilder: (context, state) => CustomTransitionPage(
        key: state.pageKey,
        child: const OrganizationAdminScreen(),
        transitionsBuilder: (context, animation, secondaryAnimation, child) {
          const begin = Offset(1.0, 0.0);
          const end = Offset.zero;
          final tween = Tween(begin: begin, end: end)
              .chain(CurveTween(curve: Curves.easeInOut));
          return SlideTransition(position: animation.drive(tween), child: child);
        },
      ),
    ),
    GoRoute(
      path: '/organization/create',
      pageBuilder: (context, state) => CustomTransitionPage(
        key: state.pageKey,
        child: const CreateOrganizationScreen(),
        transitionsBuilder: (context, animation, secondaryAnimation, child) {
          const begin = Offset(1.0, 0.0);
          const end = Offset.zero;
          final tween = Tween(begin: begin, end: end)
              .chain(CurveTween(curve: Curves.easeInOut));
          return SlideTransition(position: animation.drive(tween), child: child);
        },
      ),
    ),
    GoRoute(
      path: '/organization/join',
      pageBuilder: (context, state) => CustomTransitionPage(
        key: state.pageKey,
        child: const JoinOrganizationScreen(),
        transitionsBuilder: (context, animation, secondaryAnimation, child) {
          const begin = Offset(1.0, 0.0);
          const end = Offset.zero;
          final tween = Tween(begin: begin, end: end)
              .chain(CurveTween(curve: Curves.easeInOut));
          return SlideTransition(position: animation.drive(tween), child: child);
        },
      ),
    ),
    GoRoute(
      path: '/organization/tasks',
      pageBuilder: (context, state) => CustomTransitionPage(
        key: state.pageKey,
        child: const TasksScreen(),
        transitionsBuilder: (context, animation, secondaryAnimation, child) {
          const begin = Offset(1.0, 0.0);
          const end = Offset.zero;
          final tween = Tween(begin: begin, end: end)
              .chain(CurveTween(curve: Curves.easeInOut));
          return SlideTransition(position: animation.drive(tween), child: child);
        },
      ),
    ),
    GoRoute(
      path: '/organization/tasks/new',
      pageBuilder: (context, state) {
        final existing = state.extra as AppTask?;
        return CustomTransitionPage(
          key: state.pageKey,
          child: CreateTaskScreen(existing: existing),
          transitionsBuilder: (context, animation, secondaryAnimation, child) {
            const begin = Offset(1.0, 0.0);
            const end = Offset.zero;
            final tween = Tween(begin: begin, end: end)
                .chain(CurveTween(curve: Curves.easeInOut));
            return SlideTransition(
                position: animation.drive(tween), child: child);
          },
        );
      },
    ),
    GoRoute(
      path: '/organization/task/:id',
      pageBuilder: (context, state) {
        final taskId = state.pathParameters['id']!;
        return CustomTransitionPage(
          key: state.pageKey,
          child: TaskDetailScreen(taskId: taskId),
          transitionsBuilder: (context, animation, secondaryAnimation, child) {
            const begin = Offset(1.0, 0.0);
            const end = Offset.zero;
            final tween = Tween(begin: begin, end: end)
                .chain(CurveTween(curve: Curves.easeInOut));
            return SlideTransition(
                position: animation.drive(tween), child: child);
          },
        );
      },
    ),
    GoRoute(
      path: '/sync',
      pageBuilder: (context, state) => CustomTransitionPage(
        key: state.pageKey,
        child: const SyncScreen(),
        transitionsBuilder: (context, animation, secondaryAnimation, child) {
          const begin = Offset(1.0, 0.0);
          const end = Offset.zero;
          final tween = Tween(begin: begin, end: end)
              .chain(CurveTween(curve: Curves.easeInOut));
          return SlideTransition(position: animation.drive(tween), child: child);
        },
      ),
    ),
    GoRoute(
      path: '/import-export',
      pageBuilder: (context, state) => CustomTransitionPage(
        key: state.pageKey,
        child: const ImportExportScreen(),
        transitionsBuilder: (context, animation, secondaryAnimation, child) {
          const begin = Offset(1.0, 0.0);
          const end = Offset.zero;
          final tween = Tween(begin: begin, end: end)
              .chain(CurveTween(curve: Curves.easeInOut));
          return SlideTransition(position: animation.drive(tween), child: child);
        },
      ),
    ),
    GoRoute(
      path: '/reminder/:id',
      pageBuilder: (context, state) {
        final reminderId = state.pathParameters['id']!;
        return CustomTransitionPage(
          key: state.pageKey,
          child: ReminderDetailScreen(reminderId: reminderId),
          transitionsBuilder: (context, animation, secondaryAnimation, child) {
            const begin = Offset(1.0, 0.0);
            const end = Offset.zero;
            final tween = Tween(begin: begin, end: end).chain(CurveTween(curve: Curves.easeInOut));
            return SlideTransition(position: animation.drive(tween), child: child);
          },
        );
      },
    ),
  ],
);

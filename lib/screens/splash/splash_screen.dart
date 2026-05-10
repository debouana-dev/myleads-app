import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/l10n/app_l10n.dart';
import '../../core/theme/app_colors.dart';
import '../../providers/contacts_provider.dart';
import '../../providers/reminders_provider.dart';
import '../../services/storage_service.dart';

class SplashScreen extends ConsumerStatefulWidget {
  const SplashScreen({super.key});

  @override
  ConsumerState<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends ConsumerState<SplashScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _loaderController;

  @override
  void initState() {
    super.initState();

    SystemChrome.setSystemUIOverlayStyle(SystemUiOverlayStyle.light);

    _loaderController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2200),
    )..forward();

    Future.delayed(const Duration(milliseconds: 2500), () async {
      if (!mounted) return;
      // If a session was restored during StorageService.init(), skip login.
      if (StorageService.isLoggedIn) {
        await ref.read(contactsProvider.notifier).reload();
        await ref.read(remindersProvider.notifier).reload();
        if (mounted) context.go('/main');
      } else {
         context.go('/login');
      }
    });
  }

  @override
  void dispose() {
    _loaderController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = ref.watch(l10nProvider);

    return Scaffold(
      body: Container(
        width: double.infinity,
        height: double.infinity,
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              AppColors.primary,
              AppColors.primaryDark,
            ],
            stops: [0.0, 1.0],
          ),
        ),
        child: SafeArea(
          child: Column(
            children: [
              const Spacer(flex: 3),

              // Logo container
              Container(
                width: 120,
                height: 120,
                decoration: BoxDecoration(
                  color: AppColors.white,
                  borderRadius: BorderRadius.circular(32),
                  boxShadow: [
                    BoxShadow(
                      color: AppColors.accent.withOpacity(0.4),
                      blurRadius: 40,
                      offset: const Offset(0, 12),
                    ),
                  ],
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(32),
                  child: Image.asset(
                    'assets/icons/app_logo.png',
                    width: 120,
                    height: 120,
                    fit: BoxFit.contain,
                  ),
                ),
              )
                  .animate()
                  .fadeIn(
                    duration: 600.ms,
                    curve: Curves.easeOut,
                  )
                  .scale(
                    begin: const Offset(0.6, 0.6),
                    end: const Offset(1.0, 1.0),
                    duration: 700.ms,
                    curve: Curves.easeOutBack,
                  ),

              const SizedBox(height: 32),

              // App name
              const Text(
                'Me2Leads',
                style: TextStyle(
                  fontSize: 36,
                  fontWeight: FontWeight.w800,
                  color: AppColors.white,
                  letterSpacing: -0.5,
                ),
              )
                  .animate()
                  .fadeIn(
                    delay: 300.ms,
                    duration: 600.ms,
                  )
                  .slideY(
                    begin: 0.3,
                    end: 0,
                    delay: 300.ms,
                    duration: 600.ms,
                    curve: Curves.easeOutCubic,
                  ),

              const SizedBox(height: 12),

              // Tagline
              Text(
                l10n.splashTagline,
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w500,
                  color: AppColors.white.withOpacity(0.6),
                  letterSpacing: 2,
                ),
              )
                  .animate()
                  .fadeIn(
                    delay: 600.ms,
                    duration: 600.ms,
                  )
                  .slideY(
                    begin: 0.3,
                    end: 0,
                    delay: 600.ms,
                    duration: 600.ms,
                    curve: Curves.easeOutCubic,
                  ),

              const Spacer(flex: 4),

              // Loader bar
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 80),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: SizedBox(
                    height: 4,
                    child: AnimatedBuilder(
                      animation: _loaderController,
                      builder: (context, child) {
                        return Stack(
                          children: [
                            // Track
                            Container(
                              width: double.infinity,
                              height: 4,
                              color: AppColors.white.withOpacity(0.1),
                            ),
                            // Progress
                            FractionallySizedBox(
                              widthFactor: _loaderController.value,
                              child: Container(
                                height: 4,
                                decoration: BoxDecoration(
                                  gradient: AppColors.accentGradient,
                                  borderRadius: BorderRadius.circular(4),
                                  boxShadow: [
                                    BoxShadow(
                                      color: AppColors.accent
                                          .withOpacity(0.5),
                                      blurRadius: 8,
                                      offset: const Offset(0, 0),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ],
                        );
                      },
                    ),
                  ),
                ),
              )
                  .animate()
                  .fadeIn(
                    delay: 900.ms,
                    duration: 500.ms,
                  ),

              const SizedBox(height: 48),
            ],
          ),
        ),
      ),
    );
  }
}

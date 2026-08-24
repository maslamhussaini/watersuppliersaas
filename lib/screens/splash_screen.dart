// =============================================================================
// lib/screens/splash_screen.dart
// Animated launch screen, modelled on OrderMate's.
//
// OrderMate's splash scales and fades a logo over ~2s, shows a spinner, and
// puts version and "Powered by" in the bottom corner.
//
// TWO THINGS DELIBERATELY NOT COPIED
//
// 1. OrderMate BLOCKS on a location permission prompt and sits on the splash
//    until it is granted. This app has no feature that needs GPS, so a
//    permission wall at launch would be asking for something it never uses.
//
// 2. OrderMate waits a fixed `Future.delayed(3 seconds)` before doing anything.
//    A splash should cover real work, not manufacture a wait — three seconds
//    every launch is a tax on the user for a session that is already restored.
//    Here the animation and the session check run CONCURRENTLY and the screen
//    leaves as soon as both are done, with a floor of 900 ms so it does not
//    flash on a fast start.
// =============================================================================

import 'package:flutter/material.dart';

import '../theme/ws_theme.dart';

/// Shown for as long as startup takes, then replaced by [next].
class WsSplashScreen extends StatefulWidget {
  /// Built once the minimum display time has elapsed. Kept as a builder so the
  /// destination widget is not constructed until it is needed.
  final WidgetBuilder next;

  /// Optional startup work to run behind the animation.
  final Future<void> Function()? warmUp;

  const WsSplashScreen({super.key, required this.next, this.warmUp});

  @override
  State<WsSplashScreen> createState() => _WsSplashScreenState();
}

class _WsSplashScreenState extends State<WsSplashScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  );

  late final Animation<double> _scale = Tween<double>(begin: 0.6, end: 1.0)
      .animate(CurvedAnimation(parent: _controller, curve: Curves.easeOutBack));

  late final Animation<double> _fade = Tween<double>(begin: 0.0, end: 1.0)
      .animate(CurvedAnimation(parent: _controller, curve: Curves.easeIn));

  @override
  void initState() {
    super.initState();
    _controller.forward();
    _start();
  }

  Future<void> _start() async {
    // Both at once. Whichever is slower decides when the splash ends.
    await Future.wait([
      Future<void>.delayed(const Duration(milliseconds: 900)),
      if (widget.warmUp != null) widget.warmUp!().catchError((_) {}),
    ]);
    if (!mounted) return;
    Navigator.of(context).pushReplacement(
      PageRouteBuilder(
        transitionDuration: const Duration(milliseconds: 350),
        pageBuilder: (context, a, _) => FadeTransition(
          opacity: a,
          child: widget.next(context),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: DecoratedBox(
      decoration: const BoxDecoration(gradient: WsColors.headerGradient),
      child: Stack(children: [
        Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ScaleTransition(
                scale: _scale,
                child: FadeTransition(
                  opacity: _fade,
                  child: Container(
                    padding: const EdgeInsets.all(26),
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: Colors.white.withValues(alpha: 0.12),
                    ),
                    child: const Icon(Icons.water_drop,
                        size: 74, color: Colors.white),
                  ),
                ),
              ),
              const SizedBox(height: 22),
              FadeTransition(
                opacity: _fade,
                child: const Column(children: [
                  Text(
                    'WaterFlow',
                    style: TextStyle(
                      fontSize: 32,
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                      letterSpacing: 1.4,
                    ),
                  ),
                  SizedBox(height: 6),
                  Text(
                    'Water Supplier Management',
                    style: TextStyle(color: Colors.white70, fontSize: 13),
                  ),
                ]),
              ),
              const SizedBox(height: 40),
              FadeTransition(
                opacity: _fade,
                child: const SizedBox(
                  height: 22,
                  width: 22,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    valueColor: AlwaysStoppedAnimation(Colors.white70),
                  ),
                ),
              ),
            ],
          ),
        ),
        Positioned(
          right: 20,
          bottom: 20,
          child: FadeTransition(
            opacity: _fade,
            child: const Text(
              'Version $wsAppVersion',
              style: TextStyle(color: Colors.white54, fontSize: 11),
            ),
          ),
        ),
      ]),
    ),
  );
}

/// Kept beside the splash that shows it. OrderMate generates this file from a
/// script; here it is one constant, updated with pubspec.yaml.
const String wsAppVersion = '1.0.0';

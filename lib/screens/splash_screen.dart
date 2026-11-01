import 'package:flutter/material.dart';

import 'common.dart';
import 'tablet_ui.dart';

/// Tablet: shown while the library loads. It takes over from Android's own
/// splash: the icon starts where and as big as Android drew it (centred,
/// 113dp), grows to full size, then the rings, name and a thin sweeping bar
/// under "Opening your library" fade in.
class TabletSplash extends StatefulWidget {
  const TabletSplash({super.key});

  @override
  State<TabletSplash> createState() => _TabletSplashState();
}

class _TabletSplashState extends State<TabletSplash> with TickerProviderStateMixin {
  late final _sweep = AnimationController(vsync: this, duration: const Duration(milliseconds: 1400))..repeat();
  late final _intro = AnimationController(vsync: this, duration: const Duration(milliseconds: 650))..forward();

  /// Android 12 draws the splash icon at 452/960 of 240dp.
  static const _systemIconSize = 113.0;
  static const _iconSize = 168.0;

  @override
  void dispose() {
    _sweep.dispose();
    _intro.dispose();
    super.dispose();
  }

  /// Fades [child] in over the later part of the intro.
  Widget _later(Widget child, {double from = 0.45}) => FadeTransition(
    opacity: CurvedAnimation(
      parent: _intro,
      curve: Interval(from, 1, curve: Curves.easeOut),
    ),
    child: child,
  );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: TabletColors.background,
      body: Stack(
        fit: StackFit.expand,
        children: [
          const IgnorePointer(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: RadialGradient(
                  center: Alignment(0, -0.12),
                  radius: 0.6,
                  colors: [Color(0x382DD4BF), Color(0x002DD4BF)],
                ),
              ),
            ),
          ),
          // The icon sits exactly in the middle, where Android's splash
          // left it; the name hangs below it.
          Center(
            child: SizedBox(
              width: 248,
              height: 248,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  _later(
                    Container(
                      width: 248,
                      height: 248,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(70),
                        border: Border.all(color: const Color(0x145EEAD4), width: 2),
                      ),
                    ),
                    from: 0.6,
                  ),
                  _later(
                    Container(
                      width: 204,
                      height: 204,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(52),
                        border: Border.all(color: const Color(0x385EEAD4), width: 2),
                      ),
                    ),
                  ),
                  ScaleTransition(
                    scale: Tween(begin: _systemIconSize / _iconSize, end: 1.0).animate(
                      CurvedAnimation(
                        parent: _intro,
                        curve: const Interval(0, 0.7, curve: Curves.easeOutBack),
                      ),
                    ),
                    child: DecoratedBox(
                      decoration: const BoxDecoration(
                        borderRadius: BorderRadius.all(Radius.circular(40)),
                        boxShadow: [BoxShadow(color: Color(0xB3000000), blurRadius: 40, offset: Offset(0, 24))],
                      ),
                      child: Image.asset('assets/icons/shelfsync.png', width: _iconSize, height: _iconSize),
                    ),
                  ),
                ],
              ),
            ),
          ),
          Align(
            alignment: Alignment.center,
            child: Padding(
              padding: const EdgeInsets.only(top: 248 + 2 * 26),
              child: _later(
                const Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'ShelfSync',
                      style: TextStyle(
                        fontFamily: serifFamily,
                        fontSize: 44,
                        fontWeight: FontWeight.w600,
                        letterSpacing: -0.5,
                        color: TabletColors.text,
                      ),
                    ),
                    SizedBox(height: 8),
                    Text(
                      'Your books, on every screen',
                      style: TextStyle(fontFamily: uiFamily, fontSize: 17, color: TabletColors.dim),
                    ),
                  ],
                ),
              ),
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 96 + MediaQuery.paddingOf(context).bottom,
            child: _later(
              Column(
                children: [
                  Container(
                    width: 180,
                    height: 4,
                    decoration: BoxDecoration(color: const Color(0x1AFFFFFF), borderRadius: BorderRadius.circular(2)),
                    clipBehavior: Clip.antiAlias,
                    child: AnimatedBuilder(
                      animation: _sweep,
                      builder: (context, _) => FractionallySizedBox(
                        alignment: Alignment(-1.6 + 3.2 * Curves.easeInOut.transform(_sweep.value), 0),
                        widthFactor: 0.45,
                        child: const DecoratedBox(
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.all(Radius.circular(2)),
                            gradient: LinearGradient(colors: [Color(0x005EEAD4), TabletColors.accent]),
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 14),
                  const Text(
                    'Opening your library',
                    style: TextStyle(fontFamily: uiFamily, fontSize: 14, color: TabletColors.faint),
                  ),
                ],
              ),
              from: 0.7,
            ),
          ),
        ],
      ),
    );
  }
}

/// Fades its child in once, e.g. the library replacing the splash.
class FadeInOnce extends StatelessWidget {
  const FadeInOnce({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 380),
      curve: Curves.easeOutCubic,
      builder: (context, t, child) => Opacity(
        opacity: t,
        child: Transform.scale(scale: 0.985 + 0.015 * t, child: child),
      ),
      child: child,
    );
  }
}

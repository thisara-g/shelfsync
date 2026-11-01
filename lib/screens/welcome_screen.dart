import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/library_store.dart';
import '../sync/sync_controller.dart';
import 'common.dart';
import 'tablet_ui.dart';

final _privacyUrl = Uri.parse('https://thisara-g.github.io/shelfsync/privacy.html');

/// First-run screen: what ShelfSync does, and Google sign-in or skip.
class WelcomeScreen extends StatelessWidget {
  const WelcomeScreen({super.key, required this.store, required this.sync});

  final LibraryStore store;
  final SyncController sync;

  static const _background = Color(0xFF182024);
  static const _card = Color(0xFF202A2E);
  static const _muted = Color(0xFFA9B8B4);
  static const _accent = Color(0xFF00897B);

  Future<void> _signIn() async {
    await store.setWelcomeDone();
    await sync.signIn();
  }

  @override
  Widget build(BuildContext context) {
    final canSync = sync.status != SyncStatus.notConfigured;
    if (!useDesktopLayout(context)) {
      return _TabletWelcome(canSync: canSync, onSignIn: _signIn, onSkip: store.setWelcomeDone);
    }
    return Theme(
      data: ThemeData(colorSchemeSeed: _accent, brightness: Brightness.dark),
      child: Scaffold(
        backgroundColor: _background,
        body: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 48),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 560),
                child: Column(
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(28),
                      child: Image.asset('assets/icons/shelfsync.png', width: 112, height: 112),
                    ),
                    const SizedBox(height: 28),
                    const Text(
                      'Your books, on every screen',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontFamily: serifFamily,
                        fontSize: 40,
                        fontWeight: FontWeight.w600,
                        height: 1.15,
                        color: Color(0xFFECF1EF),
                      ),
                    ),
                    const SizedBox(height: 16),
                    const Text(
                      'Start a chapter on your PC, finish it on your tablet. '
                      'ShelfSync remembers exactly where you stopped.',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 18, height: 1.5, color: _muted),
                    ),
                    const SizedBox(height: 40),
                    const _Feature(
                      icon: Icons.add,
                      title: 'Add a PDF once',
                      text: 'It appears on all your devices automatically.',
                    ),
                    const _Feature(
                      icon: Icons.bookmark_outline,
                      title: 'Pick up mid-page',
                      text: 'Page, scroll position and zoom follow you.',
                    ),
                    const _Feature(
                      icon: Icons.lock_outline,
                      title: 'Stays in your Google Drive',
                      text: 'No ShelfSync servers. It can only see its own files.',
                    ),
                    const SizedBox(height: 40),
                    if (canSync)
                      SizedBox(
                        width: double.infinity,
                        height: 58,
                        child: FilledButton.icon(
                          style: FilledButton.styleFrom(
                            backgroundColor: _accent,
                            foregroundColor: Colors.white,
                            textStyle: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
                          ),
                          onPressed: _signIn,
                          icon: const Icon(Icons.login),
                          label: const Text('Continue with Google'),
                        ),
                      ),
                    const SizedBox(height: 12),
                    TextButton(
                      style: TextButton.styleFrom(foregroundColor: _muted, textStyle: const TextStyle(fontSize: 16)),
                      onPressed: store.setWelcomeDone,
                      child: Text(canSync ? 'Just read on this device for now' : 'Get started'),
                    ),
                    if (canSync) ...[
                      const SizedBox(height: 8),
                      TextButton(
                        style: TextButton.styleFrom(foregroundColor: const Color(0xFF80CBC4)),
                        onPressed: () => launchUrl(_privacyUrl, mode: LaunchMode.externalApplication),
                        child: const Text('Privacy policy'),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Feature extends StatelessWidget {
  const _Feature({required this.icon, required this.title, required this.text});

  final IconData icon;
  final String title;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
      decoration: BoxDecoration(color: WelcomeScreen._card, borderRadius: BorderRadius.circular(16)),
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(color: const Color(0xFF1F3B38), borderRadius: BorderRadius.circular(12)),
            child: Icon(icon, color: const Color(0xFF4DB6AC)),
          ),
          const SizedBox(width: 18),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600, color: Color(0xFFECF1EF))),
                const SizedBox(height: 2),
                Text(text, style: const TextStyle(fontSize: 15, color: WelcomeScreen._muted)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Tablet first run: your books fanned out, the PC and tablet on the same
/// page, and one Google button.
class _TabletWelcome extends StatefulWidget {
  const _TabletWelcome({required this.canSync, required this.onSignIn, required this.onSkip});

  final bool canSync;
  final VoidCallback onSignIn;
  final VoidCallback onSkip;

  @override
  State<_TabletWelcome> createState() => _TabletWelcomeState();
}

class _TabletWelcomeState extends State<_TabletWelcome> with SingleTickerProviderStateMixin {
  late final _pulse = AnimationController(vsync: this, duration: const Duration(milliseconds: 2400))..repeat();
  late final _privacy = TapGestureRecognizer()
    ..onTap = () => launchUrl(_privacyUrl, mode: LaunchMode.externalApplication);
  late final _skip = TapGestureRecognizer()..onTap = widget.onSkip;

  @override
  void dispose() {
    _pulse.dispose();
    _privacy.dispose();
    _skip.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Theme(
      data: tabletTheme(),
      child: Scaffold(
        backgroundColor: const Color(0xFF0A0E10),
        body: Stack(
          children: [
            const Positioned.fill(child: _WelcomeGlow()),
            SafeArea(
              child: Center(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(32, 24, 32, 40),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 688),
                    child: Column(
                      children: [
                        const SizedBox(height: 360, width: 600, child: _CoverFanArt()),
                        const SizedBox(height: 24),
                        _SyncLine(pulse: _pulse),
                        const SizedBox(height: 28),
                        const Text(
                          'Every book, every screen.',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontFamily: serifFamily,
                            fontSize: 54,
                            fontWeight: FontWeight.w600,
                            height: 1.08,
                            letterSpacing: -0.8,
                            color: TabletColors.text,
                          ),
                        ),
                        ShaderMask(
                          shaderCallback: (bounds) => const LinearGradient(
                            colors: [Color(0xFF5EEAD4), Color(0xFF93C5FD), Color(0xFFF9A8D4)],
                            stops: [0, 0.55, 1],
                          ).createShader(bounds),
                          child: const Text(
                            'Right where you left off.',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontFamily: serifFamily,
                              fontSize: 54,
                              fontWeight: FontWeight.w600,
                              height: 1.08,
                              letterSpacing: -0.8,
                              color: Colors.white,
                            ),
                          ),
                        ),
                        const SizedBox(height: 20),
                        ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 560),
                          child: const Text(
                            'Add a PDF on your PC and it’s already on your tablet — open at the very line '
                            'you stopped reading.',
                            textAlign: TextAlign.center,
                            style: TextStyle(fontSize: 20, height: 1.5, color: Color(0xFFA9B8B4)),
                          ),
                        ),
                        const SizedBox(height: 44),
                        const IntrinsicHeight(
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              _WelcomeFeature(
                                icon: Icons.sync_rounded,
                                tint: Color(0x292DD4BF),
                                ink: Color(0xFF5EEAD4),
                                title: 'Add once, read anywhere',
                                text: 'Your other devices get the book on their own.',
                              ),
                              SizedBox(width: 14),
                              _WelcomeFeature(
                                icon: Icons.bookmark_border_rounded,
                                tint: Color(0x2993C5FD),
                                ink: Color(0xFF93C5FD),
                                title: 'Mid-page resume',
                                text: 'Not just the page — the exact spot on it.',
                              ),
                              SizedBox(width: 14),
                              _WelcomeFeature(
                                icon: Icons.lock_outline_rounded,
                                tint: Color(0x24F9A8D4),
                                ink: Color(0xFFF9A8D4),
                                title: 'Yours alone',
                                text: 'Kept in your Google Drive. No servers, no new account.',
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 52),
                        _GoogleButton(
                          label: widget.canSync ? 'Continue with Google' : 'Get started',
                          google: widget.canSync,
                          onPressed: widget.canSync ? widget.onSignIn : widget.onSkip,
                        ),
                        const SizedBox(height: 18),
                        if (widget.canSync)
                          Text.rich(
                            TextSpan(
                              text: 'Free · nothing to set up · ',
                              children: [
                                TextSpan(
                                  text: 'Privacy',
                                  recognizer: _privacy,
                                  style: const TextStyle(color: TabletColors.accent, decoration: TextDecoration.underline),
                                ),
                                const TextSpan(text: ' · '),
                                TextSpan(
                                  text: 'Just read on this device for now',
                                  recognizer: _skip,
                                  style: const TextStyle(color: TabletColors.dim, decoration: TextDecoration.underline),
                                ),
                              ],
                            ),
                            textAlign: TextAlign.center,
                            style: const TextStyle(fontSize: 14, color: TabletColors.faint),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _WelcomeGlow extends StatelessWidget {
  const _WelcomeGlow();

  @override
  Widget build(BuildContext context) {
    Widget glow(Alignment at, double radius, Color color) => DecoratedBox(
      decoration: BoxDecoration(
        gradient: RadialGradient(center: at, radius: radius, colors: [color, color.withValues(alpha: 0)]),
      ),
    );
    return IgnorePointer(
      child: Stack(
        fit: StackFit.expand,
        children: [
          glow(const Alignment(0, -0.48), 0.62, const Color(0x4D2DD4BF)),
          glow(const Alignment(-0.7, -0.8), 0.45, const Color(0x4042A5F5)),
          glow(const Alignment(0.76, -0.72), 0.45, const Color(0x33D81B60)),
        ],
      ),
    );
  }
}

/// Five made-up covers fanned out like a hand of cards.
class _CoverFanArt extends StatelessWidget {
  const _CoverFanArt();

  static const _covers = [
    ('Digital Design', 'Mano', Color(0xFF43A047), Color(0xFF1B5E20), _Pattern.band, -0.454, 150.0, 15.0),
    ('Pride and Prejudice', 'Jane Austen', Color(0xFFD81B60), Color(0xFF880E4F), _Pattern.glow, -0.227, 166.0, 16.0),
    ('Microwave Engineering', 'Pozar', Color(0xFFFB8C00), Color(0xFFBF360C), _Pattern.grid, 0.454, 150.0, 15.0),
    ('Signals and Systems', 'Oppenheim', Color(0xFF8E24AA), Color(0xFF4A148C), _Pattern.stripes, 0.227, 166.0, 16.0),
    ('C Programming', 'K. N. King', Color(0xFF1E88E5), Color(0xFF0D47A1), _Pattern.rings, 0.0, 190.0, 21.0),
  ];

  @override
  Widget build(BuildContext context) {
    return Stack(
      clipBehavior: Clip.none,
      alignment: Alignment.bottomCenter,
      children: [
        for (final (title, author, c1, c2, pattern, angle, width, size) in _covers)
          Positioned(
            bottom: 40,
            child: Transform.rotate(
              angle: angle,
              // Turn about a point well below the covers, like a fanned hand.
              origin: Offset(0, width / 0.703 * 1.1),
              child: _ArtCover(
                title: title,
                author: author,
                colors: (c1, c2),
                pattern: pattern,
                width: width,
                titleSize: size,
              ),
            ),
          ),
      ],
    );
  }
}

enum _Pattern { rings, stripes, band, grid, glow }

class _ArtCover extends StatelessWidget {
  const _ArtCover({
    required this.title,
    required this.author,
    required this.colors,
    required this.pattern,
    required this.width,
    required this.titleSize,
  });

  final String title;
  final String author;
  final (Color, Color) colors;
  final _Pattern pattern;
  final double width;
  final double titleSize;

  @override
  Widget build(BuildContext context) {
    final height = width / 0.703;
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        borderRadius: const BorderRadius.horizontal(left: Radius.circular(4), right: Radius.circular(9)),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [colors.$1, colors.$2],
        ),
        boxShadow: const [BoxShadow(color: Color(0xE6000000), blurRadius: 50, offset: Offset(0, 30), spreadRadius: -16)],
      ),
      clipBehavior: Clip.antiAlias,
      child: CustomPaint(
        painter: _PatternPainter(pattern),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 18, 14, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                author.toUpperCase(),
                style: const TextStyle(fontSize: 9, letterSpacing: 1.6, color: Color(0xD9FFFFFF)),
              ),
              Text(
                title,
                style: TextStyle(
                  fontFamily: serifFamily,
                  fontSize: titleSize,
                  fontWeight: FontWeight.w700,
                  height: 1.05,
                  color: Colors.white,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PatternPainter extends CustomPainter {
  _PatternPainter(this.pattern);

  final _Pattern pattern;

  @override
  void paint(Canvas canvas, Size size) {
    final light = Paint()..color = const Color(0x1FFFFFFF);
    switch (pattern) {
      case _Pattern.rings:
        final c = Offset(size.width * 0.78, size.height * 0.22);
        final r = size.shortestSide * 0.32;
        canvas.drawCircle(c, r, Paint()..color = const Color(0x33FFFFFF));
        canvas.drawCircle(
          c,
          r * 1.6,
          Paint()
            ..color = const Color(0x1FFFFFFF)
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2,
        );
      case _Pattern.stripes:
        final p = Paint()
          ..color = const Color(0x14FFFFFF)
          ..strokeWidth = 7;
        for (var x = -size.height; x < size.width; x += 16) {
          canvas.drawLine(Offset(x, size.height), Offset(x + size.height, 0), p);
        }
      case _Pattern.band:
        canvas.drawRect(Rect.fromLTWH(0, size.height * 0.56, size.width, size.height * 0.03), Paint()..color = const Color(0x4D000000));
      case _Pattern.grid:
        final p = Paint()..color = const Color(0x14FFFFFF);
        for (var x = 0.0; x < size.width; x += 14) {
          canvas.drawLine(Offset(x, 0), Offset(x, size.height), p);
        }
        for (var y = 0.0; y < size.height; y += 14) {
          canvas.drawLine(Offset(0, y), Offset(size.width, y), p);
        }
      case _Pattern.glow:
        final rect = Offset.zero & size;
        canvas.drawRect(
          rect,
          Paint()
            ..shader = const RadialGradient(
              center: Alignment(0, 1.3),
              radius: 0.9,
              colors: [Color(0x47FFFFFF), Color(0x00FFFFFF)],
            ).createShader(rect),
        );
    }
    // The spine.
    canvas.drawRect(Rect.fromLTWH(0, 0, 4, size.height), light);
  }

  @override
  bool shouldRepaint(_PatternPainter old) => old.pattern != pattern;
}

/// "PC · page 214 ‒ ‒ ● ‒ ‒ Tablet · page 214", the dot travelling across.
class _SyncLine extends StatelessWidget {
  const _SyncLine({required this.pulse});

  final Animation<double> pulse;

  @override
  Widget build(BuildContext context) {
    Widget pill(IconData icon, String text, {bool lit = false}) => Container(
      height: 38,
      padding: const EdgeInsets.symmetric(horizontal: 14),
      decoration: BoxDecoration(
        color: lit ? const Color(0x242DD4BF) : const Color(0x0FFFFFFF),
        borderRadius: BorderRadius.circular(19),
        border: Border.all(color: lit ? const Color(0x595EEAD4) : const Color(0x14FFFFFF)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 18, color: lit ? TabletColors.accentLight : TabletColors.dim),
          const SizedBox(width: 8),
          Text(
            text,
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: lit ? TabletColors.accentLight : TabletColors.dim,
            ),
          ),
        ],
      ),
    );
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        pill(Icons.laptop_outlined, 'PC · page 214'),
        const SizedBox(width: 14),
        SizedBox(
          width: 120,
          height: 14,
          child: AnimatedBuilder(
            animation: pulse,
            builder: (context, _) {
              final t = Curves.easeInOut.transform(pulse.value);
              return CustomPaint(painter: _DashPainter(t));
            },
          ),
        ),
        const SizedBox(width: 14),
        pill(Icons.tablet_android_outlined, 'Tablet · page 214', lit: true),
      ],
    );
  }
}

class _DashPainter extends CustomPainter {
  _DashPainter(this.t);

  final double t;

  @override
  void paint(Canvas canvas, Size size) {
    final y = size.height / 2;
    final dash = Paint()
      ..color = TabletColors.accent
      ..strokeWidth = 2;
    for (var x = 0.0; x < size.width; x += 12) {
      canvas.drawLine(Offset(x, y), Offset(math.min(x + 6, size.width), y), dash);
    }
    final dot = Offset(size.width * t, y);
    canvas.drawCircle(dot, 10, Paint()..color = const Color(0x405EEAD4)..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6));
    canvas.drawCircle(dot, 6, Paint()..color = TabletColors.accent);
  }

  @override
  bool shouldRepaint(_DashPainter old) => old.t != t;
}

class _WelcomeFeature extends StatelessWidget {
  const _WelcomeFeature({
    required this.icon,
    required this.tint,
    required this.ink,
    required this.title,
    required this.text,
  });

  final IconData icon;
  final Color tint;
  final Color ink;
  final String title;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.fromLTRB(18, 20, 18, 20),
        decoration: BoxDecoration(
          color: const Color(0x0DFFFFFF),
          borderRadius: BorderRadius.circular(22),
          border: Border.all(color: const Color(0x14FFFFFF)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(color: tint, borderRadius: BorderRadius.circular(12)),
              child: Icon(icon, size: 20, color: ink),
            ),
            const SizedBox(height: 10),
            Text(title, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: TabletColors.text)),
            const SizedBox(height: 10),
            Text(text, style: const TextStyle(fontSize: 14, height: 1.45, color: TabletColors.dim)),
          ],
        ),
      ),
    );
  }
}

class _GoogleButton extends StatelessWidget {
  const _GoogleButton({required this.label, required this.google, required this.onPressed});

  final String label;
  final bool google;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(maxWidth: 480),
      decoration: const BoxDecoration(
        borderRadius: BorderRadius.all(Radius.circular(33)),
        boxShadow: [
          BoxShadow(color: Color(0x732DD4BF), blurRadius: 40, offset: Offset(0, 20), spreadRadius: -12),
          BoxShadow(color: Color(0x0FFFFFFF), spreadRadius: 6),
        ],
      ),
      child: Material(
        color: Colors.white,
        shape: const StadiumBorder(),
        child: InkWell(
          customBorder: const StadiumBorder(),
          onTap: onPressed,
          child: SizedBox(
            height: 66,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (google) ...[
                  Image.asset('assets/icons/google_g.png', width: 24, height: 24),
                  const SizedBox(width: 14),
                ],
                Text(
                  label,
                  style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w700, color: Color(0xFF1F1F1F)),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

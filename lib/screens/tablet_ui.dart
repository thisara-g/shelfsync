import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../models/book.dart';
import '../sync/library_sync.dart';
import 'common.dart';

/// Colours of the tablet design: dark, cover-led, one teal accent.
abstract final class TabletColors {
  static const background = Color(0xFF0C1012);
  static const sheet = Color(0xFF12181A);
  static const card = Color(0xFF141B1D);
  static const text = Color(0xFFEEF2F0);
  static const soft = Color(0xFFD5DEDB);
  static const muted = Color(0xFFB7C6C2);
  static const dim = Color(0xFF93A6A1);
  static const faint = Color(0xFF6F817C);
  static const accent = Color(0xFF5EEAD4);
  static const accentLight = Color(0xFF99F6E4);
  static const onAccent = Color(0xFF04201C);
  static const green = Color(0xFF34D399);
  static const danger = Color(0xFFFCA5A5);

  /// White at low opacity, for glass buttons and cards.
  static const glass = Color(0x14FFFFFF);
  static const glassBorder = Color(0x1AFFFFFF);
  static const line = Color(0x12FFFFFF);

  static const tealGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0xFF2DD4BF), Color(0xFF0D9488)],
  );
}

/// Material theme for the tablet screens, so dialogs, menus and snack bars
/// opened from them are dark too.
ThemeData tabletTheme() {
  const accent = TabletColors.accent;
  final scheme = ColorScheme.fromSeed(seedColor: const Color(0xFF0D9488), brightness: Brightness.dark).copyWith(
    primary: accent,
    onPrimary: TabletColors.onAccent,
    primaryContainer: const Color(0xFF1F3B38),
    onPrimaryContainer: TabletColors.accentLight,
    secondaryContainer: const Color(0xFF1F3B38),
    onSecondaryContainer: TabletColors.accentLight,
    surface: TabletColors.sheet,
    onSurface: TabletColors.text,
    onSurfaceVariant: TabletColors.dim,
    surfaceContainerLowest: TabletColors.background,
    surfaceContainerLow: TabletColors.sheet,
    surfaceContainer: TabletColors.card,
    surfaceContainerHigh: const Color(0xFF1B2326),
    surfaceContainerHighest: const Color(0xFF263033),
    outline: const Color(0x38FFFFFF),
    outlineVariant: const Color(0x1FFFFFFF),
    error: const Color(0xFFF87171),
    inverseSurface: TabletColors.text,
    onInverseSurface: TabletColors.background,
  );
  return ThemeData(
    colorScheme: scheme,
    brightness: Brightness.dark,
    fontFamily: uiFamily,
    scaffoldBackgroundColor: TabletColors.background,
    dialogTheme: DialogThemeData(
      backgroundColor: TabletColors.card,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
    ),
    bottomSheetTheme: const BottomSheetThemeData(
      backgroundColor: TabletColors.sheet,
      modalBackgroundColor: TabletColors.sheet,
      surfaceTintColor: Colors.transparent,
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: const Color(0xFF1B2326),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: const Color(0xFF1B2326),
      contentTextStyle: const TextStyle(color: TabletColors.text, fontSize: 15, fontFamily: uiFamily),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      actionTextColor: accent,
    ),
  );
}

/// "Good morning", "Good afternoon" or "Good evening", with the first name
/// when there is one.
String greeting(String? name, {DateTime? now}) {
  final hour = (now ?? DateTime.now()).hour;
  final part = hour < 5 ? 'evening' : (hour < 12 ? 'morning' : (hour < 18 ? 'afternoon' : 'evening'));
  final first = name?.trim().split(RegExp(r'\s+')).first ?? '';
  return first.isEmpty || first.contains('@') ? 'Good $part' : 'Good $part, $first';
}

/// "62%" style percentage of [book] read.
String percentRead(Book book) => '${(book.progress * 100).round()}%';

// --- Cover colour -----------------------------------------------------------

final _tints = <String, Future<Color>>{};

/// The tint the library glows in behind a book: the cover's most colourful
/// shade, made vivid enough to glow. Covers that are mostly black and white
/// (text-only first pages) glow blue.
Future<Color> coverTint(Book book, Future<File?> cover) {
  final cached = _tints[book.id];
  if (cached != null) return cached;
  final result = () async {
    final file = await cover;
    if (file == null) return placeholderTint(book.title);
    try {
      final codec = await ui.instantiateImageCodec(await file.readAsBytes(), targetWidth: 24);
      final frame = await codec.getNextFrame();
      final data = await frame.image.toByteData(format: ui.ImageByteFormat.rawRgba);
      frame.image.dispose();
      if (data == null) return _fallbackTint;
      var r = 0.0, g = 0.0, b = 0.0, weight = 0.0;
      for (var i = 0; i + 3 < data.lengthInBytes; i += 4) {
        final color = Color.fromARGB(255, data.getUint8(i), data.getUint8(i + 1), data.getUint8(i + 2));
        final hsv = HSVColor.fromColor(color);
        final w = hsv.saturation * hsv.saturation * hsv.value;
        r += color.r * w;
        g += color.g * w;
        b += color.b * w;
        weight += w;
      }
      final count = data.lengthInBytes / 4;
      if (weight / count < 0.04) return _fallbackTint;
      final mean = Color.from(alpha: 1, red: r / weight, green: g / weight, blue: b / weight);
      final hsl = HSLColor.fromColor(mean);
      return hsl.withSaturation(math.max(hsl.saturation, 0.6)).withLightness(0.5).toColor();
    } catch (_) {
      return _fallbackTint;
    }
  }();
  // A cloud-only book has no cover yet: don't remember the placeholder tint.
  result.then((_) async {
    if (await cover == null) _tints.remove(book.id);
  });
  return _tints[book.id] = result;
}

const _fallbackTint = Color(0xFF2176E2);

/// Matches [PlaceholderCover]'s colours.
Color placeholderTint(String title) {
  final hue = (title.hashCode % 360).abs().toDouble();
  return HSLColor.fromAHSL(1, hue, 0.6, 0.5).toColor();
}

/// Builds with the book's [coverTint], fading to it from [fallback].
class CoverTintBuilder extends StatelessWidget {
  const CoverTintBuilder({
    super.key,
    required this.book,
    required this.cover,
    required this.builder,
    this.fallback = const Color(0xFF1F4E79),
  });

  final Book book;
  final Future<File?> cover;
  final Color fallback;
  final Widget Function(BuildContext context, Color tint) builder;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Color>(
      future: coverTint(book, cover),
      builder: (context, snapshot) => TweenAnimationBuilder<Color?>(
        tween: ColorTween(end: snapshot.data ?? fallback),
        duration: const Duration(milliseconds: 500),
        builder: (context, tint, _) => builder(context, tint ?? fallback),
      ),
    );
  }
}

// --- Covers -------------------------------------------------------------------

/// A book cover as a physical object: rounded more on the open edge, a lit
/// spine and a deep shadow. Shows Drive and finished badges and download
/// progress.
class TabletCover extends StatelessWidget {
  const TabletCover({
    super.key,
    required this.book,
    required this.cover,
    this.transfer,
    this.badges = true,
    this.shadow = const BoxShadow(color: Color(0xD9000000), blurRadius: 28, offset: Offset(0, 18), spreadRadius: -12),
    this.spine = 3,
  });

  final Book book;
  final Future<File?> cover;
  final Transfer? transfer;
  final bool badges;
  final BoxShadow? shadow;

  /// Width of the lit spine edge.
  final double spine;

  static const radius = BorderRadius.only(
    topLeft: Radius.circular(3),
    bottomLeft: Radius.circular(3),
    topRight: Radius.circular(7),
    bottomRight: Radius.circular(7),
  );

  @override
  Widget build(BuildContext context) {
    final t = transfer;
    return DecoratedBox(
      decoration: BoxDecoration(borderRadius: radius, boxShadow: [?shadow]),
      child: ClipRRect(
        borderRadius: radius,
        child: Stack(
          fit: StackFit.expand,
          children: [
            _CoverPicture(book: book, cover: cover),
            // The spine: a lit edge, then a crease shadow.
            Positioned(
              left: 0,
              top: 0,
              bottom: 0,
              width: spine * 3.5,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    stops: [0, spine / (spine * 3.5), spine / (spine * 3.5), 1],
                    colors: const [Color(0x24FFFFFF), Color(0x24FFFFFF), Color(0x40000000), Color(0x00000000)],
                  ),
                ),
              ),
            ),
            if (badges && t == null && !book.isLocal)
              const Positioned(top: 8, right: 8, child: _CloudBadge())
            else if (badges && t == null && book.isFinished)
              const Positioned(top: 8, right: 8, child: _DoneBadge()),
            if (t != null) _TransferRing(t),
          ],
        ),
      ),
    );
  }
}

/// The first-page thumbnail over a placeholder in the book's colour, so a
/// cover never flashes black while it renders or decodes. The placeholder
/// names the book only when there is room for the title.
class _CoverPicture extends StatelessWidget {
  const _CoverPicture({required this.book, required this.cover});

  final Book book;
  final Future<File?> cover;

  @override
  Widget build(BuildContext context) {
    final placeholder = _TitleCover(title: book.title);
    return FutureBuilder<File?>(
      future: cover,
      builder: (context, snapshot) {
        final file = snapshot.data;
        if (file == null) return placeholder;
        return Image.file(
          file,
          fit: BoxFit.cover,
          alignment: Alignment.topCenter,
          frameBuilder: (context, child, frame, sync) => frame == null && !sync ? placeholder : child,
          errorBuilder: (_, _, _) => placeholder,
        );
      },
    );
  }
}

class _TitleCover extends StatelessWidget {
  const _TitleCover({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    final tint = placeholderTint(title);
    final hsl = HSLColor.fromColor(tint);
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [hsl.withLightness(0.42).toColor(), hsl.withLightness(0.26).toColor()],
        ),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          if (constraints.maxWidth < 90) return const SizedBox.expand();
          final size = (constraints.maxWidth / 9).clamp(13.0, 30.0);
          return Padding(
            padding: EdgeInsets.fromLTRB(size * 0.9, size, size * 0.7, size),
            child: Align(
              alignment: Alignment.bottomLeft,
              child: Text(
                title,
                maxLines: 5,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: Colors.white,
                  fontFamily: serifFamily,
                  fontSize: size,
                  fontWeight: FontWeight.w700,
                  height: 1.12,
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _CloudBadge extends StatelessWidget {
  const _CloudBadge();

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: 'In Google Drive · tap to download',
      child: Container(
        width: 28,
        height: 28,
        decoration: const BoxDecoration(color: Color(0x8C000000), shape: BoxShape.circle),
        child: const Icon(Icons.cloud_download_outlined, size: 16, color: Colors.white),
      ),
    );
  }
}

class _DoneBadge extends StatelessWidget {
  const _DoneBadge();

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 24,
      padding: const EdgeInsets.symmetric(horizontal: 9),
      decoration: BoxDecoration(color: TabletColors.green, borderRadius: BorderRadius.circular(12)),
      child: const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            'DONE',
            style: TextStyle(color: Color(0xFF052E1F), fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 0.3),
          ),
        ],
      ),
    );
  }
}

class _TransferRing extends StatelessWidget {
  const _TransferRing(this.transfer);

  final Transfer transfer;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: const Color(0x73000000),
      child: Center(
        child: SizedBox.square(
          dimension: 40,
          child: CircularProgressIndicator(
            value: transfer.progress,
            strokeWidth: 4,
            color: TabletColors.accent,
            backgroundColor: Colors.white24,
          ),
        ),
      ),
    );
  }
}

/// A small cover for shelf cards and stacks.
class MiniCover extends StatelessWidget {
  const MiniCover({super.key, required this.book, required this.cover, required this.width, required this.height});

  final Book book;
  final Future<File?> cover;
  final double width;
  final double height;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width,
      height: height,
      child: TabletCover(
        book: book,
        cover: cover,
        badges: false,
        spine: 2,
        shadow: const BoxShadow(color: Color(0x80000000), blurRadius: 12, offset: Offset(0, 6)),
      ),
    );
  }
}

/// Up to three covers fanned out, the last one on top.
class CoverFan extends StatelessWidget {
  const CoverFan({
    super.key,
    required this.books,
    required this.coverFor,
    required this.coverSize,
    this.spread = 18,
    this.angles = const [-0.21, -0.035, 0.157],
    this.colors = const [],
  });

  final List<Book> books;
  final Future<File?> Function(Book) coverFor;
  final Size coverSize;

  /// Horizontal step between covers.
  final double spread;
  final List<double> angles;

  /// Plain colour cards shown in place of missing books.
  final List<Color> colors;

  @override
  Widget build(BuildContext context) {
    final count = math.max(books.length, colors.isEmpty ? 0 : 3).clamp(0, 3);
    return SizedBox(
      width: coverSize.width + spread * 2 + 12,
      height: coverSize.height + 12,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          for (var i = 0; i < count; i++)
            Positioned(
              left: 6 + spread * (count == 3 ? i : i + 1),
              top: 6,
              child: Transform.rotate(
                angle: angles[count == 3 ? i : i + 1],
                child: i < books.length
                    ? MiniCover(
                        book: books[i],
                        cover: coverFor(books[i]),
                        width: coverSize.width,
                        height: coverSize.height,
                      )
                    : Container(
                        width: coverSize.width,
                        height: coverSize.height,
                        decoration: BoxDecoration(
                          color: colors[i % colors.length],
                          borderRadius: TabletCover.radius,
                          boxShadow: const [BoxShadow(color: Color(0x80000000), blurRadius: 12, offset: Offset(0, 6))],
                        ),
                      ),
              ),
            ),
        ],
      ),
    );
  }
}

// --- Buttons and small pieces ----------------------------------------------------

/// Round glass button with an icon.
class GlassIconButton extends StatelessWidget {
  const GlassIconButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.size = 48,
    this.iconSize = 22,
    this.background = TabletColors.glass,
    this.foreground = TabletColors.text,
    this.border = true,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;
  final double size;
  final double iconSize;
  final Color background;
  final Color foreground;
  final bool border;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: Material(
        color: background,
        shape: CircleBorder(side: border ? const BorderSide(color: TabletColors.glassBorder) : BorderSide.none),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onPressed,
          child: SizedBox.square(
            dimension: size,
            child: Icon(icon, size: iconSize, color: foreground),
          ),
        ),
      ),
    );
  }
}

/// The teal pill for the main action on a screen, glowing a little.
class TealButton extends StatelessWidget {
  const TealButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.height = 60,
    this.fontSize = 18,
    this.padding = const EdgeInsets.symmetric(horizontal: 30),
    this.glow = true,
    this.expand = false,
  });

  final String label;
  final IconData? icon;
  final VoidCallback? onPressed;
  final double height;
  final double fontSize;
  final EdgeInsets padding;
  final bool glow;
  final bool expand;

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null;
    return Opacity(
      opacity: enabled ? 1 : 0.45,
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: TabletColors.tealGradient,
          borderRadius: BorderRadius.circular(height / 2),
          boxShadow: [
            if (glow && enabled)
              const BoxShadow(color: Color(0xA62DD4BF), blurRadius: 30, offset: Offset(0, 12), spreadRadius: -8),
          ],
        ),
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            borderRadius: BorderRadius.circular(height / 2),
            onTap: onPressed,
            child: Container(
              height: height,
              padding: padding,
              child: Row(
                mainAxisSize: expand ? MainAxisSize.max : MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  if (icon != null) ...[
                    Icon(icon, size: fontSize + 4, color: TabletColors.onAccent),
                    const SizedBox(width: 8),
                  ],
                  Flexible(
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: TabletColors.onAccent, fontSize: fontSize, fontWeight: FontWeight.w700),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Outlined glass pill for secondary actions.
class GlassPillButton extends StatelessWidget {
  const GlassPillButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.height = 54,
    this.fontSize = 17,
    this.foreground = TabletColors.text,
  });

  final String label;
  final IconData? icon;
  final VoidCallback? onPressed;
  final double height;
  final double fontSize;
  final Color foreground;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: const Color(0x0FFFFFFF),
      shape: const StadiumBorder(side: BorderSide(color: Color(0x29FFFFFF))),
      child: InkWell(
        customBorder: const StadiumBorder(),
        onTap: onPressed,
        child: Container(
          height: height,
          padding: EdgeInsets.symmetric(horizontal: icon == null ? 22 : 18),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (icon != null) ...[Icon(icon, size: fontSize + 3, color: foreground), const SizedBox(width: 8)],
              Text(
                label,
                style: TextStyle(color: foreground, fontSize: fontSize, fontWeight: FontWeight.w600),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Filter chip: white when selected, outlined otherwise.
class TabletChip extends StatelessWidget {
  const TabletChip({super.key, required this.label, required this.selected, required this.onTap});

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: selected ? TabletColors.text : Colors.transparent,
      shape: StadiumBorder(side: selected ? BorderSide.none : const BorderSide(color: Color(0x24FFFFFF))),
      child: InkWell(
        customBorder: const StadiumBorder(),
        onTap: onTap,
        child: Container(
          height: 42,
          padding: const EdgeInsets.symmetric(horizontal: 18),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                label,
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w600,
                  color: selected ? TabletColors.background : TabletColors.soft,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Thin progress bar in the accent colour.
class TabletProgress extends StatelessWidget {
  const TabletProgress({super.key, required this.value, this.height = 3, this.glow = false});

  final double value;
  final double height;
  final bool glow;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: height,
      decoration: BoxDecoration(color: const Color(0x1AFFFFFF), borderRadius: BorderRadius.circular(height / 2)),
      alignment: Alignment.centerLeft,
      child: FractionallySizedBox(
        widthFactor: value.clamp(0.0, 1.0),
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(height / 2),
            gradient: glow ? const LinearGradient(colors: [Color(0xFF14B8A6), TabletColors.accent]) : null,
            color: glow ? null : TabletColors.accent,
            boxShadow: [if (glow) const BoxShadow(color: Color(0x995EEAD4), blurRadius: 14)],
          ),
        ),
      ),
    );
  }
}

/// Upper-case section label, like "ON SHELVES".
class TabletLabel extends StatelessWidget {
  const TabletLabel(this.text, {super.key, this.color = TabletColors.faint});

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) => Text(
    text.toUpperCase(),
    style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, letterSpacing: 1.5, color: color),
  );
}

/// Grab handle at the top of a sheet.
class SheetHandle extends StatelessWidget {
  const SheetHandle({super.key});

  @override
  Widget build(BuildContext context) => Center(
    child: Container(
      width: 44,
      height: 5,
      decoration: BoxDecoration(color: const Color(0x38FFFFFF), borderRadius: BorderRadius.circular(3)),
    ),
  );
}

/// A soft blurred ellipse of colour, e.g. the glow under a lifted cover.
class Glow extends StatelessWidget {
  const Glow({super.key, required this.color, required this.width, required this.height, this.blur = 28});

  final Color color;
  final double width;
  final double height;
  final double blur;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: ImageFiltered(
        imageFilter: ui.ImageFilter.blur(sigmaX: blur, sigmaY: blur, tileMode: TileMode.decal),
        child: Container(
          width: width,
          height: height,
          decoration: BoxDecoration(color: color, borderRadius: BorderRadius.all(Radius.elliptical(width, height))),
        ),
      ),
    );
  }
}

/// A rounded rectangle drawn with a dashed outline, for "New shelf" places.
class DashedBorder extends StatelessWidget {
  const DashedBorder({super.key, required this.child, this.radius = 22, this.color = const Color(0x38FFFFFF)});

  final Widget child;
  final double radius;
  final Color color;

  @override
  Widget build(BuildContext context) => CustomPaint(foregroundPainter: _DashedPainter(radius, color), child: child);
}

class _DashedPainter extends CustomPainter {
  _DashedPainter(this.radius, this.color);

  final double radius;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final path = Path()..addRRect(RRect.fromRectAndRadius((Offset.zero & size).deflate(0.75), Radius.circular(radius)));
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    for (final metric in path.computeMetrics()) {
      for (var d = 0.0; d < metric.length; d += 10) {
        canvas.drawPath(metric.extractPath(d, math.min(d + 5, metric.length)), paint);
      }
    }
  }

  @override
  bool shouldRepaint(_DashedPainter old) => old.radius != radius || old.color != color;
}

/// Avatar with the user's initial inside a teal-blue-violet ring.
class AccountRing extends StatelessWidget {
  const AccountRing({
    super.key,
    required this.initial,
    this.size = 48,
    this.onTap,
    this.border = TabletColors.background,
  });

  final String? initial;
  final double size;
  final VoidCallback? onTap;
  final Color border;

  @override
  Widget build(BuildContext context) {
    final ring = size / 24;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: size,
        height: size,
        padding: EdgeInsets.all(ring),
        decoration: const BoxDecoration(
          shape: BoxShape.circle,
          gradient: SweepGradient(
            startAngle: 0,
            endAngle: math.pi * 2,
            transform: GradientRotation(math.pi * 0.6),
            colors: [Color(0xFF5EEAD4), Color(0xFF42A5F5), Color(0xFFA78BFA), Color(0xFF5EEAD4)],
          ),
        ),
        child: Container(
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: const Color(0xFF263238),
            border: Border.all(color: border, width: ring),
          ),
          alignment: Alignment.center,
          child: initial == null
              ? Icon(Icons.person_outline_rounded, color: Colors.white, size: size * 0.45)
              : Text(
                  initial!,
                  style: TextStyle(color: Colors.white, fontSize: size * 0.36, fontWeight: FontWeight.w700),
                ),
        ),
      ),
    );
  }
}

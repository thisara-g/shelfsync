import 'dart:io';

import 'package:flutter/material.dart';

import '../models/book.dart';

/// Serif family for book titles and headings; resolves to the platform's
/// serif font (Noto Serif on Android, DejaVu/Noto Serif on Linux).
const serifFamily = 'serif';

/// Desktop layout: sidebar, toolbar and keyboard-first controls. Used on
/// desktop platforms unless the window is narrow, where the touch layout fits
/// better.
bool useDesktopLayout(BuildContext context) {
  final desktop = Platform.isLinux || Platform.isWindows || Platform.isMacOS;
  return desktop && MediaQuery.sizeOf(context).width >= 760;
}

String timeAgo(DateTime time, {DateTime? now}) {
  final diff = (now ?? DateTime.now()).difference(time);
  if (diff.inSeconds < 60) return 'just now';
  if (diff.inMinutes < 60) return '${diff.inMinutes} min ago';
  if (diff.inHours < 24) return '${diff.inHours} h ago';
  if (diff.inDays == 1) return 'yesterday';
  if (diff.inDays < 30) return '${diff.inDays} days ago';
  const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  return '${time.day} ${months[time.month - 1]} ${time.year}';
}

/// "last read here, 5 min ago" / "last read on Galaxy Tab, yesterday".
String? lastReadLine(Book book) {
  final when = book.lastReadAt;
  if (when == null) return null;
  final device = book.progressDevice;
  final where = device == null ? 'here' : 'on $device';
  return 'Last read $where, ${timeAgo(when)}';
}

String formatSize(int bytes) {
  if (bytes >= 1 << 30) return '${(bytes / (1 << 30)).toStringAsFixed(1)} GB';
  if (bytes >= 1 << 20) return '${(bytes / (1 << 20)).toStringAsFixed(1)} MB';
  return '${(bytes / 1024).ceil()} KB';
}

/// First-page thumbnail, with a coloured title card while it renders or when
/// the PDF can't be rendered.
class CoverImage extends StatelessWidget {
  const CoverImage({super.key, required this.book, required this.cover});

  final Book book;
  final Future<File?> cover;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<File?>(
      future: cover,
      builder: (context, snapshot) {
        final file = snapshot.data;
        if (file == null) return PlaceholderCover(title: book.title);
        return Image.file(
          file,
          fit: BoxFit.cover,
          alignment: Alignment.topCenter,
          errorBuilder: (_, _, _) => PlaceholderCover(title: book.title),
        );
      },
    );
  }
}

class PlaceholderCover extends StatelessWidget {
  const PlaceholderCover({super.key, required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    final hue = (title.hashCode % 360).abs().toDouble();
    final top = HSLColor.fromAHSL(1, hue, 0.35, 0.42).toColor();
    final bottom = HSLColor.fromAHSL(1, (hue + 30) % 360, 0.40, 0.28).toColor();
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [top, bottom]),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Align(
          alignment: Alignment.bottomLeft,
          child: Text(
            title,
            maxLines: 6,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: Colors.white,
              fontFamily: serifFamily,
              fontSize: 15,
              fontWeight: FontWeight.w600,
              height: 1.25,
            ),
          ),
        ),
      ),
    );
  }
}

/// A cover with a shadow, dimmed with a cloud badge when only in Drive.
class BookCoverFrame extends StatelessWidget {
  const BookCoverFrame({super.key, required this.book, required this.cover, this.overlay});

  final Book book;
  final Future<File?> cover;
  final Widget? overlay;

  @override
  Widget build(BuildContext context) {
    return Material(
      elevation: 3,
      shadowColor: Colors.black54,
      borderRadius: BorderRadius.circular(6),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        fit: StackFit.expand,
        children: [
          Opacity(opacity: book.isLocal ? 1 : 0.6, child: CoverImage(book: book, cover: cover)),
          if (!book.isLocal && overlay == null) const Align(alignment: Alignment.topRight, child: _CloudBadge()),
          ?overlay,
        ],
      ),
    );
  }
}

class _CloudBadge extends StatelessWidget {
  const _CloudBadge();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(8),
      child: Tooltip(
        message: 'In Google Drive, not downloaded',
        child: DecoratedBox(
          decoration: const BoxDecoration(color: Color(0x73000000), shape: BoxShape.circle),
          child: const Padding(
            padding: EdgeInsets.all(6),
            child: Icon(Icons.cloud_download_outlined, size: 18, color: Colors.white),
          ),
        ),
      ),
    );
  }
}

/// Thin reading-progress bar.
class ProgressLine extends StatelessWidget {
  const ProgressLine({super.key, required this.value, this.height = 4});

  final double value;
  final double height;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ClipRRect(
      borderRadius: BorderRadius.circular(height / 2),
      child: LinearProgressIndicator(
        value: value,
        minHeight: height,
        color: scheme.primary,
        backgroundColor: scheme.surfaceContainerHighest,
      ),
    );
  }
}

/// Lists keyboard shortcuts as (keys, action) pairs.
Future<void> showShortcutsDialog(BuildContext context, List<(String, String)> shortcuts) {
  return showDialog<void>(
    context: context,
    builder: (context) {
      final theme = Theme.of(context);
      return AlertDialog(
        title: const Text('Keyboard shortcuts'),
        content: SizedBox(
          width: 420,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final (keys, action) in shortcuts)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Row(
                      children: [
                        Expanded(child: Text(action)),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                          decoration: BoxDecoration(
                            color: theme.colorScheme.surfaceContainerHighest,
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(keys, style: theme.textTheme.labelMedium),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close'))],
      );
    },
  );
}

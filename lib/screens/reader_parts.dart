import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:pdfrx/pdfrx.dart';

import '../sync/progress_record.dart';
import 'common.dart';

/// One entry of the PDF's own table of contents, flattened.
class OutlineEntry {
  const OutlineEntry(this.title, this.page, this.level);

  final String title;
  final int page;
  final int level;
}

/// The document outline with lookups by page.
class Outline {
  Outline(this.entries) : chapters = _chapters(entries);

  /// The top-level entries, or the level below when everything sits under a
  /// single entry (often the book's own title).
  static List<OutlineEntry> _chapters(List<OutlineEntry> entries) {
    var level = 0;
    while (entries.where((e) => e.level == level).length == 1 && entries.any((e) => e.level == level + 1)) {
      level++;
    }
    return entries.where((e) => e.level == level).toList();
  }

  static final empty = Outline(const []);

  final List<OutlineEntry> entries;
  final List<OutlineEntry> chapters;

  bool get isEmpty => entries.isEmpty;

  static Future<Outline> load(PdfDocument document) async {
    final entries = <OutlineEntry>[];
    void walk(List<PdfOutlineNode> nodes, int level) {
      for (final node in nodes) {
        final page = node.dest?.pageNumber;
        final title = node.title.trim();
        if (page != null && title.isNotEmpty) entries.add(OutlineEntry(title, page, level));
        walk(node.children, level + 1);
      }
    }

    try {
      walk(await document.loadOutline(), 0);
    } catch (_) {
      // A broken outline just means no contents panel.
    }
    return Outline(entries);
  }

  static OutlineEntry? _lastAtOrBefore(List<OutlineEntry> list, int page) {
    OutlineEntry? found;
    for (final e in list) {
      if (e.page <= page && (found == null || e.page >= found.page)) found = e;
    }
    return found;
  }

  /// The deepest entry that has started by [page] (e.g. "9.3 Arguments").
  OutlineEntry? sectionAt(int page) => _lastAtOrBefore(entries, page);

  /// The top-level entry that has started by [page] (e.g. "9 Functions").
  OutlineEntry? chapterAt(int page) => _lastAtOrBefore(chapters, page);

  /// First page of the next top-level entry after [page].
  int? nextChapterPage(int page) {
    int? next;
    for (final e in chapters) {
      if (e.page > page && (next == null || e.page < next)) next = e.page;
    }
    return next;
  }
}

/// Facing pages: the first page alone on the right (like a book's cover),
/// then 2–3, 4–5, …
PdfPageLayout spreadLayout(List<PdfPage> pages, PdfViewerParams params) {
  final m = params.margin;
  final rows = <List<int>>[
    if (pages.isNotEmpty) [0],
    for (var i = 1; i < pages.length; i += 2) [i, if (i + 1 < pages.length) i + 1],
  ];
  // Every row is laid out around the same centre line, as if it had two pages
  // as wide as the widest page.
  final half = pages.fold<double>(0, (w, p) => w > p.width ? w : p.width);
  final width = half * 2 + m * 3;
  final centre = width / 2;
  final rects = List<Rect>.filled(pages.length, Rect.zero);
  var y = m;
  for (final row in rows) {
    final height = row.map((i) => pages[i].height).reduce((a, b) => a > b ? a : b);
    if (row.length == 1 && row.first == 0) {
      final p = pages[0];
      rects[0] = Rect.fromLTWH(centre + m / 2, y + (height - p.height) / 2, p.width, p.height);
    } else {
      final left = pages[row[0]];
      rects[row[0]] = Rect.fromLTWH(
        centre - m / 2 - left.width,
        y + (height - left.height) / 2,
        left.width,
        left.height,
      );
      if (row.length > 1) {
        final right = pages[row[1]];
        rects[row[1]] = Rect.fromLTWH(centre + m / 2, y + (height - right.height) / 2, right.width, right.height);
      }
    }
    y += height + m;
  }
  return PdfPageLayout(pageLayouts: rects, documentSize: Size(width, y));
}

/// Zoom that shows all of [rect] in [view]. With [halveBars] (full screen) it
/// zooms in further so the empty bars beside the page are half as wide.
double frameZoom(Rect rect, Size view, double margin, {bool halveBars = false}) {
  final fit = math.min((view.width - margin * 2) / rect.width, (view.height - margin * 2) / rect.height);
  if (!halveBars) return fit;
  final bars = view.width - rect.width * fit;
  return math.max(fit, (view.width - bars / 2) / rect.width);
}

/// First page of the spread row that contains [page].
int spreadRowStart(int page) => page <= 1 ? 1 : (page.isEven ? page : page - 1);

/// Page thumbnails.
class PagesGrid extends StatelessWidget {
  const PagesGrid({
    super.key,
    required this.document,
    required this.page,
    required this.onSelect,
    this.maxExtent = 130,
    this.controller,
  });

  final PdfDocument document;
  final int page;
  final ValueChanged<int> onSelect;
  final double maxExtent;
  final ScrollController? controller;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return GridView.builder(
      controller: controller,
      padding: const EdgeInsets.all(12),
      gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: maxExtent,
        mainAxisSpacing: 12,
        crossAxisSpacing: 12,
        childAspectRatio: 0.62,
      ),
      itemCount: document.pages.length,
      itemBuilder: (context, i) {
        final number = i + 1;
        final selected = number == page;
        return InkWell(
          onTap: () => onSelect(number),
          borderRadius: BorderRadius.circular(6),
          child: Column(
            children: [
              Expanded(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: Colors.white,
                    border: Border.all(
                      color: selected ? scheme.primary : scheme.outlineVariant,
                      width: selected ? 3 : 1,
                    ),
                  ),
                  child: PdfPageView(document: document, pageNumber: number, maximumDpi: 48),
                ),
              ),
              const SizedBox(height: 4),
              Text(
                '$number',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.normal,
                  color: selected ? scheme.primary : null,
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// What the resume prompt needs to describe the other device's position.
class ResumeOffer {
  const ResumeOffer({required this.record, required this.currentPage, this.section, this.chapter});

  final ProgressRecord record;
  final int currentPage;
  final String? section;

  /// Top-level outline entry at the other device's page.
  final String? chapter;

  String get where => ['Page ${record.page}', ?section].join(' · ');
}

/// Desktop: a corner notification that doesn't block reading.
class ResumeToast extends StatelessWidget {
  const ResumeToast({
    super.key,
    required this.offer,
    required this.alwaysJump,
    required this.onAlwaysJump,
    required this.onJump,
    required this.onStay,
  });

  final ResumeOffer offer;
  final bool alwaysJump;
  final ValueChanged<bool> onAlwaysJump;
  final VoidCallback onJump;
  final VoidCallback onStay;

  @override
  Widget build(BuildContext context) {
    final record = offer.record;
    final theme = Theme.of(context);
    const muted = Color(0xFFA9B8B4);
    return Material(
      color: const Color(0xFF182024),
      elevation: 12,
      borderRadius: BorderRadius.circular(16),
      child: SizedBox(
        width: 420,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 16, 10, 12),
          child: DefaultTextStyle.merge(
            style: const TextStyle(color: Color(0xFFECF1EF)),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        color: const Color(0xFF1F3B38),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: const Icon(Icons.devices_outlined, color: Color(0xFF4DB6AC), size: 22),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Newer position from ${record.device}',
                            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            '${offer.where} · ${timeAgo(record.updated)}',
                            style: const TextStyle(fontSize: 14, color: muted),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      tooltip: 'Stay here',
                      icon: const Icon(Icons.close, size: 18, color: muted),
                      onPressed: onStay,
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    FilledButton(onPressed: onJump, child: Text('Jump to page ${record.page}')),
                    const SizedBox(width: 6),
                    TextButton(
                      style: TextButton.styleFrom(foregroundColor: const Color(0xFFECF1EF)),
                      onPressed: onStay,
                      child: const Text('Stay here'),
                    ),
                    const Spacer(),
                    Text('J to jump', style: theme.textTheme.bodySmall?.copyWith(color: muted)),
                    const SizedBox(width: 8),
                  ],
                ),
                Row(
                  children: [
                    Checkbox(
                      value: alwaysJump,
                      onChanged: (v) => onAlwaysJump(v ?? false),
                      side: const BorderSide(color: muted),
                    ),
                    const Flexible(
                      child: Text('Always jump without asking', style: TextStyle(fontSize: 13, color: muted)),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Bookmarked pages with the section each falls in.
class BookmarksList extends StatelessWidget {
  const BookmarksList({
    super.key,
    required this.pages,
    required this.outline,
    required this.page,
    required this.onSelect,
    required this.onRemove,
    this.emptyText = 'No bookmarks yet. Tap the bookmark button to save a page.',
  });

  final List<int> pages;
  final Outline outline;
  final int page;
  final ValueChanged<int> onSelect;
  final ValueChanged<int> onRemove;
  final String emptyText;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (pages.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            emptyText,
            textAlign: TextAlign.center,
            style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
          ),
        ),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 4),
      itemCount: pages.length,
      itemBuilder: (context, i) {
        final p = pages[i];
        final section = outline.sectionAt(p)?.title;
        return ListTile(
          dense: true,
          selected: p == page,
          selectedTileColor: theme.colorScheme.secondaryContainer,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          leading: Icon(Icons.bookmark, color: theme.colorScheme.primary, size: 20),
          title: Text('Page $p'),
          subtitle: section == null ? null : Text(section, maxLines: 1, overflow: TextOverflow.ellipsis),
          trailing: IconButton(
            tooltip: 'Remove bookmark',
            icon: const Icon(Icons.close, size: 18),
            onPressed: () => onRemove(p),
          ),
          onTap: () => onSelect(p),
        );
      },
    );
  }
}

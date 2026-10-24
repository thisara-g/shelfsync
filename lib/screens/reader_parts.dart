import 'package:flutter/material.dart';
import 'package:pdfrx/pdfrx.dart';

import '../services/library_store.dart';
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
  Outline(this.entries) : chapters = entries.where((e) => e.level == 0).toList();

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
      rects[row[0]] = Rect.fromLTWH(centre - m / 2 - left.width, y + (height - left.height) / 2, left.width, left.height);
      if (row.length > 1) {
        final right = pages[row[1]];
        rects[row[1]] = Rect.fromLTWH(centre + m / 2, y + (height - right.height) / 2, right.width, right.height);
      }
    }
    y += height + m;
  }
  return PdfPageLayout(pageLayouts: rects, documentSize: Size(width, y));
}

/// First page of the spread row that contains [page].
int spreadRowStart(int page) => page <= 1 ? 1 : (page.isEven ? page : page - 1);

/// Table of contents with the current section highlighted.
class ContentsList extends StatelessWidget {
  const ContentsList({super.key, required this.outline, required this.page, required this.onSelect, this.controller});

  final Outline outline;
  final int page;
  final ValueChanged<int> onSelect;
  final ScrollController? controller;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final current = outline.sectionAt(page);
    return ListView.builder(
      controller: controller,
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 8),
      itemCount: outline.entries.length,
      itemBuilder: (context, i) {
        final e = outline.entries[i];
        final selected = identical(e, current);
        return ListTile(
          dense: true,
          selected: selected,
          selectedTileColor: theme.colorScheme.secondaryContainer,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          contentPadding: EdgeInsets.only(left: 12.0 + 16 * e.level.clamp(0, 4), right: 12),
          title: Text(
            e.title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontWeight: e.level == 0 ? FontWeight.w600 : FontWeight.normal),
          ),
          trailing: Text('${e.page}', style: theme.textTheme.bodySmall),
          onTap: () => onSelect(e.page),
        );
      },
    );
  }
}

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
                    border: Border.all(color: selected ? scheme.primary : scheme.outlineVariant, width: selected ? 3 : 1),
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

/// Light / Sepia / Dark chooser.
class PageColourPicker extends StatelessWidget {
  const PageColourPicker({super.key, required this.value, required this.onChanged});

  final ReaderTheme value;
  final ValueChanged<ReaderTheme> onChanged;

  static const _swatches = {
    ReaderTheme.light: (Color(0xFFFFFFFF), Color(0xFF1D2321), 'Light'),
    ReaderTheme.sepia: (Color(0xFFF4ECD8), Color(0xFF5B4636), 'Sepia'),
    ReaderTheme.dark: (Color(0xFF1B1B1D), Color(0xFFDDDDDD), 'Dark'),
  };

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    return Wrap(
      spacing: 8,
      children: [
        for (final MapEntry(key: theme, value: (bg, fg, label)) in _swatches.entries)
          Semantics(
            selected: theme == value,
            button: true,
            child: Material(
              color: bg,
              shape: StadiumBorder(
                side: BorderSide(color: theme == value ? accent : Colors.black26, width: theme == value ? 2.5 : 1),
              ),
              child: InkWell(
                customBorder: const StadiumBorder(),
                onTap: () => onChanged(theme),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
                  child: Text(label, style: TextStyle(color: fg, fontWeight: FontWeight.w600)),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// What the resume prompt needs to describe the other device's position.
class ResumeOffer {
  const ResumeOffer({required this.record, required this.currentPage, this.section});

  final ProgressRecord record;
  final int currentPage;
  final String? section;

  String get where => [
        'Page ${record.page}',
        ?section,
      ].join(' · ');
}

/// Tablet: a bottom sheet over a dimmed page.
class ResumeSheet extends StatelessWidget {
  const ResumeSheet({
    super.key,
    required this.offer,
    required this.document,
    required this.alwaysJump,
    required this.onAlwaysJump,
    required this.onJump,
    required this.onStay,
  });

  final ResumeOffer offer;
  final PdfDocument? document;
  final bool alwaysJump;
  final ValueChanged<bool> onAlwaysJump;
  final VoidCallback onJump;
  final VoidCallback onStay;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final record = offer.record;
    final doc = document;
    return Stack(
      children: [
        const Positioned.fill(child: ModalBarrier(color: Color(0x61000000), dismissible: false)),
        Align(
          alignment: Alignment.bottomCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720),
            child: Card(
              margin: const EdgeInsets.all(16),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
              child: SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          if (doc != null && record.page >= 1 && record.page <= doc.pages.length) ...[
                            Container(
                              width: 96,
                              height: 130,
                              decoration: BoxDecoration(
                                color: Colors.white,
                                border: Border.all(color: theme.colorScheme.outlineVariant),
                                borderRadius: BorderRadius.circular(6),
                              ),
                              clipBehavior: Clip.antiAlias,
                              child: PdfPageView(document: doc, pageNumber: record.page, maximumDpi: 72),
                            ),
                            const SizedBox(width: 20),
                          ],
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Icon(Icons.devices_outlined, size: 18, color: theme.colorScheme.primary),
                                    const SizedBox(width: 8),
                                    Flexible(
                                      child: Text(
                                        'From ${record.device} · ${timeAgo(record.updated)}',
                                        style: theme.textTheme.labelLarge?.copyWith(color: theme.colorScheme.primary),
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 8),
                                Text(
                                  'Pick up where you left off?',
                                  style: theme.textTheme.headlineSmall?.copyWith(fontFamily: serifFamily, fontWeight: FontWeight.w600),
                                ),
                                const SizedBox(height: 6),
                                Text(offer.where, style: theme.textTheme.bodyLarge?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
                              ],
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 22),
                      Row(
                        children: [
                          Expanded(
                            child: SizedBox(
                              height: 54,
                              child: FilledButton(onPressed: onJump, child: Text('Jump to page ${record.page}')),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: SizedBox(
                              height: 54,
                              child: OutlinedButton(onPressed: onStay, child: Text('Stay on page ${offer.currentPage}')),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      CheckboxListTile(
                        contentPadding: EdgeInsets.zero,
                        controlAffinity: ListTileControlAffinity.leading,
                        value: alwaysJump,
                        onChanged: (v) => onAlwaysJump(v ?? false),
                        title: const Text('Always jump to my latest position without asking'),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
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
                      decoration: BoxDecoration(color: const Color(0xFF1F3B38), borderRadius: BorderRadius.circular(12)),
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
                          Text('${offer.where} · ${timeAgo(record.updated)}', style: const TextStyle(fontSize: 14, color: muted)),
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

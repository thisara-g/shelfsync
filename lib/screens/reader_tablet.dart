import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pdfrx/pdfrx.dart';

import '../models/book.dart';
import '../services/library_store.dart';
import 'common.dart';
import 'reader_parts.dart';
import 'tablet_ui.dart';

/// Frosted dark glass: the reader's floating bars.
class ReaderGlass extends StatelessWidget {
  const ReaderGlass({super.key, required this.child, required this.radius, this.padding = EdgeInsets.zero});

  final Widget child;
  final double radius;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    final shape = BorderRadius.circular(radius);
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: shape,
        boxShadow: const [
          BoxShadow(color: Color(0x99000000), blurRadius: 40, offset: Offset(0, 18), spreadRadius: -16),
        ],
      ),
      child: ClipRRect(
        borderRadius: shape,
        child: BackdropFilter(
          filter: ui.ImageFilter.blur(sigmaX: 22, sigmaY: 22),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: const Color(0xD6121719),
              borderRadius: shape,
              border: Border.all(color: const Color(0x14FFFFFF)),
            ),
            child: Padding(padding: padding, child: child),
          ),
        ),
      ),
    );
  }
}

/// Page slider with a dot where each chapter starts; dragging close to a
/// dot snaps onto that chapter's first page. While dragging, a preview of the page
/// under the thumb floats above it.
class TabletPageSlider extends StatefulWidget {
  const TabletPageSlider({
    super.key,
    required this.page,
    required this.count,
    required this.chapters,
    required this.document,
    required this.sectionAt,
    required this.onChanged,
    required this.onChangeEnd,
  });

  final int page;
  final int count;
  final List<int> chapters;
  final PdfDocument? document;
  final String? Function(int page) sectionAt;
  final ValueChanged<int> onChanged;
  final ValueChanged<int> onChangeEnd;

  @override
  State<TabletPageSlider> createState() => _TabletPageSliderState();
}

class _TabletPageSliderState extends State<TabletPageSlider> {
  int? _drag;

  int _pageAt(double dx, double width) {
    final f = (dx / width).clamp(0.0, 1.0);
    return 1 + (f * (widget.count - 1)).round();
  }

  /// The chapter start the thumb has snapped onto, if any.
  int? _snapped;

  /// How close (in logical pixels) the finger must come to a chapter dot to
  /// snap onto it. Small, so pages near a chapter start stay reachable.
  static const _snapDistance = 8.0;

  void _move(double dx, double width) {
    var page = _pageAt(dx, width);
    int? snap;
    var best = _snapDistance;
    for (final c in widget.chapters) {
      final d = (dx - (c - 1) / (widget.count - 1) * width).abs();
      if (d <= best) {
        best = d;
        snap = c;
      }
    }
    if (snap != null) page = snap;
    if (snap != null && snap != _snapped) HapticFeedback.selectionClick();
    _snapped = snap;
    if (page == _drag) return;
    setState(() => _drag = page);
    widget.onChanged(page);
  }

  void _end() {
    final page = _drag;
    setState(() {
      _drag = null;
      _snapped = null;
    });
    if (page != null) widget.onChangeEnd(page);
  }

  @override
  Widget build(BuildContext context) {
    final count = widget.count;
    if (count < 2) return const SizedBox(height: 36);
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        double x(num page) => (page - 1) / (count - 1) * width;
        final shown = _drag ?? widget.page;
        final thumb = x(shown);
        final doc = widget.document;
        final section = widget.sectionAt(shown);
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onHorizontalDragStart: (d) => _move(d.localPosition.dx, width),
          onHorizontalDragUpdate: (d) => _move(d.localPosition.dx, width),
          onHorizontalDragEnd: (_) => _end(),
          onHorizontalDragCancel: _end,
          onTapDown: (d) => _move(d.localPosition.dx, width),
          onTapUp: (_) => _end(),
          child: SizedBox(
            height: 36,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                Positioned(
                  left: 0,
                  right: 0,
                  top: 16,
                  height: 4,
                  child: DecoratedBox(
                    decoration: BoxDecoration(color: const Color(0x24FFFFFF), borderRadius: BorderRadius.circular(2)),
                  ),
                ),
                Positioned(
                  left: 0,
                  width: thumb,
                  top: 16,
                  height: 4,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: const LinearGradient(colors: [Color(0xFF14B8A6), TabletColors.accent]),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                // Chapter starts: small dots on the track, dark on the
                // filled part so they stay visible there too.
                for (final c in widget.chapters)
                  if (c > 1)
                    Positioned(
                      left: x(c) - 2,
                      top: 16,
                      width: 4,
                      height: 4,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: c <= shown ? const Color(0x5904201C) : const Color(0x66FFFFFF),
                          shape: BoxShape.circle,
                        ),
                      ),
                    ),
                // The chapter start the thumb just snapped onto glows.
                if (_snapped != null && _drag != null)
                  Positioned(
                    left: thumb - 20,
                    top: -2,
                    width: 40,
                    height: 40,
                    child: const IgnorePointer(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          boxShadow: [BoxShadow(color: Color(0x805EEAD4), blurRadius: 16, spreadRadius: 2)],
                        ),
                      ),
                    ),
                  ),
                Positioned(
                  left: thumb - 12,
                  top: 6,
                  child: AnimatedScale(
                    duration: const Duration(milliseconds: 120),
                    scale: _drag == null ? 1 : 1.15,
                    child: Container(
                      width: 24,
                      height: 24,
                      decoration: const BoxDecoration(
                        color: Colors.white,
                        shape: BoxShape.circle,
                        boxShadow: [
                          BoxShadow(color: Color(0x475EEAD4), spreadRadius: 6),
                          BoxShadow(color: Color(0x80000000), blurRadius: 10, offset: Offset(0, 4)),
                        ],
                      ),
                    ),
                  ),
                ),
                if (_drag != null)
                  Positioned(
                    left: thumb,
                    bottom: 50,
                    child: FractionalTranslation(
                      translation: const Offset(-0.5, 0),
                      child: IgnorePointer(
                        child: _Preview(document: doc, page: shown, section: section),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _Preview extends StatelessWidget {
  const _Preview({required this.document, required this.page, required this.section});

  final PdfDocument? document;
  final int page;
  final String? section;

  @override
  Widget build(BuildContext context) {
    final doc = document;
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: const Color(0xFF1B2326),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0x1AFFFFFF)),
        boxShadow: const [
          BoxShadow(color: Color(0xB3000000), blurRadius: 30, offset: Offset(0, 16), spreadRadius: -10),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 72,
            height: 100,
            decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(3)),
            clipBehavior: Clip.antiAlias,
            child: doc == null || page > doc.pages.length
                ? null
                : PdfPageView(key: ValueKey(page), document: doc, pageNumber: page, maximumDpi: 36),
          ),
          const SizedBox(height: 8),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 180),
            child: Text(
              section == null ? 'p. $page' : 'p. $page · $section',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: TabletColors.text, fontSize: 13, fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }
}

/// Paper / Sepia / Night: each with an "Aa" in its colours.
class ReaderThemeSegment extends StatelessWidget {
  const ReaderThemeSegment({super.key, required this.value, required this.onChanged});

  final ReaderTheme value;
  final ValueChanged<ReaderTheme> onChanged;

  static const _themes = [
    (ReaderTheme.light, 'Paper', Color(0xFFFBFAF6), Color(0xFF23201C)),
    (ReaderTheme.sepia, 'Sepia', Color(0xFFF3E7CF), Color(0xFF5B4636)),
    (ReaderTheme.dark, 'Night', Color(0xFF121619), Color(0xFFD6DDDA)),
  ];

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(5),
      decoration: BoxDecoration(color: const Color(0x0FFFFFFF), borderRadius: BorderRadius.circular(24)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final (theme, name, paper, ink) in _themes)
            Semantics(
              selected: theme == value,
              button: true,
              label: 'Page colour $name',
              child: Padding(
                padding: const EdgeInsets.only(right: 6),
                child: Material(
                  color: theme == value ? const Color(0x24FFFFFF) : Colors.transparent,
                  shape: const StadiumBorder(),
                  child: InkWell(
                    customBorder: const StadiumBorder(),
                    onTap: () => onChanged(theme),
                    child: Container(
                      height: 40,
                      padding: const EdgeInsets.only(left: 8, right: 14),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Container(
                            width: 26,
                            height: 26,
                            alignment: Alignment.center,
                            decoration: BoxDecoration(
                              color: paper,
                              shape: BoxShape.circle,
                              border: Border.all(color: const Color(0x2EFFFFFF)),
                            ),
                            child: Text(
                              'Aa',
                              style: TextStyle(
                                fontFamily: serifFamily,
                                fontSize: 12,
                                fontWeight: FontWeight.w700,
                                color: ink,
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            name,
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                              color: theme == value ? Colors.white : TabletColors.muted,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

// --- Contents drawer ------------------------------------------------------------

/// Slides in from the right over the dimmed page: Contents, Pages and
/// Bookmarks. Picking an entry closes it and goes there.
Future<void> showTabletContents(
  BuildContext context, {
  required Book book,
  required Future<File?> cover,
  required Outline outline,
  required int page,
  required int pageCount,
  required PdfDocument document,
  required LibraryStore store,
  required ValueChanged<int> onGo,
  required ValueChanged<int> onRemoveBookmark,
  int initialTab = 0,
}) {
  return showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'Close contents',
    barrierColor: const Color(0x9406090A),
    transitionDuration: const Duration(milliseconds: 260),
    transitionBuilder: (context, animation, _, child) => SlideTransition(
      position: Tween(
        begin: const Offset(1, 0),
        end: Offset.zero,
      ).animate(CurvedAnimation(parent: animation, curve: Curves.easeOutCubic)),
      child: child,
    ),
    pageBuilder: (context, _, _) => Theme(
      data: tabletTheme(),
      child: Align(
        alignment: Alignment.centerRight,
        child: _ContentsDrawer(
          book: book,
          cover: cover,
          outline: outline,
          page: page,
          pageCount: pageCount,
          document: document,
          store: store,
          initialTab: outline.isEmpty && initialTab == 0 ? 1 : initialTab,
          onGo: (p) {
            Navigator.pop(context);
            onGo(p);
          },
          onRemoveBookmark: onRemoveBookmark,
        ),
      ),
    ),
  );
}

class _ContentsDrawer extends StatefulWidget {
  const _ContentsDrawer({
    required this.book,
    required this.cover,
    required this.outline,
    required this.page,
    required this.pageCount,
    required this.document,
    required this.store,
    required this.initialTab,
    required this.onGo,
    required this.onRemoveBookmark,
  });

  final Book book;
  final Future<File?> cover;
  final Outline outline;
  final int page;
  final int pageCount;
  final PdfDocument document;
  final LibraryStore store;
  final int initialTab;
  final ValueChanged<int> onGo;
  final ValueChanged<int> onRemoveBookmark;

  @override
  State<_ContentsDrawer> createState() => _ContentsDrawerState();
}

class _ContentsDrawerState extends State<_ContentsDrawer> {
  late var _tab = widget.initialTab;

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final padding = MediaQuery.paddingOf(context);
    final page = widget.page, count = widget.pageCount;
    final left = math.max(0, count - page);
    final read = count > 1 ? ((page - 1) / (count - 1) * 100).round() : 0;
    return Material(
      color: TabletColors.sheet,
      elevation: 24,
      shadowColor: Colors.black,
      child: Container(
        width: math.min(540, size.width - 60),
        height: double.infinity,
        decoration: const BoxDecoration(
          border: Border(left: BorderSide(color: TabletColors.line)),
        ),
        padding: EdgeInsets.fromLTRB(24, padding.top + 24, 24, 0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                MiniCover(book: widget.book, cover: widget.cover, width: 56, height: 80),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        widget.book.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontFamily: serifFamily,
                          fontSize: 21,
                          fontWeight: FontWeight.w600,
                          height: 1.2,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        '$read% read · $left page${left == 1 ? '' : 's'} to go',
                        style: const TextStyle(fontSize: 14, color: TabletColors.dim),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                GlassIconButton(
                  icon: Icons.close_rounded,
                  tooltip: 'Close',
                  border: false,
                  background: const Color(0x12FFFFFF),
                  onPressed: () => Navigator.pop(context),
                ),
              ],
            ),
            const SizedBox(height: 22),
            ListenableBuilder(
              listenable: widget.store,
              builder: (context, _) => _Tabs(
                index: _tab,
                bookmarks: widget.store.bookmarksFor(widget.book.id).length,
                onChanged: (i) => setState(() => _tab = i),
              ),
            ),
            const SizedBox(height: 14),
            Expanded(
              child: switch (_tab) {
                0 => _ChapterList(outline: widget.outline, page: page, pageCount: count, onGo: widget.onGo),
                1 => PagesGrid(document: widget.document, page: page, maxExtent: 150, onSelect: widget.onGo),
                _ => ListenableBuilder(
                  listenable: widget.store,
                  builder: (context, _) => BookmarksList(
                    pages: widget.store.bookmarksFor(widget.book.id),
                    outline: widget.outline,
                    page: page,
                    onSelect: widget.onGo,
                    onRemove: widget.onRemoveBookmark,
                  ),
                ),
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _Tabs extends StatelessWidget {
  const _Tabs({required this.index, required this.bookmarks, required this.onChanged});

  final int index;
  final int bookmarks;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    Widget tab(int i, String label, {int? badge}) {
      final selected = i == index;
      return Expanded(
        child: Semantics(
          selected: selected,
          button: true,
          child: Material(
            color: selected ? TabletColors.text : Colors.transparent,
            shape: const StadiumBorder(),
            child: InkWell(
              customBorder: const StadiumBorder(),
              onTap: () => onChanged(i),
              child: SizedBox(
                height: 44,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      label,
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: selected ? FontWeight.w700 : FontWeight.w600,
                        color: selected ? TabletColors.background : TabletColors.muted,
                      ),
                    ),
                    if (badge != null && badge > 0) ...[
                      const SizedBox(width: 8),
                      Container(
                        constraints: const BoxConstraints(minWidth: 22),
                        height: 22,
                        padding: const EdgeInsets.symmetric(horizontal: 6),
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: selected ? const Color(0x2E0C1012) : const Color(0x2E5EEAD4),
                          borderRadius: BorderRadius.circular(11),
                        ),
                        child: Text(
                          '$badge',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                            color: selected ? TabletColors.background : TabletColors.accent,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.all(5),
      decoration: BoxDecoration(color: const Color(0x0FFFFFFF), borderRadius: BorderRadius.circular(26)),
      child: Row(
        children: [
          tab(0, 'Contents'),
          tab(1, 'Pages'),
          tab(2, 'Bookmarks', badge: bookmarks),
        ],
      ),
    );
  }
}

/// Chapters, with the one you're in opened up: how far into it you are and
/// its sections. Chapters already behind you are ticked.
class _ChapterList extends StatefulWidget {
  const _ChapterList({required this.outline, required this.page, required this.pageCount, required this.onGo});

  final Outline outline;
  final int page;
  final int pageCount;
  final ValueChanged<int> onGo;

  @override
  State<_ChapterList> createState() => _ChapterListState();
}

class _ChapterListState extends State<_ChapterList> {
  final _current = GlobalKey();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final target = _current.currentContext;
      if (target != null) Scrollable.ensureVisible(target, alignment: 0.3);
    });
  }

  /// "9 · Functions" → ("9", "Functions"); "Preface" → (null, "Preface").
  static (String?, String) _split(String title) {
    final match = RegExp(r'^(?:Chapter\s+)?(\d+|[IVXLC]+)[.:·\s]+(.+)$', caseSensitive: false).firstMatch(title);
    return match == null ? (null, title) : (match.group(1), match.group(2)!.trim());
  }

  @override
  Widget build(BuildContext context) {
    final outline = widget.outline;
    final chapters = outline.chapters;
    if (chapters.isEmpty) {
      return const Center(
        child: Text('This PDF has no table of contents.', style: TextStyle(color: TabletColors.dim, fontSize: 15)),
      );
    }
    final page = widget.page;
    final current = outline.chapterAt(page);
    return ListView(
      padding: const EdgeInsets.only(bottom: 24),
      children: [
        for (final (i, chapter) in chapters.indexed)
          chapter == current
              ? _currentCard(chapter, i)
              : _row(chapter, i, done: current != null && chapter.page < current.page),
      ],
    );
  }

  Widget _row(OutlineEntry chapter, int index, {required bool done}) {
    final (number, title) = _split(chapter.title);
    return InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: () => widget.onGo(chapter.page),
      child: Container(
        constraints: const BoxConstraints(minHeight: 56),
        padding: const EdgeInsets.only(left: 24, right: 20),
        child: Row(
          children: [
            SizedBox(
              width: 42,
              child: Text(
                number ?? '',
                style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: TabletColors.faint),
              ),
            ),
            Expanded(
              child: Text(
                title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 18, color: done ? const Color(0xFF7E908B) : TabletColors.text),
              ),
            ),
            if (done) const Icon(Icons.check_rounded, size: 18, color: TabletColors.accent),
            SizedBox(
              width: 44,
              child: Text(
                '${chapter.page}',
                textAlign: TextAlign.right,
                style: const TextStyle(fontSize: 15, color: TabletColors.faint),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _currentCard(OutlineEntry chapter, int index) {
    final outline = widget.outline;
    final page = widget.page;
    final (number, title) = _split(chapter.title);
    final end = outline.nextChapterPage(chapter.page) ?? widget.pageCount + 1;
    final through = ((page - chapter.page) / math.max(1, end - chapter.page)).clamp(0.0, 1.0);

    // Its sections: the next level down, until the next chapter.
    final start = outline.entries.indexOf(chapter);
    final sections = <OutlineEntry>[];
    for (final e in outline.entries.skip(start + 1)) {
      if (e.level <= chapter.level) break;
      if (e.level == chapter.level + 1) sections.add(e);
    }
    OutlineEntry? here;
    for (final s in sections) {
      if (s.page <= page) here = s;
    }

    return Container(
      key: _current,
      margin: const EdgeInsets.symmetric(vertical: 4),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0x332DD4BF), Color(0x0F2DD4BF)],
        ),
        border: Border.all(color: const Color(0x4D5EEAD4)),
      ),
      child: Stack(
        children: [
          Positioned(
            left: 0,
            top: 18,
            bottom: 18,
            width: 4,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: TabletColors.accent,
                borderRadius: BorderRadius.horizontal(right: Radius.circular(3)),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 18, 20, 18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                InkWell(
                  onTap: () => widget.onGo(chapter.page),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.baseline,
                    textBaseline: TextBaseline.alphabetic,
                    children: [
                      SizedBox(
                        width: 42,
                        child: Text(
                          number ?? '',
                          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: TabletColors.accent),
                        ),
                      ),
                      Expanded(
                        child: Text(title, style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w700)),
                      ),
                      Text('${chapter.page}', style: const TextStyle(fontSize: 15, color: TabletColors.muted)),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                Padding(
                  padding: const EdgeInsets.only(left: 42),
                  child: Row(
                    children: [
                      Expanded(child: TabletProgress(value: through, height: 4)),
                      const SizedBox(width: 12),
                      Text(
                        'You’re on p. $page',
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: TabletColors.accentLight,
                        ),
                      ),
                    ],
                  ),
                ),
                if (sections.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  for (final s in sections)
                    InkWell(
                      onTap: () => widget.onGo(s.page),
                      child: Padding(
                        padding: const EdgeInsets.only(left: 42, top: 6, bottom: 6),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                s.title,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 15,
                                  fontWeight: s == here ? FontWeight.w600 : FontWeight.normal,
                                  color: s == here ? Colors.white : TabletColors.soft,
                                ),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Text(
                              '${s.page}',
                              style: TextStyle(
                                fontSize: 15,
                                fontWeight: s == here ? FontWeight.w600 : FontWeight.normal,
                                color: s == here ? TabletColors.accentLight : TabletColors.dim,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// --- Resume -------------------------------------------------------------------

/// Another device is further on (or back): both pages side by side, the
/// newer one highlighted.
class TabletResumeCard extends StatelessWidget {
  const TabletResumeCard({
    super.key,
    required this.offer,
    required this.document,
    required this.localChapter,
    required this.localWhen,
    required this.alwaysJump,
    required this.onAlwaysJump,
    required this.onJump,
    required this.onStay,
  });

  final ResumeOffer offer;
  final PdfDocument? document;
  final String? localChapter;
  final DateTime? localWhen;
  final bool alwaysJump;
  final ValueChanged<bool> onAlwaysJump;
  final VoidCallback onJump;
  final VoidCallback onStay;

  @override
  Widget build(BuildContext context) {
    final record = offer.record;
    final here = offer.currentPage;
    final diff = (record.page - here).abs();
    final ahead = record.page > here;
    final other = Platform.isAndroid ? 'your PC' : 'your tablet';
    final width = MediaQuery.sizeOf(context).width;
    final thumb = width < 700 ? 80.0 : 100.0;
    return Stack(
      children: [
        Positioned.fill(
          child: BackdropFilter(
            filter: ui.ImageFilter.blur(sigmaX: 5, sigmaY: 5),
            child: const DecoratedBox(
              decoration: BoxDecoration(
                gradient: RadialGradient(radius: 0.9, colors: [Color(0x8C0A0E10), Color(0xD106090A)]),
              ),
            ),
          ),
        ),
        Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 660),
              child: Material(
                color: TabletColors.sheet,
                elevation: 30,
                shadowColor: Colors.black,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(34),
                  side: const BorderSide(color: Color(0x14FFFFFF)),
                ),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(36, 36, 36, 28),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Center(
                        child: Container(
                          height: 36,
                          padding: const EdgeInsets.symmetric(horizontal: 14),
                          decoration: BoxDecoration(
                            color: const Color(0x1F5EEAD4),
                            borderRadius: BorderRadius.circular(18),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(Icons.sync_rounded, size: 18, color: TabletColors.accent),
                              const SizedBox(width: 10),
                              Flexible(
                                child: Text(
                                  'Synced from ${record.device}',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontSize: 14,
                                    fontWeight: FontWeight.w700,
                                    color: TabletColors.accent,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        ahead ? 'You read further on $other' : 'You went back on $other',
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          fontFamily: serifFamily,
                          fontSize: 34,
                          fontWeight: FontWeight.w600,
                          height: 1.15,
                        ),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        '$diff page${diff == 1 ? '' : 's'} ${ahead ? 'ahead' : 'back'}, ${timeAgo(record.updated)}. '
                        'Where do you want to be?',
                        textAlign: TextAlign.center,
                        style: const TextStyle(fontSize: 17, color: Color(0xFFA9B8B4)),
                      ),
                      const SizedBox(height: 26),
                      Row(
                        children: [
                          Expanded(
                            child: _Side(
                              document: document,
                              page: here,
                              thumb: thumb,
                              label: Platform.isAndroid ? 'This tablet' : 'This device',
                              chapter: localChapter == null ? null : chapterLine(localChapter!, short: true),
                              when: localWhen == null ? null : timeAgo(localWhen!),
                              latest: false,
                            ),
                          ),
                          const Padding(
                            padding: EdgeInsets.symmetric(horizontal: 14),
                            child: Icon(Icons.arrow_forward_rounded, color: TabletColors.accent, size: 28),
                          ),
                          Expanded(
                            child: _Side(
                              document: document,
                              page: record.page,
                              thumb: thumb,
                              label: record.device,
                              chapter: offer.chapter == null ? null : chapterLine(offer.chapter!, short: true),
                              when: timeAgo(record.updated),
                              latest: true,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 26),
                      TealButton(label: 'Jump to page ${record.page}', height: 62, fontSize: 19, onPressed: onJump),
                      const SizedBox(height: 10),
                      SizedBox(
                        height: 56,
                        child: TextButton(
                          style: TextButton.styleFrom(
                            foregroundColor: TabletColors.soft,
                            shape: const StadiumBorder(),
                            textStyle: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600, fontFamily: uiFamily),
                          ),
                          onPressed: onStay,
                          child: Text('Stay on page $here'),
                        ),
                      ),
                      const SizedBox(height: 18),
                      const Divider(height: 1, color: TabletColors.line),
                      const SizedBox(height: 10),
                      Row(
                        children: [
                          const Expanded(
                            child: Text(
                              'Always jump to my latest page without asking',
                              style: TextStyle(fontSize: 15, color: Color(0xFFA9B8B4)),
                            ),
                          ),
                          Switch(
                            value: alwaysJump,
                            onChanged: onAlwaysJump,
                            activeThumbColor: TabletColors.onAccent,
                            activeTrackColor: TabletColors.accent,
                          ),
                        ],
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

class _Side extends StatelessWidget {
  const _Side({
    required this.document,
    required this.page,
    required this.thumb,
    required this.label,
    required this.chapter,
    required this.when,
    required this.latest,
  });

  final PdfDocument? document;
  final int page;
  final double thumb;
  final String label;
  final String? chapter;
  final String? when;
  final bool latest;

  @override
  Widget build(BuildContext context) {
    final doc = document;
    final card = Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(24),
        color: latest ? null : const Color(0x0AFFFFFF),
        gradient: latest
            ? const LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [Color(0x382DD4BF), Color(0x0D2DD4BF)],
              )
            : null,
        border: Border.all(color: latest ? const Color(0x8C5EEAD4) : const Color(0x14FFFFFF), width: latest ? 1.5 : 1),
        boxShadow: [if (latest) const BoxShadow(color: Color(0x145EEAD4), spreadRadius: 6)],
      ),
      child: Row(
        children: [
          Container(
            width: thumb,
            height: thumb * 1.39,
            decoration: BoxDecoration(
              color: const Color(0xFFFBFAF6),
              borderRadius: BorderRadius.circular(4),
              boxShadow: const [
                BoxShadow(color: Color(0x99000000), blurRadius: 24, offset: Offset(0, 12), spreadRadius: -10),
              ],
            ),
            clipBehavior: Clip.antiAlias,
            child: doc == null || page < 1 || page > doc.pages.length
                ? null
                : PdfPageView(document: doc, pageNumber: page, maximumDpi: 72),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    color: latest ? TabletColors.accent : TabletColors.dim,
                  ),
                ),
                const SizedBox(height: 6),
                Text('p. $page', style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w700)),
                const SizedBox(height: 6),
                Text(
                  [?chapter, ?when].join('\n'),
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 14, color: latest ? TabletColors.muted : TabletColors.dim),
                ),
              ],
            ),
          ),
        ],
      ),
    );
    if (!latest) return Opacity(opacity: 0.75, child: card);
    return Stack(
      clipBehavior: Clip.none,
      children: [
        card,
        Positioned(
          top: -12,
          right: 16,
          child: Container(
            height: 24,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            decoration: BoxDecoration(color: TabletColors.accent, borderRadius: BorderRadius.circular(12)),
            child: const Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'LATEST',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.5,
                    color: TabletColors.onAccent,
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

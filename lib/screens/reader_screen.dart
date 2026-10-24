import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pdfrx/pdfrx.dart';

import '../models/book.dart';
import '../services/library_store.dart';
import '../services/page_image_regions.dart';
import '../sync/library_sync.dart';
import '../sync/progress_record.dart';
import 'common.dart';
import 'reader_parts.dart';

class ReaderScreen extends StatefulWidget {
  const ReaderScreen({super.key, required this.store, required this.librarySync, required this.book});

  final LibraryStore store;
  final LibrarySync librarySync;
  final Book book;

  @override
  State<ReaderScreen> createState() => _ReaderScreenState();
}

class _ReaderScreenState extends State<ReaderScreen> {
  final _controller = PdfViewerController();
  final _focusNode = FocusNode();
  final _pageField = TextEditingController();
  final _pageFieldFocus = FocusNode();
  Timer? _saveTimer;
  Timer? _hideTimer;
  int? _page;
  int? _pageCount;

  // Latest exact position, captured on every view change. The viewer's state is
  // disposed before ours, so it can't be read from the controller in dispose().
  Offset? _pageOffset;
  double? _zoom;

  PdfDocument? _document;
  PageImageRegions? _imageRegions;
  Outline _outline = Outline.empty;

  /// Touch layout: whether the top bar and bottom panel are showing.
  bool _chrome = true;

  /// Desktop layout: whether the contents / pages panel is open.
  bool _panel = false;
  int _panelTab = 0;

  /// Page being dragged to on the slider, before letting go.
  double? _sliderPage;

  /// The other device's position currently offered.
  ProgressRecord? _offeredJump;
  bool _alwaysJump = false;
  bool _viewerReady = false;

  /// Bumped to rebuild the viewer when the page layout changes.
  int _viewerGeneration = 0;
  bool _restoreZoom = true;

  LibrarySync get _sync => widget.librarySync;
  LibraryStore get _store => widget.store;
  Book get _book => widget.book;
  bool get _spread => _desktop && _store.twoPageSpread;
  bool _desktop = false;

  @override
  void initState() {
    super.initState();
    _alwaysJump = _store.autoJump;
    _sync.openBookId = _book.id;
    _sync.addListener(_onSyncChanged);
    _sync.checkProgress(_book);
    _scheduleHide();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _desktop = useDesktopLayout(context);
  }

  @override
  void dispose() {
    _saveTimer?.cancel();
    _hideTimer?.cancel();
    _controller.removeListener(_onViewChanged);
    _sync.removeListener(_onSyncChanged);
    if (_sync.openBookId == _book.id) _sync.openBookId = null;
    _imageRegions?.dispose();
    _saveProgress();
    _focusNode.dispose();
    _pageField.dispose();
    _pageFieldFocus.dispose();
    if (Platform.isAndroid) SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  Future<void> _saveProgress() async {
    final page = _page;
    if (page == null) return;
    await _store.updateProgress(
      _book.id,
      page: page,
      pageCount: _pageCount,
      pageOffset: _pageOffset,
      zoom: _zoom,
      chapter: _outline.chapterAt(page)?.title,
    );
    _sync.progressChanged(_book.id);
  }

  // --- Sync prompt ----------------------------------------------------------

  /// Shows or hides the resume prompt as sync finds a newer position from
  /// another device.
  void _onSyncChanged() {
    if (!mounted || !_viewerReady) return;
    final pending = _sync.pendingJumpFor(_book.id);
    if (pending?.updated == _offeredJump?.updated && pending?.page == _offeredJump?.page) return;
    if (pending != null && _store.autoJump) {
      _offeredJump = pending;
      _acceptJump(announce: true);
      return;
    }
    setState(() => _offeredJump = pending);
  }

  Future<void> _acceptJump({bool announce = false}) async {
    final offered = _offeredJump;
    setState(() => _offeredJump = null);
    if (_alwaysJump != _store.autoJump) await _store.setAutoJump(_alwaysJump);
    final record = await _sync.acceptJump(_book.id);
    if (record == null || !mounted || !_controller.isReady) return;
    final offset = record.pageOffset;
    if (offset == null) {
      await _controller.goToPage(pageNumber: record.page.clamp(1, _controller.pageCount));
    } else {
      await _goToPosition(record.page, offset);
    }
    if (announce && mounted && offered != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Moved to page ${record.page}, where you were on ${record.device}')),
      );
    }
    _focusNode.requestFocus();
  }

  Future<void> _declineJump() async {
    setState(() => _offeredJump = null);
    await _sync.declineJump(_book.id);
    _focusNode.requestFocus();
  }

  // --- Position tracking ----------------------------------------------------

  void _scheduleSave() {
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(seconds: 1), _saveProgress);
  }

  void _onPageChanged(int? page) {
    if (page == null) return;
    setState(() => _page = page);
    if (!_pageFieldFocus.hasFocus) _pageField.text = '$page';
    _scheduleSave();
  }

  /// Records the viewport's top-left relative to the current page.
  void _onViewChanged() {
    if (!_controller.isReady) return;
    final page = _controller.pageNumber ?? _page;
    if (page == null) return;
    final pageRect = _controller.layout.pageLayouts[page - 1];
    final visible = _controller.visibleRect;
    _page = page;
    _pageOffset = Offset(
      (visible.left - pageRect.left) / pageRect.width,
      (visible.top - pageRect.top) / pageRect.height,
    );
    _zoom = _controller.currentZoom;
    _scheduleSave();
  }

  void _onViewerReady(PdfDocument document, PdfViewerController controller) {
    _controller.removeListener(_onViewChanged);
    _imageRegions?.dispose();
    _imageRegions = PageImageRegions(document, onLoaded: () {
      if (mounted && _store.readerTheme == ReaderTheme.dark) setState(() {});
    });
    _document = document;
    final page = controller.pageNumber ?? _page ?? _book.lastPage;
    setState(() {
      _pageCount = document.pages.length;
      _page = page;
    });
    _pageField.text = '$page';
    Outline.load(document).then((outline) {
      if (!mounted) return;
      setState(() {
        _outline = outline;
        if (outline.isEmpty) _panelTab = 1;
      });
    });
    _restoreExactPosition().whenComplete(() {
      if (!mounted) return;
      _controller.addListener(_onViewChanged);
      _viewerReady = true;
      _onSyncChanged();
    });
  }

  /// The viewer has already jumped to the top of [Book.lastPage]; refine that to
  /// the saved scroll offset and zoom within the page.
  Future<void> _restoreExactPosition() async {
    final x = _book.pageOffsetX, y = _book.pageOffsetY;
    if (x == null || y == null) return;
    final zoom = _restoreZoom ? _book.zoom?.clamp(_controller.minScale, _controller.maxScale) : null;
    await _goToPosition(_book.lastPage, Offset(x, y), zoom: zoom);
  }

  /// Scrolls so the viewport's top-left is at [offset] (fractions of the page
  /// size) within [page].
  Future<void> _goToPosition(int page, Offset offset, {double? zoom}) async {
    if (page < 1 || page > _controller.pageCount) return;
    final pageRect = _controller.layout.pageLayouts[page - 1];
    await _controller.goToPosition(
      documentOffset: Offset(pageRect.left + offset.dx * pageRect.width, pageRect.top + offset.dy * pageRect.height),
      zoom: zoom,
    );
  }

  // --- Navigation -----------------------------------------------------------

  Future<void> _goToPage(int page) async {
    final count = _pageCount;
    if (count == null || !_controller.isReady) return;
    await _controller.goToPage(pageNumber: page.clamp(1, count));
  }

  void _step(int direction) {
    final page = _page;
    final count = _pageCount;
    if (page == null || count == null) return;
    int target;
    if (_spread) {
      final start = spreadRowStart(page);
      target = direction > 0 ? (start == 1 ? 2 : start + 2) : (start <= 2 ? 1 : start - 2);
    } else {
      target = page + direction;
    }
    target = target.clamp(1, count);
    if (target != page) _controller.goToPage(pageNumber: target);
  }

  /// Zooms so the current page (or both facing pages) fill the width.
  Future<void> _fitWidth() async {
    final page = _page;
    if (page == null || !_controller.isReady) return;
    var rect = _controller.layout.pageLayouts[page - 1];
    if (_spread) {
      final start = spreadRowStart(page);
      rect = _controller.layout.pageLayouts[start - 1];
      if (start > 1 && start < _controller.pageCount) rect = rect.expandToInclude(_controller.layout.pageLayouts[start]);
    }
    final margin = _controller.params.margin;
    final view = _controller.viewSize;
    final zoom = (view.width - margin * 2) / rect.width;
    final position = rect.topCenter.translate(0, (view.height / 2 - margin) / zoom);
    await _controller.goTo(_controller.calcMatrixFor(position, zoom: zoom, viewSize: view));
  }

  Future<void> _setSpread(bool spread) async {
    if (spread == _store.twoPageSpread) return;
    await _saveProgress();
    _controller.removeListener(_onViewChanged);
    _viewerReady = false;
    _restoreZoom = false;
    await _store.setTwoPageSpread(spread);
    setState(() => _viewerGeneration++);
  }

  Future<void> _setTheme(ReaderTheme theme) async {
    await _store.setReaderTheme(theme);
    if (mounted) setState(() {});
  }

  // --- Touch chrome -----------------------------------------------------------

  void _scheduleHide() {
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(seconds: 3), () {
      if (mounted && !_desktop && _offeredJump == null) _setChrome(false);
    });
  }

  void _setChrome(bool visible) {
    _hideTimer?.cancel();
    if (_chrome == visible) return;
    setState(() => _chrome = visible);
    if (Platform.isAndroid) {
      SystemChrome.setEnabledSystemUIMode(visible ? SystemUiMode.edgeToEdge : SystemUiMode.immersiveSticky);
    }
  }

  bool _onTap(BuildContext context, PdfViewerController controller, PdfViewerGeneralTapHandlerDetails details) {
    if (_desktop || details.type != PdfViewerGeneralTapType.tap) return false;
    _setChrome(!_chrome);
    return false;
  }

  Future<void> _showContentsSheet() async {
    final document = _document;
    if (document == null) return;
    _hideTimer?.cancel();
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.7,
        maxChildSize: 0.95,
        builder: (context, scroll) => DefaultTabController(
          length: 2,
          initialIndex: _outline.isEmpty ? 1 : 0,
          child: Column(
            children: [
              const TabBar(tabs: [Tab(text: 'Contents'), Tab(text: 'Pages')]),
              Expanded(
                child: TabBarView(
                  children: [
                    _outline.isEmpty
                        ? const Center(child: Text('This PDF has no table of contents.'))
                        : ContentsList(
                            outline: _outline,
                            page: _page ?? 1,
                            controller: scroll,
                            onSelect: (p) {
                              Navigator.pop(context);
                              _goToPage(p);
                            },
                          ),
                    PagesGrid(
                      document: document,
                      page: _page ?? 1,
                      maxExtent: 150,
                      onSelect: (p) {
                        Navigator.pop(context);
                        _goToPage(p);
                      },
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // --- Page painting --------------------------------------------------------

  /// Dark mode: invert everything on the page except its images, then soften
  /// pure black/white to easier-on-the-eyes greys.
  void _paintDarkPage(Canvas canvas, Rect pageRect, PdfPage page) {
    final regions = _imageRegions?.regionsFor(page.pageNumber) ?? const <PdfRect>[];
    canvas.save();
    if (regions.isNotEmpty) {
      final images = Path();
      for (final r in regions) {
        images.addRect(r.toRectInDocument(page: page, pageRect: pageRect));
      }
      canvas.clipPath(Path.combine(PathOperation.difference, Path()..addRect(pageRect), images));
    }
    canvas.drawRect(pageRect, Paint()..color = Colors.white..blendMode = BlendMode.difference);
    canvas.drawRect(pageRect, Paint()..color = const Color(0xFF1B1B1D)..blendMode = BlendMode.lighten);
    canvas.restore();
    // Slightly dim the whole page, images included, so they don't glare.
    canvas.drawRect(pageRect, Paint()..color = const Color(0xFFDDDDDD)..blendMode = BlendMode.multiply);
  }

  /// Sepia: warm paper and brown-black ink.
  void _paintSepiaPage(Canvas canvas, Rect pageRect, PdfPage page) {
    canvas.drawRect(pageRect, Paint()..color = const Color(0xFFF4ECD8)..blendMode = BlendMode.multiply);
    canvas.drawRect(pageRect, Paint()..color = const Color(0xFF2E2118)..blendMode = BlendMode.lighten);
  }

  // --- Build ----------------------------------------------------------------

  Widget _viewer() {
    final theme = _store.readerTheme;
    final background = switch (theme) {
      ReaderTheme.light => const Color(0xFFD6D6D6),
      ReaderTheme.sepia => const Color(0xFFD8CDB4),
      ReaderTheme.dark => const Color(0xFF0B0B0C),
    };
    return PdfViewer.file(
      _store.fileFor(_book).path,
      key: ValueKey(_viewerGeneration),
      controller: _controller,
      initialPageNumber: _page ?? _book.lastPage,
      params: PdfViewerParams(
        backgroundColor: background,
        layoutPages: _spread ? spreadLayout : null,
        pagePaintCallbacks: switch (theme) {
          ReaderTheme.light => null,
          ReaderTheme.sepia => [_paintSepiaPage],
          ReaderTheme.dark => [_paintDarkPage],
        },
        onViewerReady: _onViewerReady,
        onPageChanged: _onPageChanged,
        onGeneralTap: _onTap,
      ),
    );
  }

  ResumeOffer? get _offer {
    final record = _offeredJump;
    if (record == null) return null;
    return ResumeOffer(
      record: record,
      currentPage: _page ?? _book.lastPage,
      section: _outline.sectionAt(record.page)?.title,
    );
  }

  @override
  Widget build(BuildContext context) {
    _desktop = useDesktopLayout(context);
    final offer = _offer;
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.pageDown): () => _step(1),
        const SingleActivator(LogicalKeyboardKey.pageUp): () => _step(-1),
        const SingleActivator(LogicalKeyboardKey.arrowRight): () => _step(1),
        const SingleActivator(LogicalKeyboardKey.arrowLeft): () => _step(-1),
        const SingleActivator(LogicalKeyboardKey.home): () => _goToPage(1),
        const SingleActivator(LogicalKeyboardKey.end): () => _goToPage(_pageCount ?? 1),
        const SingleActivator(LogicalKeyboardKey.equal, control: true): () => _controller.zoomUp(),
        const SingleActivator(LogicalKeyboardKey.minus, control: true): () => _controller.zoomDown(),
        const SingleActivator(LogicalKeyboardKey.digit0, control: true): _fitWidth,
        const SingleActivator(LogicalKeyboardKey.keyG, control: true): () {
          _pageFieldFocus.requestFocus();
          _pageField.selection = TextSelection(baseOffset: 0, extentOffset: _pageField.text.length);
        },
        const SingleActivator(LogicalKeyboardKey.keyB, control: true): () => setState(() => _panel = !_panel),
        if (offer != null) const SingleActivator(LogicalKeyboardKey.keyJ): _acceptJump,
        if (offer != null) const SingleActivator(LogicalKeyboardKey.escape): _declineJump,
      },
      child: Focus(
        focusNode: _focusNode,
        autofocus: true,
        onKeyEvent: (_, event) => questionMarkOpens(event, () => showShortcutsDialog(context, _shortcuts)),
        child: _desktop ? _desktopLayout(context, offer) : _touchLayout(context, offer),
      ),
    );
  }

  static const _shortcuts = [
    ('← → / PgUp PgDn', 'Previous / next page'),
    ('Home / End', 'First / last page'),
    ('Ctrl+G', 'Go to page'),
    ('Ctrl+= / Ctrl+−', 'Zoom in / out'),
    ('Ctrl+0', 'Fit width'),
    ('Ctrl+B', 'Contents panel'),
    ('J / Esc', 'Jump / stay when another device is ahead'),
    ('?', 'Show this list'),
  ];

  // --- Touch layout ---------------------------------------------------------

  Widget _touchLayout(BuildContext context, ResumeOffer? offer) {
    final page = _page ?? _book.lastPage;
    final count = _pageCount;
    final chapter = _outline.chapterAt(page)?.title;
    const barColor = Color(0xF2182024);
    const fg = Color(0xFFECF1EF);
    const muted = Color(0xFFA9B8B4);
    final topInset = MediaQuery.paddingOf(context).top;
    return Scaffold(
      body: Stack(
        children: [
          Positioned.fill(child: _viewer()),
          // Top bar.
          AnimatedPositioned(
            duration: const Duration(milliseconds: 200),
            left: 0,
            right: 0,
            top: _chrome ? 0 : -(topInset + 80),
            child: Material(
              color: barColor,
              child: Padding(
                padding: EdgeInsets.fromLTRB(4, topInset + 4, 8, 4),
                child: Row(
                  children: [
                    IconButton(
                      tooltip: 'Back to library',
                      color: fg,
                      icon: const Icon(Icons.arrow_back),
                      onPressed: () => Navigator.maybePop(context),
                    ),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            _book.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(color: fg, fontSize: 17, fontWeight: FontWeight.w600),
                          ),
                          if (chapter != null)
                            Text(chapter, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: muted, fontSize: 13)),
                        ],
                      ),
                    ),
                    IconButton(
                      tooltip: 'Contents and pages',
                      color: fg,
                      icon: const Icon(Icons.toc),
                      onPressed: _showContentsSheet,
                    ),
                  ],
                ),
              ),
            ),
          ),
          // Bottom panel.
          AnimatedPositioned(
            duration: const Duration(milliseconds: 200),
            left: 0,
            right: 0,
            bottom: _chrome ? 0 : -260,
            child: Material(
              color: barColor,
              borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
              child: SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
                  child: count == null
                      ? const SizedBox(height: 48)
                      : Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            _PageSlider(
                              page: _sliderPage ?? page.toDouble(),
                              count: count,
                              chapters: _outline.chapters.map((c) => c.page).toList(),
                              onChanged: (v) {
                                _hideTimer?.cancel();
                                setState(() => _sliderPage = v);
                              },
                              onChangeEnd: (v) {
                                setState(() => _sliderPage = null);
                                _goToPage(v.round());
                              },
                            ),
                            Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 8),
                              child: Row(
                                children: [
                                  Text('Page ${(_sliderPage ?? page).round()} of $count', style: const TextStyle(color: muted)),
                                  const Spacer(),
                                  Flexible(
                                    child: Text(
                                      _remainingText(page, count),
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(color: muted),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(height: 14),
                            Row(
                              children: [
                                const Text('Page colour', style: TextStyle(color: muted)),
                                const Spacer(),
                                PageColourPicker(value: _store.readerTheme, onChanged: _setTheme),
                              ],
                            ),
                          ],
                        ),
                ),
              ),
            ),
          ),
          if (offer != null)
            Positioned.fill(
              child: ResumeSheet(
                offer: offer,
                document: _document,
                alwaysJump: _alwaysJump,
                onAlwaysJump: (v) => setState(() => _alwaysJump = v),
                onJump: _acceptJump,
                onStay: _declineJump,
              ),
            ),
        ],
      ),
    );
  }

  String _remainingText(int page, int count) {
    final percent = '${((page - 1) / (count > 1 ? count - 1 : 1) * 100).round()}%';
    final next = _outline.nextChapterPage(page);
    if (next != null) {
      final left = next - page;
      return '$percent · $left page${left == 1 ? '' : 's'} left in chapter';
    }
    final left = count - page;
    return '$percent · $left page${left == 1 ? '' : 's'} left';
  }

  // --- Desktop layout ---------------------------------------------------------

  Widget _desktopLayout(BuildContext context, ResumeOffer? offer) =>
      Theme(data: readerChromeTheme(), child: Builder(builder: (context) => _desktopChrome(context, offer)));

  Widget _desktopChrome(BuildContext context, ResumeOffer? offer) {
    final theme = Theme.of(context);
    final page = _page ?? _book.lastPage;
    final count = _pageCount;
    final chapter = _outline.chapterAt(page)?.title;
    final document = _document;
    final compact = MediaQuery.sizeOf(context).width < 1180;
    return Scaffold(
      body: Column(
        children: [
          Material(
            color: theme.colorScheme.surfaceContainer,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              child: Row(
                children: [
                  IconButton(
                    tooltip: 'Back to library',
                    icon: const Icon(Icons.arrow_back),
                    onPressed: () => Navigator.maybePop(context),
                  ),
                  IconButton(
                    tooltip: _panel ? 'Hide contents (Ctrl+B)' : 'Show contents (Ctrl+B)',
                    isSelected: _panel,
                    icon: const Icon(Icons.vertical_split_outlined),
                    onPressed: () => setState(() => _panel = !_panel),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(_book.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.titleSmall),
                        if (chapter != null)
                          Text(
                            chapter,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                          ),
                      ],
                    ),
                  ),
                  if (count != null) ...[
                    const Text('Page '),
                    SizedBox(
                      width: 64,
                      height: 34,
                      child: TextField(
                        controller: _pageField,
                        focusNode: _pageFieldFocus,
                        textAlign: TextAlign.center,
                        inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                        decoration: const InputDecoration(
                          isDense: true,
                          contentPadding: EdgeInsets.symmetric(vertical: 8),
                          border: OutlineInputBorder(),
                        ),
                        onSubmitted: (text) {
                          final target = int.tryParse(text);
                          if (target != null) _goToPage(target);
                          _focusNode.requestFocus();
                        },
                      ),
                    ),
                    Text('  of $count'),
                    const SizedBox(width: 16),
                  ],
                  IconButton(tooltip: 'Zoom out (Ctrl+−)', icon: const Icon(Icons.zoom_out), onPressed: () => _controller.zoomDown()),
                  compact
                      ? IconButton(tooltip: 'Fit width (Ctrl+0)', icon: const Icon(Icons.fit_screen_outlined), onPressed: _fitWidth)
                      : TextButton(onPressed: _fitWidth, child: const Text('Fit width')),
                  IconButton(tooltip: 'Zoom in (Ctrl+=)', icon: const Icon(Icons.zoom_in), onPressed: () => _controller.zoomUp()),
                  const SizedBox(width: 8),
                  SegmentedButton<bool>(
                    showSelectedIcon: false,
                    style: const ButtonStyle(visualDensity: VisualDensity.compact),
                    segments: [
                      ButtonSegment(
                        value: false,
                        tooltip: 'Scroll',
                        label: compact ? null : const Text('Scroll'),
                        icon: const Icon(Icons.view_day_outlined),
                      ),
                      ButtonSegment(
                        value: true,
                        tooltip: 'Two pages',
                        label: compact ? null : const Text('Two pages'),
                        icon: const Icon(Icons.auto_stories_outlined),
                      ),
                    ],
                    selected: {_store.twoPageSpread},
                    onSelectionChanged: (s) => _setSpread(s.first),
                  ),
                  const SizedBox(width: 4),
                  PopupMenuButton<ReaderTheme>(
                    tooltip: 'Page colour',
                    icon: const Icon(Icons.contrast),
                    initialValue: _store.readerTheme,
                    onSelected: _setTheme,
                    itemBuilder: (_) => const [
                      PopupMenuItem(value: ReaderTheme.light, child: Text('Light pages')),
                      PopupMenuItem(value: ReaderTheme.sepia, child: Text('Sepia pages')),
                      PopupMenuItem(value: ReaderTheme.dark, child: Text('Dark pages')),
                    ],
                  ),
                  IconButton(
                    tooltip: 'Keyboard shortcuts (?)',
                    icon: const Icon(Icons.keyboard_outlined),
                    onPressed: () => showShortcutsDialog(context, _shortcuts),
                  ),
                ],
              ),
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (_panel && document != null) ...[
                  SizedBox(
                    width: 290,
                    child: Material(
                      color: theme.colorScheme.surfaceContainerLow,
                      child: Column(
                        children: [
                          Padding(
                            padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
                            child: SegmentedButton<int>(
                              showSelectedIcon: false,
                              style: const ButtonStyle(visualDensity: VisualDensity.compact),
                              segments: const [
                                ButtonSegment(value: 0, label: Text('Contents')),
                                ButtonSegment(value: 1, label: Text('Pages')),
                              ],
                              selected: {_panelTab},
                              onSelectionChanged: (s) => setState(() => _panelTab = s.first),
                            ),
                          ),
                          Expanded(
                            child: _panelTab == 0
                                ? (_outline.isEmpty
                                    ? const Center(
                                        child: Padding(
                                          padding: EdgeInsets.all(24),
                                          child: Text('This PDF has no table of contents.', textAlign: TextAlign.center),
                                        ),
                                      )
                                    : ContentsList(outline: _outline, page: page, onSelect: _goToPage))
                                : PagesGrid(document: document, page: page, maxExtent: 120, onSelect: _goToPage),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const VerticalDivider(width: 1),
                ],
                Expanded(
                  child: Stack(
                    children: [
                      Positioned.fill(child: _viewer()),
                      if (offer != null)
                        Positioned(
                          right: 24,
                          bottom: 24,
                          child: ResumeToast(
                            offer: offer,
                            alwaysJump: _alwaysJump,
                            onAlwaysJump: (v) => setState(() => _alwaysJump = v),
                            onJump: _acceptJump,
                            onStay: _declineJump,
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Material(
            color: theme.colorScheme.surfaceContainer,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
              child: DefaultTextStyle.merge(
                style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                child: Row(
                  children: [
                    if (count != null) ...[
                      SizedBox(
                        width: 220,
                        child: ProgressLine(value: count > 1 ? (page - 1) / (count - 1) : 0),
                      ),
                      const SizedBox(width: 10),
                      Text(_remainingText(page, count)),
                    ],
                    const Spacer(),
                    if (count != null) Text('${((page - 1) / (count > 1 ? count - 1 : 1) * 100).round()}% read'),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Page slider with tick marks where chapters start.
class _PageSlider extends StatelessWidget {
  const _PageSlider({
    required this.page,
    required this.count,
    required this.chapters,
    required this.onChanged,
    required this.onChangeEnd,
  });

  final double page;
  final int count;
  final List<int> chapters;
  final ValueChanged<double> onChanged;
  final ValueChanged<double> onChangeEnd;

  @override
  Widget build(BuildContext context) {
    if (count < 2) return const SizedBox(height: 48);
    return SizedBox(
      height: 48,
      child: LayoutBuilder(builder: (context, constraints) {
        // Matches the Slider's default horizontal track padding.
        const inset = 24.0;
        final track = constraints.maxWidth - inset * 2;
        return Stack(
          alignment: Alignment.center,
          children: [
            for (final c in chapters)
              Positioned(
                left: inset + track * (c - 1) / (count - 1) - 1,
                top: 17,
                child: Container(width: 2, height: 14, color: const Color(0xFF78909C)),
              ),
            SliderTheme(
              data: SliderTheme.of(context).copyWith(
                activeTrackColor: const Color(0xFF4DB6AC),
                inactiveTrackColor: const Color(0xFF37474F),
                thumbColor: Colors.white,
                overlayColor: Colors.white24,
              ),
              child: Slider(
                min: 1,
                max: count.toDouble(),
                value: page.clamp(1, count.toDouble()),
                onChanged: onChanged,
                onChangeEnd: onChangeEnd,
              ),
            ),
          ],
        );
      }),
    );
  }
}

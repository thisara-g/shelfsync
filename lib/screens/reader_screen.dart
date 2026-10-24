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

/// Native window controls (Linux runner): full screen.
const _windowChannel = MethodChannel('shelfsync/window');

/// Colours of the desktop reader chrome, from the mockup.
abstract final class _Chrome {
  static const bar = Color(0xFF182024);
  static const panel = Color(0xFF151B1E);
  static const page = Color(0xFF101416);
  static const group = Color(0xFF202A2E);
  static const line = Color(0xFF263238);
  static const selected = Color(0xFF37474F);
  static const text = Color(0xFFECF1EF);
  static const muted = Color(0xFFA9B8B4);
  static const faint = Color(0xFF78909C);
  static const accent = Color(0xFF4DB6AC);
  static const current = Color(0xFF1F3B38);
  static const currentText = Color(0xFF80CBC4);
}

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
  late final _searcher = PdfTextSearcher(_controller)..addListener(_onSearchChanged);
  final _focusNode = FocusNode();
  final _pageField = TextEditingController();
  final _pageFieldFocus = FocusNode();
  final _searchField = TextEditingController();
  final _searchFocus = FocusNode();
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

  /// Desktop layout: whether the contents / pages / bookmarks panel is open.
  bool _panel = false;
  int _panelTab = 0;

  bool _searching = false;
  bool _fullscreen = false;

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
  bool _desktop = false;
  ReaderLayout get _layout => _desktop ? _store.readerLayout : ReaderLayout.scroll;
  bool get _spread => _layout == ReaderLayout.spread;

  @override
  void initState() {
    super.initState();
    _alwaysJump = _store.autoJump;
    _sync.openBookId = _book.id;
    _sync.addListener(_onSyncChanged);
    _store.addListener(_onStoreChanged);
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
    _store.removeListener(_onStoreChanged);
    if (_sync.openBookId == _book.id) _sync.openBookId = null;
    _imageRegions?.dispose();
    _searcher.dispose();
    _saveProgress();
    _focusNode.dispose();
    _pageField.dispose();
    _pageFieldFocus.dispose();
    _searchField.dispose();
    _searchFocus.dispose();
    if (_fullscreen && Platform.isLinux) _windowChannel.invokeMethod('setFullscreen', false);
    if (Platform.isAndroid) SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  void _onStoreChanged() {
    if (mounted) setState(() {}); // bookmarks synced from elsewhere
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message), duration: const Duration(seconds: 2)));
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
    if (offset == null || _layout == ReaderLayout.single) {
      await _showPage(record.page);
    } else {
      await _goToPosition(record.page, offset);
    }
    if (announce && offered != null) _snack('Moved to page ${record.page}, where you were on ${record.device}');
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
    _imageRegions = PageImageRegions(
      document,
      onLoaded: () {
        if (mounted && _store.readerTheme == ReaderTheme.dark) setState(() {});
      },
    );
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
        if (outline.isEmpty && _panelTab == 0) _panelTab = 1;
      });
    });
    final restore = _layout == ReaderLayout.single ? _showPage(page) : _restoreExactPosition();
    restore.whenComplete(() {
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

  /// Shows a whole page in Single mode, otherwise scrolls to its top.
  Future<void> _showPage(int page) async {
    final count = _pageCount;
    if (count == null || !_controller.isReady) return;
    await _controller.goToPage(
      pageNumber: page.clamp(1, count),
      anchor: _layout == ReaderLayout.single ? PdfPageAnchor.all : null,
    );
  }

  Future<void> _goToPage(int page) => _showPage(page);

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
    if (target != page) _showPage(target);
  }

  /// Zooms so the current page (or both facing pages) fill the width.
  Future<void> _fitWidth() async {
    final page = _page;
    if (page == null || !_controller.isReady) return;
    var rect = _controller.layout.pageLayouts[page - 1];
    if (_spread) {
      final start = spreadRowStart(page);
      rect = _controller.layout.pageLayouts[start - 1];
      if (start > 1 && start < _controller.pageCount) {
        rect = rect.expandToInclude(_controller.layout.pageLayouts[start]);
      }
    }
    final margin = _controller.params.margin;
    final view = _controller.viewSize;
    final zoom = (view.width - margin * 2) / rect.width;
    final position = rect.topCenter.translate(0, (view.height / 2 - margin) / zoom);
    await _controller.goTo(_controller.calcMatrixFor(position, zoom: zoom, viewSize: view));
  }

  Future<void> _setLayout(ReaderLayout layout) async {
    final previous = _store.readerLayout;
    if (layout == previous) return;
    await _store.setReaderLayout(layout);
    if ((layout == ReaderLayout.spread) != (previous == ReaderLayout.spread)) {
      // Facing pages need a different page layout: rebuild the viewer.
      await _saveProgress();
      _controller.removeListener(_onViewChanged);
      _viewerReady = false;
      _restoreZoom = false;
      setState(() => _viewerGeneration++);
    } else {
      setState(() {});
      if (layout == ReaderLayout.single) await _showPage(_page ?? 1);
    }
    _focusNode.requestFocus();
  }

  Future<void> _setTheme(ReaderTheme theme) async {
    await _store.setReaderTheme(theme);
    if (mounted) setState(() {});
  }

  // --- Search, bookmarks, full screen ---------------------------------------

  void _openSearch() {
    _hideTimer?.cancel();
    setState(() {
      _searching = true;
      _chrome = true;
    });
    _searchFocus.requestFocus();
    _searchField.selection = TextSelection(baseOffset: 0, extentOffset: _searchField.text.length);
  }

  void _closeSearch() {
    _searcher.resetTextSearch();
    setState(() => _searching = false);
    _focusNode.requestFocus();
  }

  void _onSearchChanged() {
    if (mounted) setState(() {});
  }

  void _search(String text) {
    if (text.trim().isEmpty) {
      _searcher.resetTextSearch();
    } else {
      _searcher.startTextSearch(text.trim());
    }
  }

  String get _searchStatus {
    if (_searchField.text.trim().isEmpty) return '';
    final count = _searcher.matches.length;
    final index = _searcher.currentIndex;
    if (_searcher.isSearching && count == 0) return 'Searching…';
    if (count == 0) return 'No matches';
    final suffix = _searcher.isSearching ? '+' : '';
    return index == null ? '$count$suffix matches' : '${index + 1} of $count$suffix';
  }

  Future<void> _toggleBookmark() async {
    final page = _page;
    if (page == null) return;
    final added = await _store.toggleBookmark(_book.id, page);
    _sync.syncNow();
    _snack(added ? 'Bookmarked page $page' : 'Removed bookmark on page $page');
  }

  Future<void> _toggleFullscreen() async {
    final on = !_fullscreen;
    setState(() => _fullscreen = on);
    if (Platform.isLinux) {
      await _windowChannel.invokeMethod('setFullscreen', on);
    } else {
      _setChrome(!on);
    }
  }

  // --- Touch chrome -----------------------------------------------------------

  void _scheduleHide() {
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(seconds: 3), () {
      if (mounted && !_desktop && _offeredJump == null && !_searching) _setChrome(false);
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
    if (_desktop || details.type != PdfViewerGeneralTapType.tap || _searching) return false;
    _setChrome(!_chrome);
    return false;
  }

  Future<void> _showContentsSheet() async {
    final document = _document;
    if (document == null) return;
    _hideTimer?.cancel();
    void go(BuildContext context, int page) {
      Navigator.pop(context);
      _goToPage(page);
    }

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.7,
        maxChildSize: 0.95,
        builder: (context, scroll) => DefaultTabController(
          length: 3,
          initialIndex: _outline.isEmpty ? 1 : 0,
          child: Column(
            children: [
              const TabBar(
                tabs: [
                  Tab(text: 'Contents'),
                  Tab(text: 'Pages'),
                  Tab(text: 'Bookmarks'),
                ],
              ),
              Expanded(
                child: TabBarView(
                  children: [
                    _outline.isEmpty
                        ? const Center(child: Text('This PDF has no table of contents.'))
                        : ContentsList(
                            outline: _outline,
                            page: _page ?? 1,
                            controller: scroll,
                            onSelect: (p) => go(context, p),
                          ),
                    PagesGrid(document: document, page: _page ?? 1, maxExtent: 150, onSelect: (p) => go(context, p)),
                    ListenableBuilder(
                      listenable: _store,
                      builder: (context, _) => BookmarksList(
                        pages: _store.bookmarksFor(_book.id),
                        outline: _outline,
                        page: _page ?? 1,
                        onSelect: (p) => go(context, p),
                        onRemove: (p) => _store.toggleBookmark(_book.id, p).then((_) => _sync.syncNow()),
                      ),
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
    canvas.drawRect(
      pageRect,
      Paint()
        ..color = Colors.white
        ..blendMode = BlendMode.difference,
    );
    canvas.drawRect(
      pageRect,
      Paint()
        ..color = const Color(0xFF1B1B1D)
        ..blendMode = BlendMode.lighten,
    );
    canvas.restore();
    // Slightly dim the whole page, images included, so they don't glare.
    canvas.drawRect(
      pageRect,
      Paint()
        ..color = const Color(0xFFDDDDDD)
        ..blendMode = BlendMode.multiply,
    );
  }

  /// Sepia: warm paper and brown-black ink.
  void _paintSepiaPage(Canvas canvas, Rect pageRect, PdfPage page) {
    canvas.drawRect(
      pageRect,
      Paint()
        ..color = const Color(0xFFF4ECD8)
        ..blendMode = BlendMode.multiply,
    );
    canvas.drawRect(
      pageRect,
      Paint()
        ..color = const Color(0xFF2E2118)
        ..blendMode = BlendMode.lighten,
    );
  }

  // --- Build ----------------------------------------------------------------

  Widget _viewer() {
    final theme = _store.readerTheme;
    final background = _desktop
        ? _Chrome.page
        : switch (theme) {
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
        margin: _desktop ? 14 : 8,
        layoutPages: _spread ? spreadLayout : null,
        pagePaintCallbacks: [
          ?switch (theme) {
            ReaderTheme.light => null,
            ReaderTheme.sepia => _paintSepiaPage,
            ReaderTheme.dark => _paintDarkPage,
          },
          _searcher.pageTextMatchPaintCallback,
        ],
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

  static const _shortcuts = [
    ('← → / PgUp PgDn', 'Previous / next page'),
    ('Home / End', 'First / last page'),
    ('Ctrl+F', 'Search in book'),
    ('Ctrl+D', 'Bookmark this page'),
    ('Ctrl+G', 'Go to page'),
    ('Ctrl+= / Ctrl+−', 'Zoom in / out'),
    ('Ctrl+0', 'Fit width'),
    ('Ctrl+B', 'Contents panel'),
    ('F11', 'Full screen'),
    ('J / Esc', 'Jump / stay when another device is ahead'),
    ('?', 'Show this list'),
  ];

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    final keyboard = HardwareKeyboard.instance;
    if (keyboard.isControlPressed) {
      final VoidCallback? action = switch (key) {
        LogicalKeyboardKey.keyF => _openSearch,
        LogicalKeyboardKey.keyD => _toggleBookmark,
        LogicalKeyboardKey.keyB => () => setState(() => _panel = !_panel),
        LogicalKeyboardKey.keyG => () {
          _pageFieldFocus.requestFocus();
          _pageField.selection = TextSelection(baseOffset: 0, extentOffset: _pageField.text.length);
        },
        LogicalKeyboardKey.equal ||
        LogicalKeyboardKey.add ||
        LogicalKeyboardKey.numpadAdd => () => _controller.zoomUp(),
        LogicalKeyboardKey.minus || LogicalKeyboardKey.numpadSubtract => () => _controller.zoomDown(),
        LogicalKeyboardKey.digit0 || LogicalKeyboardKey.numpad0 => _fitWidth,
        _ => null,
      };
      if (action == null) return KeyEventResult.ignored;
      action();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.f11) {
      _toggleFullscreen();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.escape) {
      if (_searching) {
        _closeSearch();
      } else if (_offeredJump != null) {
        _declineJump();
      } else if (_fullscreen) {
        _toggleFullscreen();
      } else {
        return KeyEventResult.ignored;
      }
      return KeyEventResult.handled;
    }
    final focused = FocusManager.instance.primaryFocus?.context;
    if (focused != null && focused.findAncestorStateOfType<EditableTextState>() != null) {
      return KeyEventResult.ignored; // typing in the search or page box
    }
    final VoidCallback? action = switch (key) {
      LogicalKeyboardKey.pageDown || LogicalKeyboardKey.arrowRight => () => _step(1),
      LogicalKeyboardKey.pageUp || LogicalKeyboardKey.arrowLeft => () => _step(-1),
      LogicalKeyboardKey.home => () => _goToPage(1),
      LogicalKeyboardKey.end => () => _goToPage(_pageCount ?? 1),
      LogicalKeyboardKey.keyJ when _offeredJump != null => _acceptJump,
      _ when event.character == '?' => () => showShortcutsDialog(context, _shortcuts),
      _ => null,
    };
    if (action == null) return KeyEventResult.ignored;
    action();
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    _desktop = useDesktopLayout(context);
    final offer = _offer;
    return Focus(
      focusNode: _focusNode,
      autofocus: true,
      onKeyEvent: _onKey,
      child: _desktop ? _desktopLayout(context, offer) : _touchLayout(context, offer),
    );
  }

  /// Find-in-book strip, shared by both layouts.
  Widget _searchStrip({required Color background}) {
    return Material(
      color: background,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
        child: Row(
          children: [
            const Icon(Icons.search, size: 20, color: _Chrome.muted),
            const SizedBox(width: 10),
            Expanded(
              child: TextField(
                controller: _searchField,
                focusNode: _searchFocus,
                style: const TextStyle(color: _Chrome.text, fontSize: 15),
                cursorColor: _Chrome.accent,
                decoration: const InputDecoration(
                  hintText: 'Search in book',
                  hintStyle: TextStyle(color: _Chrome.faint),
                  border: InputBorder.none,
                  isDense: true,
                ),
                onChanged: _search,
                onSubmitted: (_) {
                  if (HardwareKeyboard.instance.isShiftPressed) {
                    _searcher.goToPrevMatch();
                  } else {
                    _searcher.goToNextMatch();
                  }
                  _searchFocus.requestFocus();
                },
              ),
            ),
            Text(_searchStatus, style: const TextStyle(color: _Chrome.muted, fontSize: 13)),
            IconButton(
              tooltip: 'Previous match (Shift+Enter)',
              color: _Chrome.text,
              icon: const Icon(Icons.keyboard_arrow_up),
              onPressed: _searcher.hasMatches ? () => _searcher.goToPrevMatch() : null,
            ),
            IconButton(
              tooltip: 'Next match (Enter)',
              color: _Chrome.text,
              icon: const Icon(Icons.keyboard_arrow_down),
              onPressed: _searcher.hasMatches ? () => _searcher.goToNextMatch() : null,
            ),
            IconButton(
              tooltip: 'Close (Esc)',
              color: _Chrome.text,
              icon: const Icon(Icons.close),
              onPressed: _closeSearch,
            ),
          ],
        ),
      ),
    );
  }

  // --- Touch layout ---------------------------------------------------------

  Widget _touchLayout(BuildContext context, ResumeOffer? offer) {
    final page = _page ?? _book.lastPage;
    final count = _pageCount;
    final chapter = _outline.chapterAt(page)?.title;
    const barColor = Color(0xF2182024);
    final topInset = MediaQuery.paddingOf(context).top;
    final bookmarked = _store.isBookmarked(_book.id, page);
    return Scaffold(
      body: Stack(
        children: [
          Positioned.fill(child: _viewer()),
          // Top bar (and the search strip under it).
          AnimatedPositioned(
            duration: const Duration(milliseconds: 200),
            left: 0,
            right: 0,
            top: _chrome ? 0 : -(topInset + 140),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Material(
                  color: barColor,
                  child: Padding(
                    padding: EdgeInsets.fromLTRB(4, topInset + 4, 8, 4),
                    child: Row(
                      children: [
                        IconButton(
                          tooltip: 'Back to library',
                          color: _Chrome.text,
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
                                style: const TextStyle(color: _Chrome.text, fontSize: 18, fontWeight: FontWeight.w600),
                              ),
                              if (chapter != null)
                                Text(
                                  chapter,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(color: _Chrome.muted, fontSize: 14),
                                ),
                            ],
                          ),
                        ),
                        IconButton(
                          tooltip: 'Search in book',
                          color: _Chrome.text,
                          icon: const Icon(Icons.search),
                          onPressed: _openSearch,
                        ),
                        IconButton(
                          tooltip: 'Contents, pages and bookmarks',
                          color: _Chrome.text,
                          icon: const Icon(Icons.format_list_bulleted),
                          onPressed: _showContentsSheet,
                        ),
                        IconButton(
                          tooltip: bookmarked ? 'Remove bookmark' : 'Bookmark this page',
                          color: bookmarked ? _Chrome.accent : _Chrome.text,
                          icon: Icon(bookmarked ? Icons.bookmark : Icons.bookmark_border),
                          onPressed: _toggleBookmark,
                        ),
                      ],
                    ),
                  ),
                ),
                if (_searching) _searchStrip(background: const Color(0xF2202A2E)),
              ],
            ),
          ),
          // Bottom panel.
          AnimatedPositioned(
            duration: const Duration(milliseconds: 200),
            left: 0,
            right: 0,
            bottom: _chrome ? 0 : -260,
            child: Material(
              color: const Color(0xF2182024),
              borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
              child: SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(32, 20, 32, 28),
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
                            const SizedBox(height: 4),
                            Row(
                              children: [
                                Text(
                                  'Page ${(_sliderPage ?? page).round()} of $count',
                                  style: const TextStyle(color: _Chrome.muted, fontSize: 15),
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Text(
                                    _remainingText(page, count),
                                    textAlign: TextAlign.end,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(color: _Chrome.muted, fontSize: 15),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 22),
                            Row(
                              children: [
                                const Text('Page colour', style: TextStyle(color: _Chrome.muted, fontSize: 15)),
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

  String get _percentRead {
    final page = _page ?? _book.lastPage;
    final count = _pageCount ?? 1;
    return '${((page - 1) / (count > 1 ? count - 1 : 1) * 100).round()}%';
  }

  String _remainingText(int page, int count) {
    final next = _outline.nextChapterPage(page);
    if (next != null) {
      final left = next - page;
      return '$_percentRead · $left page${left == 1 ? '' : 's'} left in chapter';
    }
    final left = count - page;
    return '$_percentRead · $left page${left == 1 ? '' : 's'} left';
  }

  // --- Desktop layout ---------------------------------------------------------

  Widget _desktopLayout(BuildContext context, ResumeOffer? offer) => Theme(
    data: readerChromeTheme(),
    child: Builder(builder: (context) => _desktopChrome(context, offer)),
  );

  Widget _desktopChrome(BuildContext context, ResumeOffer? offer) {
    final page = _page ?? _book.lastPage;
    final count = _pageCount;
    final chapter = _outline.chapterAt(page)?.title;
    final document = _document;
    final compact = MediaQuery.sizeOf(context).width < 1100;
    return Scaffold(
      backgroundColor: _Chrome.page,
      body: Column(
        children: [
          if (!_fullscreen)
            Container(
              decoration: const BoxDecoration(
                color: _Chrome.bar,
                border: Border(bottom: BorderSide(color: _Chrome.line)),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              child: Row(
                children: [
                  _ChromeIcon(
                    tooltip: 'Back to library',
                    icon: Icons.chevron_left,
                    size: 22,
                    onPressed: () => Navigator.maybePop(context),
                  ),
                  _ChromeIcon(
                    tooltip: _panel ? 'Hide contents (Ctrl+B)' : 'Show contents (Ctrl+B)',
                    icon: Icons.vertical_split_outlined,
                    active: _panel,
                    onPressed: () => setState(() => _panel = !_panel),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          _book.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(color: _Chrome.text, fontSize: 15, fontWeight: FontWeight.w600),
                        ),
                        if (chapter != null)
                          Text(
                            chapter,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(color: _Chrome.muted, fontSize: 13),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  if (count != null) ...[
                    _Group(
                      padding: const EdgeInsets.symmetric(horizontal: 6),
                      children: [
                        const Text('Page', style: TextStyle(color: _Chrome.muted, fontSize: 14)),
                        const SizedBox(width: 6),
                        SizedBox(
                          width: 52,
                          height: 28,
                          child: TextField(
                            controller: _pageField,
                            focusNode: _pageFieldFocus,
                            textAlign: TextAlign.center,
                            style: const TextStyle(color: _Chrome.text, fontSize: 14),
                            cursorColor: _Chrome.accent,
                            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                            decoration: InputDecoration(
                              isDense: true,
                              filled: true,
                              fillColor: _Chrome.page,
                              contentPadding: const EdgeInsets.symmetric(vertical: 6),
                              enabledBorder: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(6),
                                borderSide: const BorderSide(color: _Chrome.selected),
                              ),
                              focusedBorder: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(6),
                                borderSide: const BorderSide(color: _Chrome.accent),
                              ),
                            ),
                            onSubmitted: (text) {
                              final target = int.tryParse(text);
                              if (target != null) _goToPage(target);
                              _focusNode.requestFocus();
                            },
                          ),
                        ),
                        const SizedBox(width: 6),
                        Text('of $count', style: const TextStyle(color: _Chrome.muted, fontSize: 14)),
                        const SizedBox(width: 6),
                      ],
                    ),
                    const SizedBox(width: 8),
                  ],
                  _Group(
                    children: [
                      _GroupButton(
                        tooltip: 'Zoom out (Ctrl+−)',
                        label: '−',
                        large: true,
                        onPressed: () => _controller.zoomDown(),
                      ),
                      _GroupButton(
                        tooltip: 'Fit width (Ctrl+0)',
                        label: compact ? null : 'Fit width',
                        icon: compact ? Icons.fit_screen_outlined : null,
                        onPressed: _fitWidth,
                      ),
                      _GroupButton(
                        tooltip: 'Zoom in (Ctrl+=)',
                        label: '+',
                        large: true,
                        onPressed: () => _controller.zoomUp(),
                      ),
                    ],
                  ),
                  const SizedBox(width: 8),
                  _Group(
                    padding: const EdgeInsets.all(4),
                    children: [
                      for (final (layout, label, icon) in const [
                        (ReaderLayout.scroll, 'Scroll', Icons.view_day_outlined),
                        (ReaderLayout.single, 'Single', Icons.crop_portrait),
                        (ReaderLayout.spread, 'Two pages', Icons.auto_stories_outlined),
                      ])
                        _Segment(
                          label: compact ? null : label,
                          icon: compact ? icon : null,
                          tooltip: label,
                          selected: _store.readerLayout == layout,
                          onPressed: () => _setLayout(layout),
                        ),
                    ],
                  ),
                  const SizedBox(width: 8),
                  _ChromeIcon(
                    tooltip: 'Search in book (Ctrl+F)',
                    icon: Icons.search,
                    active: _searching,
                    onPressed: _openSearch,
                  ),
                  PopupMenuButton<ReaderTheme>(
                    tooltip: 'Page colour',
                    initialValue: _store.readerTheme,
                    onSelected: _setTheme,
                    itemBuilder: (_) => const [
                      PopupMenuItem(value: ReaderTheme.light, child: Text('Light pages')),
                      PopupMenuItem(value: ReaderTheme.sepia, child: Text('Sepia pages')),
                      PopupMenuItem(value: ReaderTheme.dark, child: Text('Dark pages')),
                    ],
                    child: const SizedBox.square(
                      dimension: 40,
                      child: Icon(Icons.dark_mode_outlined, size: 20, color: _Chrome.text),
                    ),
                  ),
                  _ChromeIcon(tooltip: 'Full screen (F11)', icon: Icons.fullscreen, onPressed: _toggleFullscreen),
                ],
              ),
            ),
          if (_searching) _searchStrip(background: _Chrome.group),
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (_panel && document != null && !_fullscreen)
                  Container(
                    width: 280,
                    decoration: const BoxDecoration(
                      color: _Chrome.panel,
                      border: Border(right: BorderSide(color: _Chrome.line)),
                    ),
                    padding: const EdgeInsets.fromLTRB(10, 14, 10, 0),
                    child: Column(
                      children: [
                        Padding(
                          padding: const EdgeInsets.fromLTRB(4, 0, 4, 12),
                          child: Row(
                            children: [
                              for (final (i, label) in const [(0, 'Contents'), (1, 'Pages'), (2, 'Bookmarks')]) ...[
                                if (i > 0) const SizedBox(width: 4),
                                Expanded(
                                  child: _PanelTab(
                                    label: label,
                                    selected: _panelTab == i,
                                    onPressed: () => setState(() => _panelTab = i),
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                        Expanded(
                          child: switch (_panelTab) {
                            0 =>
                              _outline.isEmpty
                                  ? const _PanelEmpty('This PDF has no table of contents.')
                                  : _DesktopContents(outline: _outline, page: page, onSelect: _goToPage),
                            1 => PagesGrid(document: document, page: page, maxExtent: 120, onSelect: _goToPage),
                            _ => BookmarksList(
                              pages: _store.bookmarksFor(_book.id),
                              outline: _outline,
                              page: page,
                              onSelect: _goToPage,
                              onRemove: (p) => _store.toggleBookmark(_book.id, p).then((_) => _sync.syncNow()),
                              emptyText: 'No bookmarks yet.\nPress Ctrl+D to bookmark a page.',
                            ),
                          },
                        ),
                      ],
                    ),
                  ),
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
          if (!_fullscreen)
            Container(
              decoration: const BoxDecoration(
                color: _Chrome.bar,
                border: Border(top: BorderSide(color: _Chrome.line)),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
              child: DefaultTextStyle.merge(
                style: const TextStyle(color: _Chrome.muted, fontSize: 13),
                child: Row(
                  children: [
                    Expanded(
                      child: Row(
                        children: [
                          Expanded(
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(2),
                              child: LinearProgressIndicator(
                                value: count == null || count < 2 ? 0 : (page - 1) / (count - 1),
                                minHeight: 4,
                                color: _Chrome.accent,
                                backgroundColor: _Chrome.selected,
                              ),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Text(_percentRead),
                        ],
                      ),
                    ),
                    if (!compact) ...[
                      const SizedBox(width: 18),
                      const _FooterHint(keys: '← →', text: 'turn pages'),
                      const _FooterHint(keys: 'Ctrl F', text: 'search'),
                      const _FooterHint(keys: 'Ctrl D', text: 'bookmark'),
                      const _FooterHint(keys: 'F11', text: 'full screen'),
                    ],
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

// --- Desktop chrome pieces ---------------------------------------------------

class _ChromeIcon extends StatelessWidget {
  const _ChromeIcon({
    required this.tooltip,
    required this.icon,
    required this.onPressed,
    this.active = false,
    this.size = 20,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback onPressed;
  final bool active;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: Material(
        color: active ? _Chrome.group : Colors.transparent,
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: onPressed,
          child: SizedBox.square(
            dimension: 40,
            child: Icon(icon, size: size, color: _Chrome.text),
          ),
        ),
      ),
    );
  }
}

/// Rounded dark box holding related controls.
class _Group extends StatelessWidget {
  const _Group({required this.children, this.padding = EdgeInsets.zero});

  final List<Widget> children;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 40,
      padding: padding,
      decoration: BoxDecoration(color: _Chrome.group, borderRadius: BorderRadius.circular(10)),
      child: Row(mainAxisSize: MainAxisSize.min, children: children),
    );
  }
}

class _GroupButton extends StatelessWidget {
  const _GroupButton({required this.tooltip, required this.onPressed, this.label, this.icon, this.large = false});

  final String tooltip;
  final VoidCallback onPressed;
  final String? label;
  final IconData? icon;
  final bool large;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onPressed,
        child: Container(
          height: 40,
          constraints: const BoxConstraints(minWidth: 36),
          padding: EdgeInsets.symmetric(horizontal: label != null && !large ? 8 : 0),
          alignment: Alignment.center,
          child: icon != null
              ? Icon(icon, size: 18, color: _Chrome.text)
              : Text(
                  label!,
                  style: TextStyle(color: _Chrome.text, fontSize: large ? 18 : 14),
                ),
        ),
      ),
    );
  }
}

class _Segment extends StatelessWidget {
  const _Segment({required this.tooltip, required this.selected, required this.onPressed, this.label, this.icon});

  final String tooltip;
  final bool selected;
  final VoidCallback onPressed;
  final String? label;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final color = selected ? _Chrome.text : _Chrome.muted;
    return Padding(
      padding: const EdgeInsets.only(right: 2),
      child: Tooltip(
        message: tooltip,
        child: Material(
          color: selected ? _Chrome.selected : Colors.transparent,
          borderRadius: BorderRadius.circular(7),
          child: InkWell(
            borderRadius: BorderRadius.circular(7),
            onTap: onPressed,
            child: Container(
              height: 32,
              padding: const EdgeInsets.symmetric(horizontal: 10),
              alignment: Alignment.center,
              child: label != null
                  ? Text(
                      label!,
                      style: TextStyle(
                        color: color,
                        fontSize: 13,
                        fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
                      ),
                    )
                  : Icon(icon, size: 18, color: color),
            ),
          ),
        ),
      ),
    );
  }
}

class _PanelTab extends StatelessWidget {
  const _PanelTab({required this.label, required this.selected, required this.onPressed});

  final String label;
  final bool selected;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: selected ? _Chrome.line : Colors.transparent,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: onPressed,
        child: Container(
          height: 34,
          alignment: Alignment.center,
          child: Text(
            label,
            style: TextStyle(
              color: selected ? _Chrome.text : _Chrome.muted,
              fontSize: 13,
              fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
            ),
          ),
        ),
      ),
    );
  }
}

class _PanelEmpty extends StatelessWidget {
  const _PanelEmpty(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Text(
        text,
        textAlign: TextAlign.center,
        style: const TextStyle(color: _Chrome.muted, fontSize: 14),
      ),
    ),
  );
}

/// Contents list styled like the mockup: chapters bright, sections indented
/// and dimmer, the current section highlighted.
class _DesktopContents extends StatelessWidget {
  const _DesktopContents({required this.outline, required this.page, required this.onSelect});

  final Outline outline;
  final int page;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) {
    final current = outline.sectionAt(page);
    return ListView.builder(
      itemCount: outline.entries.length,
      itemBuilder: (context, i) {
        final e = outline.entries[i];
        final isCurrent = identical(e, current);
        final color = isCurrent ? _Chrome.currentText : (e.level == 0 ? _Chrome.text : _Chrome.muted);
        return Material(
          color: isCurrent ? _Chrome.current : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
          child: InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: () => onSelect(e.page),
            child: Container(
              constraints: const BoxConstraints(minHeight: 36),
              padding: EdgeInsets.only(left: 10.0 + 18 * e.level.clamp(0, 4), right: 10, top: 6, bottom: 6),
              child: Row(
                children: [
                  Expanded(
                    child: Text(e.title, style: TextStyle(color: color, fontSize: 14)),
                  ),
                  const SizedBox(width: 10),
                  Text('${e.page}', style: const TextStyle(color: _Chrome.faint, fontSize: 12)),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _FooterHint extends StatelessWidget {
  const _FooterHint({required this.keys, required this.text});

  final String keys;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 18),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
            decoration: BoxDecoration(color: _Chrome.line, borderRadius: BorderRadius.circular(4)),
            child: Text(keys, style: const TextStyle(color: _Chrome.text, fontSize: 13)),
          ),
          const SizedBox(width: 6),
          Text(text),
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
      child: LayoutBuilder(
        builder: (context, constraints) {
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
                  child: Container(width: 2, height: 14, color: _Chrome.faint),
                ),
              SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  activeTrackColor: _Chrome.accent,
                  inactiveTrackColor: _Chrome.selected,
                  thumbColor: Colors.white,
                  overlayColor: Colors.white24,
                  trackHeight: 6,
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
        },
      ),
    );
  }
}

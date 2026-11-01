import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:pdfrx/pdfrx.dart';

import '../models/book.dart';
import '../services/cover_renderer.dart';
import '../services/library_store.dart';
import '../services/page_image_regions.dart';
import '../sync/library_sync.dart';
import '../sync/progress_record.dart';
import 'common.dart';
import 'reader_parts.dart';
import 'reader_tablet.dart';
import 'tablet_ui.dart';

/// Native window controls (Linux runner): full screen.
const _windowChannel = MethodChannel('shelfsync/window');

/// Waits for a viewer animation, but no longer than [limit]: when the user
/// scrolls or zooms mid-animation, pdfrx cancels it and its future never
/// completes, which must not leave the reader half set up.
Future<void> _settle(Future<void> animation, {Duration limit = const Duration(milliseconds: 500)}) =>
    Future.any([animation, Future<void>.delayed(limit)]);

Future<void> _window(String method, bool value) async {
  if (!Platform.isLinux) return;
  try {
    await _windowChannel.invokeMethod(method, value);
  } on MissingPluginException {
    // Not running in the ShelfSync runner (e.g. tests).
  }
}

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
  const ReaderScreen({
    super.key,
    required this.store,
    required this.librarySync,
    required this.book,
    this.openContents = false,
  });

  final LibraryStore store;
  final LibrarySync librarySync;
  final Book book;

  /// Tablet: open the contents drawer as soon as the book has loaded.
  final bool openContents;

  @override
  State<ReaderScreen> createState() => _ReaderScreenState();
}

class _ReaderScreenState extends State<ReaderScreen> {
  final _controller = PdfViewerController();

  /// Find-in-book; needs a loaded document, so it's created per viewer load.
  PdfTextSearcher? _searcher;
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

  /// [ReaderScreen.openContents] has been acted on.
  bool _contentsOpened = false;
  late final _cover = CoverRenderer(widget.store).coverFor(widget.book);

  /// Local reading time before a resume prompt, for its "This tablet" side.
  late final DateTime? _localReadAt = widget.book.progressDevice == null ? widget.book.progressUpdatedAt : null;

  /// Desktop layout: whether the contents / pages / bookmarks panel is open.
  bool _panel = false;
  int _panelTab = 0;
  static const _panelWidth = 280.0;
  static const _panelDuration = Duration(milliseconds: 260);

  /// While the panel opens or closes the page area changes width every
  /// frame: keep the page centred then, and fit it once at the end.
  bool _panelAnimating = false;
  Offset? _panelCenter;

  bool _searching = false;
  bool _fullscreen = false;

  /// Desktop: toolbar and footer showing. They hide after a few seconds
  /// without pointer activity on them or at the window edges.
  bool _bars = true;
  Timer? _barsTimer;

  /// Waits for a text selection to settle before copying it.
  Timer? _copyTimer;

  /// "Copied" in the top-left of the page area, briefly after a copy.
  var _copied = false;
  Timer? _copiedTimer;

  /// Height of the floating toolbar (plus search strip), for placing the
  /// "Copied" popup just below it.
  var _topBarsHeight = 0.0;

  /// The bars stay longer the first time, while the reader is new.
  bool _barsHiddenOnce = false;
  Duration get _barsDelay => _barsHiddenOnce ? const Duration(seconds: 3) : const Duration(seconds: 5);

  Size? _viewSize;
  Timer? _resizeTimer;

  /// A zoom the user chose (buttons, keys, pinch, Ctrl+wheel). Page turns
  /// from ↑/↓ and window resizes keep it; ←/→ and layout changes fit the
  /// page again.
  double? _userZoom;

  /// The zoom [_frame] last applied, and whether it is applying one now, to
  /// tell our own zoom changes from the user's.
  double? _framedZoom;
  bool _framing = false;

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

  /// Desktop shows Single or Two pages; the touch layout scrolls continuously.
  ReaderLayout get _layout => !_desktop
      ? ReaderLayout.scroll
      : (_store.readerLayout == ReaderLayout.spread ? ReaderLayout.spread : ReaderLayout.single);
  bool get _spread => _layout == ReaderLayout.spread;

  @override
  void initState() {
    super.initState();
    _alwaysJump = _store.autoJump;
    _pageFieldFocus.addListener(() {
      if (_pageFieldFocus.hasFocus) {
        _showBars();
      } else {
        _scheduleBarsHide();
      }
    });
    _sync.openBookId = _book.id;
    _sync.addListener(_onSyncChanged);
    _store.addListener(_onStoreChanged);
    _sync.checkProgress(_book);
    _scheduleHide();
    _scheduleBarsHide();
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
    _resizeTimer?.cancel();
    _barsTimer?.cancel();
    _copyTimer?.cancel();
    _copiedTimer?.cancel();
    _controller.removeListener(_onViewChanged);
    _sync.removeListener(_onSyncChanged);
    _store.removeListener(_onStoreChanged);
    if (_sync.openBookId == _book.id) _sync.openBookId = null;
    _imageRegions?.dispose();
    _searcher?.dispose();
    _saveProgress();
    _focusNode.dispose();
    _pageField.dispose();
    _pageFieldFocus.dispose();
    _searchField.dispose();
    _searchFocus.dispose();
    if (_fullscreen) _window('setFullscreen', false);
    if (Platform.isAndroid) SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  void _onStoreChanged() {
    if (mounted) setState(() {}); // bookmarks synced from elsewhere
  }

  /// Selecting text copies it once the selection stops changing, so there
  /// is no need to press Ctrl+C (like the primary selection on Linux).
  void _onTextSelectionChange(PdfTextSelection selection) {
    _copyTimer?.cancel();
    // The tablet keeps pdfrx's own Copy menu.
    if (!_desktop || !selection.hasSelectedText || !selection.isCopyAllowed) return;
    _copyTimer = Timer(const Duration(milliseconds: 300), _copySelection);
  }

  /// Copies the selected text and keeps it selected (pdfrx's own
  /// copyTextSelection clears it). Returns whether anything was copied.
  Future<bool> _copySelection() async {
    final selection = _controller.textSelectionDelegate;
    if (!selection.hasSelectedText || !selection.isCopyAllowed) return false;
    final text = await selection.getSelectedText();
    if (text.isEmpty) return false;
    await Clipboard.setData(ClipboardData(text: text));
    if (mounted && _desktop) {
      setState(() => _copied = true);
      _copiedTimer?.cancel();
      _copiedTimer = Timer(const Duration(milliseconds: 1500), () {
        if (mounted) setState(() => _copied = false);
      });
    }
    return true;
  }

  Future<void> _copyWithKeys() async {
    final selection = _controller.textSelectionDelegate;
    if (selection.hasSelectedText && !selection.isCopyAllowed) {
      _snack("This PDF doesn't allow copying its text");
      return;
    }
    await _copySelection();
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
    if (offset == null || _layout != ReaderLayout.scroll) {
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
    final framed = _framedZoom;
    if (!_framing && framed != null && (_controller.currentZoom - framed).abs() > 0.001) {
      _userZoom = _controller.currentZoom;
    }
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
    _searcher?.dispose();
    _searcher = PdfTextSearcher(controller)..addListener(_onSearchChanged);
    if (_searching && _searchField.text.trim().isNotEmpty) _searcher!.startTextSearch(_searchField.text.trim());
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
      if (widget.openContents && !_contentsOpened && !_desktop) {
        _contentsOpened = true;
        _showContentsSheet();
      }
    });
    final restore = _layout == ReaderLayout.scroll ? _restoreExactPosition() : _frame(page);
    _settle(restore, limit: const Duration(milliseconds: 700)).whenComplete(() {
      if (!mounted) return;
      _controller.addListener(_onViewChanged);
      _viewerReady = true;
      // The first 5s before the bars hide count from when the book is showing.
      if (!_desktop && _chrome) _scheduleHide();
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
    await _settle(
      _controller.goToPosition(
        documentOffset: Offset(pageRect.left + offset.dx * pageRect.width, pageRect.top + offset.dy * pageRect.height),
        zoom: zoom,
      ),
    );
  }

  // --- Navigation -----------------------------------------------------------

  /// Single / Two pages: frames the page (or both facing pages). Scroll:
  /// scrolls to the page's top.
  Future<void> _showPage(int page) async {
    final count = _pageCount;
    if (count == null || !_controller.isReady) return;
    final target = page.clamp(1, count);
    if (_layout == ReaderLayout.scroll) {
      await _controller.goToPage(pageNumber: target);
    } else {
      await _frame(target);
    }
  }

  /// The page, or in Two pages the facing pair that contains it.
  Rect _frameRect(int page) {
    final layouts = _controller.layout.pageLayouts;
    if (!_spread) return layouts[page - 1];
    final start = spreadRowStart(page);
    var rect = layouts[start - 1];
    if (start > 1 && start < layouts.length) rect = rect.expandToInclude(layouts[start]);
    return rect;
  }

  /// Shows [page] at the user's zoom, or with [fit] (or no zoom chosen) zooms
  /// so it fits. If it's then taller than the window, shows its top (its
  /// bottom with [showBottom], or the current height with [keepY]).
  ///
  /// [xOffset]: horizontal position of the view's centre from the left edge of
  /// the previous page (or pair), so running on at a zoom wider than the
  /// window stays on the same side instead of jumping to the middle.
  Future<void> _frame(
    int page, {
    bool fit = false,
    bool keepY = false,
    bool showBottom = false,
    double? xOffset,
  }) async {
    if (!_controller.isReady || page < 1 || page > _controller.pageCount) return;
    if (fit) _userZoom = null;
    final rect = _frameRect(page);
    final view = _controller.viewSize;
    final margin = _controller.params.margin;
    final zoom = _userZoom ?? frameZoom(rect, view, margin);
    var x = rect.center.dx;
    final halfWidth = (view.width / 2 - margin) / zoom;
    if (xOffset != null && rect.width / 2 > halfWidth) {
      x = (rect.left + xOffset).clamp(rect.left + halfWidth, rect.right - halfWidth);
    }
    final halfHeight = (view.height / 2 - margin) / zoom;
    final double y;
    if (rect.height * zoom <= view.height - margin * 2 + 1) {
      y = rect.center.dy;
    } else if (keepY) {
      y = _controller.visibleRect.center.dy;
    } else if (showBottom) {
      y = rect.bottom - halfHeight;
    } else {
      y = rect.top + halfHeight;
    }
    final position = Offset(x, y);
    _framedZoom = zoom;
    _framing = true;
    try {
      await _settle(_controller.goTo(_controller.calcMatrixFor(position, zoom: zoom, viewSize: view)));
    } finally {
      // pdfrx may clamp the zoom; remember what it actually applied.
      if (_controller.isReady) _framedZoom = _controller.currentZoom;
      _framing = false;
    }
  }

  /// Keeps Single / Two pages framed when the window changes size.
  void _onViewSize(Size size) {
    if (size == _viewSize) return;
    final first = _viewSize == null;
    _viewSize = size;
    if (first || _layout == ReaderLayout.scroll) return;
    final center = _panelCenter;
    if (_panelAnimating && center != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_controller.isReady) return;
        _controller.goTo(_controller.calcMatrixFor(center, zoom: _controller.currentZoom), duration: Duration.zero);
      });
      return;
    }
    _resizeTimer?.cancel();
    _resizeTimer = Timer(const Duration(milliseconds: 150), () {
      if (mounted && _viewerReady) _frame(_page ?? 1);
    });
  }

  Future<void> _goToPage(int page) => _showPage(page);

  /// Turns a page (or a pair). [fit]: show it whole, dropping any zoom the
  /// user chose (←/→, PgUp/PgDn); otherwise keep the zoom (↑/↓ running on).
  void _step(int direction, {bool fit = true, bool showBottom = false}) {
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
    if (target == page || (_spread && spreadRowStart(target) == spreadRowStart(page))) return;
    if (_layout == ReaderLayout.scroll) {
      _showPage(target);
    } else {
      final xOffset = fit ? null : _controller.visibleRect.center.dx - _frameRect(page).left;
      _frame(target, fit: fit, showBottom: showBottom, xOffset: xOffset);
    }
  }

  /// ↑ / ↓: scrolls through the page; at its bottom (top) moves on to the next
  /// page (the bottom of the previous one).
  void _scrollStep(int direction) {
    if (!_controller.isReady) return;
    final visible = _controller.visibleRect;
    final step = visible.height * 0.15;
    var centerY = visible.center.dy + direction * step;
    if (_layout != ReaderLayout.scroll) {
      final page = _page;
      if (page == null) return;
      final rect = _frameRect(page);
      final edge = _controller.params.margin / _controller.currentZoom;
      if (direction > 0) {
        if (visible.bottom >= rect.bottom - 1) return _step(1, fit: false);
        centerY = math.min(centerY, rect.bottom + edge - visible.height / 2);
      } else {
        if (visible.top <= rect.top + 1) return _step(-1, fit: false, showBottom: true);
        centerY = math.max(centerY, rect.top - edge + visible.height / 2);
      }
    }
    _controller.goTo(
      _controller.calcMatrixFor(Offset(visible.center.dx, centerY), zoom: _controller.currentZoom),
      duration: const Duration(milliseconds: 120),
    );
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
      _userZoom = null;
      setState(() => _viewerGeneration++);
    } else {
      setState(() {});
      if (layout != ReaderLayout.scroll) await _frame(_page ?? 1, fit: true);
    }
    _focusNode.requestFocus();
  }

  /// Page colours cycle Light → Dark → Sepia.
  ReaderTheme get _nextTheme => switch (_store.readerTheme) {
    ReaderTheme.light => ReaderTheme.dark,
    ReaderTheme.dark => ReaderTheme.sepia,
    ReaderTheme.sepia => ReaderTheme.light,
  };

  static String _themeName(ReaderTheme theme) => switch (theme) {
    ReaderTheme.light => 'Light',
    ReaderTheme.dark => 'Dark',
    ReaderTheme.sepia => 'Sepia',
  };

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
    _setBars(true);
    _searchFocus.requestFocus();
    _searchField.selection = TextSelection(baseOffset: 0, extentOffset: _searchField.text.length);
  }

  void _closeSearch() {
    _searcher?.resetTextSearch();
    setState(() => _searching = false);
    if (!_desktop) _scheduleHide();
    _scheduleBarsHide();
    _focusNode.requestFocus();
  }

  void _onSearchChanged() {
    if (mounted) setState(() {});
  }

  void _search(String text) {
    final searcher = _searcher;
    if (searcher == null) return;
    if (text.trim().isEmpty) {
      searcher.resetTextSearch();
    } else {
      searcher.startTextSearch(text.trim());
    }
  }

  String get _searchStatus {
    final searcher = _searcher;
    if (searcher == null || _searchField.text.trim().isEmpty) return '';
    final count = searcher.matches.length;
    final index = searcher.currentIndex;
    if (searcher.isSearching && count == 0) return 'Searching…';
    if (count == 0) return 'No matches';
    final suffix = searcher.isSearching ? '+' : '';
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
      await _window('setFullscreen', on);
    } else {
      _setChrome(!on);
    }
    // Reframe once the window has settled at its new size. Entering full
    // screen in Single zooms so the bars beside the page are half as wide,
    // kept like a chosen zoom (so ↓/↑ keep it); ←/→ fit the page again.
    await Future<void>.delayed(const Duration(milliseconds: 400));
    if (!mounted || !_controller.isReady || _layout == ReaderLayout.scroll) return;
    final page = _page ?? 1;
    if (on && !_spread) {
      _userZoom = frameZoom(_frameRect(page), _controller.viewSize, _controller.params.margin, halveBars: true);
      await _frame(page);
    } else {
      await _frame(page, fit: true);
    }
  }

  void _togglePanel() {
    _resizeTimer?.cancel();
    setState(() {
      _panel = !_panel;
      _panelAnimating = true;
      _panelCenter = _controller.isReady ? _controller.centerPosition : null;
    });
  }

  void _onPanelAnimated() {
    if (!_panelAnimating) return;
    setState(() => _panelAnimating = false);
    // Glide to the fit for the new width (keeps a zoom the user chose).
    if (_viewerReady && _layout != ReaderLayout.scroll) _frame(_page ?? 1);
  }

  // --- Desktop bars ---------------------------------------------------------

  double? _pinchStartZoom;
  Offset? _pinchFocus;

  /// The bars sit over the page; wheel scrolls and touchpad pinches or
  /// two-finger scrolls made over them go to the page instead of being lost.
  Widget _passToPage(Widget bar) {
    return Listener(
      onPointerSignal: (event) {
        if (_controller.isReady) _controller.handlePointerSignalEvent(event);
      },
      onPointerPanZoomStart: (event) {
        if (!_controller.isReady) return;
        _pinchStartZoom = _controller.currentZoom;
        _pinchFocus = _controller.globalToDocument(event.position) ?? _controller.centerPosition;
      },
      onPointerPanZoomUpdate: (event) {
        final start = _pinchStartZoom, focus = _pinchFocus;
        if (start == null || focus == null || !_controller.isReady) return;
        final zoom = (start * event.scale).clamp(_controller.minScale, _controller.maxScale);
        final center = _controller.centerPosition - event.localPanDelta / zoom;
        // Zoom around the pinch point, then apply the two-finger pan.
        final around = focus + (center - focus) * (_controller.currentZoom / zoom);
        _controller.goTo(_controller.calcMatrixFor(around, zoom: zoom), duration: Duration.zero);
      },
      onPointerPanZoomEnd: (_) {
        _pinchStartZoom = null;
        _pinchFocus = null;
      },
      child: bar,
    );
  }

  void _showBars() {
    _setBars(true);
    _scheduleBarsHide();
  }

  void _setBars(bool visible) {
    if (_bars == visible) return;
    setState(() => _bars = visible);
  }

  /// Hides the toolbar and footer after [_barsDelay] without activity. While
  /// the search bar is open or the page box is being typed in, checks again
  /// later instead.
  void _scheduleBarsHide() {
    _barsTimer?.cancel();
    _barsTimer = Timer(_barsDelay, () {
      if (!mounted) return;
      if (_searching || _pageFieldFocus.hasFocus) return _scheduleBarsHide();
      _barsHiddenOnce = true;
      _setBars(false);
    });
  }

  // --- Touch chrome -----------------------------------------------------------

  /// Touch layout: the bars have hidden at least once since the book opened.
  bool _chromeHiddenOnce = false;

  /// 5s the first time, while the reader is new; 3s after that.
  Duration get _chromeDelay => _chromeHiddenOnce ? const Duration(seconds: 3) : const Duration(seconds: 5);

  /// Touch layout: hides the bars after [_chromeDelay]. While search, the
  /// resume prompt or a slider drag needs them, it checks again later instead
  /// of giving up, so they always go away in the end.
  void _scheduleHide() {
    _hideTimer?.cancel();
    _hideTimer = Timer(_chromeDelay, () {
      if (!mounted || _desktop) return;
      if (_offeredJump != null || _searching || _sliderPage != null) return _scheduleHide();
      _chromeHiddenOnce = true;
      _setChrome(false);
    });
  }

  /// Shows or hides the touch bars; shown, they hide again after [_chromeDelay].
  void _setChrome(bool visible) {
    _hideTimer?.cancel();
    if (visible) _scheduleHide();
    if (_chrome == visible) return;
    setState(() => _chrome = visible);
    if (Platform.isAndroid) {
      SystemChrome.setEnabledSystemUIMode(visible ? SystemUiMode.edgeToEdge : SystemUiMode.immersiveSticky);
    }
  }

  /// Touching the bars restarts their countdown, so they don't go mid-tap.
  Widget _keepBars(Widget bars) => Listener(onPointerDown: (_) => _scheduleHide(), child: bars);

  bool _onTap(BuildContext context, PdfViewerController controller, PdfViewerGeneralTapHandlerDetails details) {
    if (_desktop || details.type != PdfViewerGeneralTapType.tap || _searching) return false;
    _setChrome(!_chrome);
    return false;
  }

  Future<void> _showContentsSheet({int tab = 0}) async {
    final document = _document;
    if (document == null) return;
    _hideTimer?.cancel();
    await showTabletContents(
      context,
      book: _book,
      cover: _cover,
      outline: _outline,
      page: _page ?? _book.lastPage,
      pageCount: _pageCount ?? document.pages.length,
      document: document,
      store: _store,
      initialTab: tab,
      onGo: _goToPage,
      onRemoveBookmark: (p) => _store.toggleBookmark(_book.id, p).then((_) => _sync.syncNow()),
    );
    if (mounted) _scheduleHide();
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

  void _paintSearchMatches(Canvas canvas, Rect pageRect, PdfPage page) =>
      _searcher?.pageTextMatchPaintCallback(canvas, pageRect, page);

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
          _paintSearchMatches,
        ],
        onViewerReady: _onViewerReady,
        onPageChanged: _onPageChanged,
        onGeneralTap: _onTap,
        textSelectionParams: PdfTextSelectionParams(onTextSelectionChange: _onTextSelectionChange),
        // Keys are handled in _onKey, so ↑/↓ can continue onto the next page.
        keyHandlerParams: const PdfViewerKeyHandlerParams(enabled: false),
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
      chapter: _outline.chapterAt(record.page)?.title,
    );
  }

  static const _shortcuts = [
    ('← → / PgUp PgDn', 'Previous / next page'),
    ('↑ ↓', 'Scroll; past the edge, previous / next page'),
    ('Home / End', 'First / last page'),
    ('Ctrl+F', 'Search in book'),
    ('Select text', 'Copies it'),
    ('Ctrl+C / Ctrl+A', 'Copy the selection / select all text'),
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
    final focused = FocusManager.instance.primaryFocus?.context;
    final typing = focused != null && focused.findAncestorStateOfType<EditableTextState>() != null;
    if (keyboard.isControlPressed && !typing) {
      // pdfrx's own key handler is off (see keyHandlerParams), so copy and
      // select all are handled here; in the search box they stay the box's.
      if (key == LogicalKeyboardKey.keyC) {
        _copyWithKeys();
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.keyA) {
        _controller.textSelectionDelegate.selectAllText();
        return KeyEventResult.handled;
      }
    }
    if (keyboard.isControlPressed) {
      final VoidCallback? action = switch (key) {
        LogicalKeyboardKey.keyF => _openSearch,
        LogicalKeyboardKey.keyD => _toggleBookmark,
        LogicalKeyboardKey.keyB => _togglePanel,
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
      } else if (_controller.textSelectionDelegate.hasSelectedText) {
        _controller.textSelectionDelegate.clearTextSelection();
      } else if (_offeredJump != null) {
        _declineJump();
      } else if (_fullscreen) {
        _toggleFullscreen();
      } else {
        return KeyEventResult.ignored;
      }
      return KeyEventResult.handled;
    }
    if (typing) return KeyEventResult.ignored; // typing in the search or page box
    final VoidCallback? action = switch (key) {
      LogicalKeyboardKey.arrowDown => () => _scrollStep(1),
      LogicalKeyboardKey.arrowUp => () => _scrollStep(-1),
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
                    _searcher?.goToPrevMatch();
                  } else {
                    _searcher?.goToNextMatch();
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
              onPressed: _searcher?.hasMatches == true ? () => _searcher?.goToPrevMatch() : null,
            ),
            IconButton(
              tooltip: 'Next match (Enter)',
              color: _Chrome.text,
              icon: const Icon(Icons.keyboard_arrow_down),
              onPressed: _searcher?.hasMatches == true ? () => _searcher?.goToNextMatch() : null,
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
    final insets = MediaQuery.paddingOf(context);
    final bookmarked = _store.isBookmarked(_book.id, page);
    final shown = (_sliderPage ?? page).round();
    const duration = Duration(milliseconds: 220);
    return Scaffold(
      body: Stack(
        children: [
          Positioned.fill(child: _viewer()),
          // A soft shade under the top bar so it reads on white pages.
          Positioned(
            left: 0,
            right: 0,
            top: 0,
            height: insets.top + 150,
            child: IgnorePointer(
              child: AnimatedOpacity(
                duration: duration,
                opacity: _chrome ? 1 : 0,
                child: const DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [Color(0x590A0E10), Color(0x000A0E10)],
                    ),
                  ),
                ),
              ),
            ),
          ),
          // Floating top bar (and the search strip under it).
          AnimatedPositioned(
            duration: duration,
            curve: Curves.easeOutCubic,
            left: 16,
            right: 16,
            top: _chrome ? insets.top + 12 : -(insets.top + 200),
            child: _keepBars(
              Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  ReaderGlass(
                    radius: 26,
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                    child: Row(
                      children: [
                        GlassIconButton(
                          icon: Icons.chevron_left_rounded,
                          iconSize: 28,
                          size: 52,
                          border: false,
                          background: const Color(0x12FFFFFF),
                          tooltip: 'Back to library',
                          onPressed: () => Navigator.maybePop(context),
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                _book.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  color: TabletColors.text,
                                  fontSize: 17,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              if (chapter != null)
                                Text(
                                  chapterLine(chapter),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(color: TabletColors.dim, fontSize: 14),
                                ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 6),
                        GlassIconButton(
                          icon: Icons.search_rounded,
                          size: 52,
                          border: false,
                          background: _searching ? const Color(0x295EEAD4) : Colors.transparent,
                          foreground: _searching ? TabletColors.accent : TabletColors.text,
                          tooltip: 'Search in book',
                          onPressed: _searching ? _closeSearch : _openSearch,
                        ),
                        const SizedBox(width: 6),
                        GlassIconButton(
                          icon: bookmarked ? Icons.bookmark_rounded : Icons.bookmark_border_rounded,
                          size: 52,
                          border: false,
                          background: bookmarked ? const Color(0x295EEAD4) : Colors.transparent,
                          foreground: bookmarked ? TabletColors.accent : TabletColors.text,
                          tooltip: bookmarked ? 'Remove bookmark' : 'Bookmark this page',
                          onPressed: _toggleBookmark,
                        ),
                        const SizedBox(width: 6),
                        GlassIconButton(
                          icon: Icons.format_list_bulleted_rounded,
                          size: 52,
                          border: false,
                          background: Colors.transparent,
                          tooltip: 'Contents, pages and bookmarks',
                          onPressed: _showContentsSheet,
                        ),
                      ],
                    ),
                  ),
                  if (_searching) ...[
                    const SizedBox(height: 8),
                    ReaderGlass(radius: 20, child: _searchStrip(background: Colors.transparent)),
                  ],
                ],
              ),
            ),
          ),
          // Floating bottom panel: slider, where you are, page colour.
          AnimatedPositioned(
            duration: duration,
            curve: Curves.easeOutCubic,
            left: 16,
            right: 16,
            // Search needs the room (and the keyboard covers it anyway).
            bottom: _chrome && !_searching ? insets.bottom + 24 : -340,
            child: _keepBars(
              Stack(
                clipBehavior: Clip.none,
                children: [
                  const Positioned.fill(child: ReaderGlass(radius: 30, child: SizedBox.expand())),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(24, 22, 24, 18),
                    child: count == null
                        ? const SizedBox(height: 48)
                        : Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              TabletPageSlider(
                                page: page,
                                count: count,
                                chapters: _outline.chapters.map((c) => c.page).toList(),
                                document: _document,
                                sectionAt: (p) => _outline.sectionAt(p)?.title,
                                onChanged: (p) {
                                  _hideTimer?.cancel();
                                  setState(() => _sliderPage = p.toDouble());
                                },
                                onChangeEnd: (p) {
                                  setState(() => _sliderPage = null);
                                  _goToPage(p);
                                  _scheduleHide();
                                },
                              ),
                              const SizedBox(height: 14),
                              Row(
                                crossAxisAlignment: CrossAxisAlignment.baseline,
                                textBaseline: TextBaseline.alphabetic,
                                children: [
                                  Text.rich(
                                    TextSpan(
                                      text: 'Page $shown',
                                      children: [
                                        TextSpan(
                                          text: ' of $count',
                                          style: const TextStyle(
                                            fontWeight: FontWeight.normal,
                                            color: TabletColors.dim,
                                          ),
                                        ),
                                      ],
                                    ),
                                    style: const TextStyle(
                                      color: TabletColors.text,
                                      fontSize: 17,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: Text(
                                      _leftText(shown, count),
                                      textAlign: TextAlign.end,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(color: TabletColors.dim, fontSize: 14),
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 18),
                              Row(
                                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                children: [
                                  // Takes the width it needs; scrolls only on a narrow screen.
                                  Flexible(
                                    child: SingleChildScrollView(
                                      scrollDirection: Axis.horizontal,
                                      child: ReaderThemeSegment(value: _store.readerTheme, onChanged: _setTheme),
                                    ),
                                  ),
                                  const SizedBox(width: 10),
                                  Material(
                                    color: Colors.transparent,
                                    shape: const StadiumBorder(side: BorderSide(color: Color(0x1FFFFFFF))),
                                    child: InkWell(
                                      customBorder: const StadiumBorder(),
                                      onTap: () => _showContentsSheet(tab: 1),
                                      child: const SizedBox(
                                        height: 50,
                                        child: Padding(
                                          padding: EdgeInsets.symmetric(horizontal: 18),
                                          child: Row(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              Icon(Icons.grid_view_outlined, size: 20, color: TabletColors.text),
                                              SizedBox(width: 8),
                                              Text(
                                                'Pages',
                                                style: TextStyle(
                                                  color: TabletColors.text,
                                                  fontSize: 15,
                                                  fontWeight: FontWeight.w600,
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                  ),
                ],
              ),
            ),
          ),
          if (offer != null)
            Positioned.fill(
              child: TabletResumeCard(
                offer: offer,
                document: _document,
                localChapter: _outline.chapterAt(offer.currentPage)?.title,
                localWhen: _localReadAt,
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

  /// "13 pages left in this chapter", or in the book after the last chapter.
  String _leftText(int page, int count) {
    final next = _outline.nextChapterPage(page);
    final left = (next ?? count + 1) - page - (next == null ? 1 : 0);
    if (left <= 0) return next == null ? 'Last page' : 'Last page of this chapter';
    return '$left page${left == 1 ? '' : 's'} left${next == null ? '' : ' in this chapter'}';
  }

  String get _percentRead {
    final page = _page ?? _book.lastPage;
    final count = _pageCount ?? 1;
    return '${((page - 1) / (count > 1 ? count - 1 : 1) * 100).round()}%';
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
    final toolbar = Container(
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
            onPressed: _togglePanel,
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
                // Always two lines, so the toolbar (and the page area
                // under it) keeps its height when the chapter changes.
                Text(
                  chapter ?? ' ',
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
              _GroupButton(tooltip: 'Zoom in (Ctrl+=)', label: '+', large: true, onPressed: () => _controller.zoomUp()),
            ],
          ),
          const SizedBox(width: 8),
          _Group(
            padding: const EdgeInsets.all(4),
            children: [
              for (final (layout, label, icon) in const [
                (ReaderLayout.single, 'Single', Icons.crop_portrait),
                (ReaderLayout.spread, 'Two pages', Icons.auto_stories_outlined),
              ])
                _Segment(
                  label: compact ? null : label,
                  icon: compact ? icon : null,
                  tooltip: label,
                  selected: _layout == layout,
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
          _ChromeIcon(
            tooltip: 'Page colour: ${_themeName(_store.readerTheme)} (click for ${_themeName(_nextTheme)})',
            // Shows the colour a click switches to.
            icon: switch (_nextTheme) {
              ReaderTheme.dark => Icons.dark_mode_outlined,
              ReaderTheme.sepia => Icons.coffee_outlined,
              ReaderTheme.light => Icons.light_mode_outlined,
            },
            onPressed: () => _setTheme(_nextTheme),
          ),
          _ChromeIcon(
            tooltip: _fullscreen ? 'Exit full screen (F11)' : 'Full screen (F11)',
            icon: _fullscreen ? Icons.fullscreen_exit : Icons.fullscreen,
            onPressed: _toggleFullscreen,
          ),
        ],
      ),
    );
    final body = Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (document != null)
          AnimatedContainer(
            duration: _panelDuration,
            curve: Curves.easeInOutCubic,
            width: _panel ? _panelWidth : 0,
            clipBehavior: Clip.hardEdge,
            decoration: const BoxDecoration(
              color: _Chrome.panel,
              border: Border(right: BorderSide(color: _Chrome.line)),
            ),
            onEnd: _onPanelAnimated,
            // The content keeps its full width and is revealed as the panel
            // widens, rather than being squeezed.
            child: OverflowBox(
              alignment: Alignment.centerRight,
              minWidth: _panelWidth,
              maxWidth: _panelWidth,
              child: !_panel && !_panelAnimating
                  ? const SizedBox()
                  : AnimatedPadding(
                      duration: const Duration(milliseconds: 200),
                      // Clear of the toolbar and footer while they show.
                      padding: EdgeInsets.fromLTRB(10, _bars ? 76 : 14, 10, _bars ? 40 : 0),
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
            ),
          ),
        Expanded(
          child: Stack(
            children: [
              Positioned.fill(
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    _onViewSize(constraints.biggest);
                    return _viewer();
                  },
                ),
              ),
              AnimatedPositioned(
                duration: const Duration(milliseconds: 200),
                left: 32,
                top: (_bars ? _topBarsHeight : 0) + 32,
                child: IgnorePointer(child: _CopiedToast(visible: _copied)),
              ),
              if (offer != null)
                AnimatedPositioned(
                  duration: const Duration(milliseconds: 200),
                  right: 24,
                  bottom: _bars ? 64 : 24,
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
    );
    final footer = Container(
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
    );
    // Toolbar and footer float over the page and hide after a few seconds;
    // moving the pointer to the top or bottom edge brings them back.
    return Scaffold(
      backgroundColor: _Chrome.page,
      body: MouseRegion(
        onHover: (event) {
          final height = MediaQuery.sizeOf(context).height;
          // Near the top or bottom edge (the toolbar's own height, or less).
          if (event.localPosition.dy < 40 || event.localPosition.dy > height - 32) _showBars();
        },
        child: Stack(
          children: [
            Positioned.fill(child: body),
            AnimatedPositioned(
              duration: const Duration(milliseconds: 200),
              left: 0,
              right: 0,
              top: _bars ? 0 : -160,
              child: MouseRegion(
                // Moving over the bars counts as activity.
                onHover: (_) => _scheduleBarsHide(),
                child: _SizeReporter(
                  onHeight: (height) {
                    if (height != _topBarsHeight) setState(() => _topBarsHeight = height);
                  },
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _passToPage(toolbar),
                      if (_searching) _searchStrip(background: _Chrome.group),
                    ],
                  ),
                ),
              ),
            ),
            AnimatedPositioned(
              duration: const Duration(milliseconds: 200),
              left: 0,
              right: 0,
              bottom: _bars ? 0 : -60,
              child: MouseRegion(
                // Moving over the bars counts as activity.
                onHover: (_) => _scheduleBarsHide(),
                child: _passToPage(footer),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// --- Desktop chrome pieces ---------------------------------------------------

/// Small dark pill with a teal check: "Copied". Fades and drops in.
class _CopiedToast extends StatelessWidget {
  const _CopiedToast({required this.visible});

  final bool visible;

  @override
  Widget build(BuildContext context) {
    return AnimatedOpacity(
      opacity: visible ? 1 : 0,
      duration: const Duration(milliseconds: 160),
      child: AnimatedSlide(
        offset: visible ? Offset.zero : const Offset(0, -0.25),
        duration: const Duration(milliseconds: 160),
        curve: Curves.easeOutCubic,
        child: Semantics(
          liveRegion: true,
          child: Container(
            height: 40,
            padding: const EdgeInsets.only(left: 10, right: 16),
            decoration: BoxDecoration(
              color: const Color(0xF21D2321),
              borderRadius: BorderRadius.circular(20),
              boxShadow: const [BoxShadow(color: Color(0x66000000), blurRadius: 22, offset: Offset(0, 8))],
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 22,
                  height: 22,
                  decoration: const BoxDecoration(color: Color(0xFF00897B), shape: BoxShape.circle),
                  child: const Icon(Icons.check_rounded, size: 15, color: Colors.white),
                ),
                const SizedBox(width: 9),
                const Text(
                  'Copied',
                  style: TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w600),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Reports its child's laid-out height after each layout.
class _SizeReporter extends SingleChildRenderObjectWidget {
  const _SizeReporter({required this.onHeight, required super.child});

  final ValueChanged<double> onHeight;

  @override
  RenderObject createRenderObject(BuildContext context) => _RenderSizeReporter(onHeight);

  @override
  void updateRenderObject(BuildContext context, _RenderSizeReporter renderObject) => renderObject.onHeight = onHeight;
}

class _RenderSizeReporter extends RenderProxyBox {
  _RenderSizeReporter(this.onHeight);

  ValueChanged<double> onHeight;
  double? _reported;

  @override
  void performLayout() {
    super.performLayout();
    final height = size.height;
    if (height == _reported) return;
    _reported = height;
    WidgetsBinding.instance.addPostFrameCallback((_) => onHeight(height));
  }
}

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

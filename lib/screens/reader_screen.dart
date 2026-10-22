import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pdfrx/pdfrx.dart';

import '../models/book.dart';
import '../services/library_store.dart';
import '../services/page_image_regions.dart';
import '../sync/library_sync.dart';
import '../sync/progress_record.dart';

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
  Timer? _saveTimer;
  int? _page;
  int? _pageCount;

  // Latest exact position, captured on every view change. The viewer's state is
  // disposed before ours, so it can't be read from the controller in dispose().
  Offset? _pageOffset;
  double? _zoom;

  PageImageRegions? _imageRegions;

  /// The other device's position currently offered in the banner.
  ProgressRecord? _offeredJump;
  bool _viewerReady = false;
  ScaffoldMessengerState? _messenger;

  LibrarySync get _sync => widget.librarySync;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _messenger = ScaffoldMessenger.of(context);
  }

  @override
  void initState() {
    super.initState();
    _sync.openBookId = widget.book.id;
    _sync.addListener(_onSyncChanged);
    _sync.checkProgress(widget.book);
  }

  @override
  void dispose() {
    _saveTimer?.cancel();
    _controller.removeListener(_onViewChanged);
    _sync.removeListener(_onSyncChanged);
    if (_sync.openBookId == widget.book.id) _sync.openBookId = null;
    // The banner lives on the app-wide messenger; don't leave it on the library.
    if (_offeredJump != null) _messenger?.clearMaterialBanners();
    _imageRegions?.dispose();
    _saveProgress();
    _focusNode.dispose();
    super.dispose();
  }

  Future<void> _saveProgress() async {
    final page = _page;
    if (page == null) return;
    await widget.store.updateProgress(
      widget.book.id,
      page: page,
      pageCount: _pageCount,
      pageOffset: _pageOffset,
      zoom: _zoom,
    );
    _sync.progressChanged(widget.book.id);
  }

  /// Shows or hides the "Jump to page X (from …)?" banner as sync finds a
  /// newer position from another device.
  void _onSyncChanged() {
    if (!mounted || !_viewerReady) return;
    final pending = _sync.pendingJumpFor(widget.book.id);
    if (pending?.updated == _offeredJump?.updated && pending?.page == _offeredJump?.page) return;
    final messenger = ScaffoldMessenger.of(context);
    messenger.clearMaterialBanners();
    _offeredJump = pending;
    if (pending == null) return;
    messenger.showMaterialBanner(MaterialBanner(
      leading: const Icon(Icons.devices_outlined),
      content: Text('Jump to page ${pending.page} (from ${pending.device})?'),
      actions: [
        TextButton(onPressed: _declineJump, child: const Text('Stay here')),
        FilledButton.tonal(onPressed: _acceptJump, child: Text('Go to page ${pending.page}')),
      ],
    ));
  }

  Future<void> _acceptJump() async {
    ScaffoldMessenger.of(context).clearMaterialBanners();
    _offeredJump = null;
    final record = await _sync.acceptJump(widget.book.id);
    if (record == null || !mounted || !_controller.isReady) return;
    final offset = record.pageOffset;
    if (offset == null) {
      await _controller.goToPage(pageNumber: record.page.clamp(1, _controller.pageCount));
    } else {
      await _goToPosition(record.page, offset);
    }
    _focusNode.requestFocus();
  }

  Future<void> _declineJump() async {
    ScaffoldMessenger.of(context).clearMaterialBanners();
    _offeredJump = null;
    await _sync.declineJump(widget.book.id);
    _focusNode.requestFocus();
  }

  void _scheduleSave() {
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(seconds: 1), _saveProgress);
  }

  void _onPageChanged(int? page) {
    if (page == null) return;
    setState(() => _page = page);
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
    _imageRegions = PageImageRegions(document, onLoaded: () {
      if (mounted && widget.store.darkReader) setState(() {});
    });
    setState(() {
      _pageCount = document.pages.length;
      _page = controller.pageNumber ?? widget.book.lastPage;
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
    final book = widget.book;
    final x = book.pageOffsetX, y = book.pageOffsetY;
    if (x == null || y == null) return;
    final zoom = book.zoom?.clamp(_controller.minScale, _controller.maxScale);
    await _goToPosition(book.lastPage, Offset(x, y), zoom: zoom);
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

  void _step(int delta) {
    final page = _page;
    final count = _pageCount;
    if (page == null || count == null) return;
    final target = (page + delta).clamp(1, count);
    if (target != page) _controller.goToPage(pageNumber: target);
  }

  Future<void> _showGoToPage() async {
    final count = _pageCount;
    if (count == null) return;
    final input = TextEditingController(text: '${_page ?? 1}');
    final target = await showDialog<int>(
      context: context,
      builder: (context) {
        void submit() => Navigator.pop(context, int.tryParse(input.text));
        return AlertDialog(
          title: const Text('Go to page'),
          content: TextField(
            controller: input,
            autofocus: true,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            decoration: InputDecoration(helperText: '1 – $count'),
            onSubmitted: (_) => submit(),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
            FilledButton(onPressed: submit, child: const Text('Go')),
          ],
        );
      },
    );
    input.dispose();
    if (target != null) await _controller.goToPage(pageNumber: target.clamp(1, count));
    _focusNode.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final page = _page;
    final count = _pageCount;
    final dark = widget.store.darkReader;
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.pageDown): () => _step(1),
        const SingleActivator(LogicalKeyboardKey.pageUp): () => _step(-1),
        const SingleActivator(LogicalKeyboardKey.arrowRight): () => _step(1),
        const SingleActivator(LogicalKeyboardKey.arrowLeft): () => _step(-1),
      },
      child: Focus(
        focusNode: _focusNode,
        autofocus: true,
        child: Scaffold(
          appBar: AppBar(
            title: Text(widget.book.title, overflow: TextOverflow.ellipsis),
            actions: [
              IconButton(
                tooltip: dark ? 'Light pages' : 'Dark pages',
                icon: Icon(dark ? Icons.light_mode_outlined : Icons.dark_mode_outlined),
                onPressed: () async {
                  await widget.store.setDarkReader(!dark);
                  if (mounted) setState(() {});
                },
              ),
              if (page != null && count != null)
                TextButton(
                  onPressed: _showGoToPage,
                  child: Text('$page / $count'),
                ),
              const SizedBox(width: 8),
            ],
          ),
          body: PdfViewer.file(
            widget.store.fileFor(widget.book).path,
            controller: _controller,
            initialPageNumber: widget.book.lastPage,
            params: PdfViewerParams(
              backgroundColor: dark ? const Color(0xFF0B0B0C) : const Color(0xFFD6D6D6),
              pagePaintCallbacks: dark ? [_paintDarkPage] : null,
              onViewerReady: _onViewerReady,
              onPageChanged: _onPageChanged,
            ),
          ),
        ),
      ),
    );
  }
}

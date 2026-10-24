import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/book.dart';
import '../models/shelf.dart';
import '../services/cover_renderer.dart';
import '../services/library_store.dart';
import '../sync/library_sync.dart';
import '../sync/sync_controller.dart';
import 'common.dart';
import 'reader_screen.dart';
import 'sync_button.dart';

enum LibraryFilter {
  all('All books', Icons.auto_stories_outlined),
  reading('Reading now', Icons.schedule),
  finished('Finished', Icons.check),
  cloud('Only in Drive', Icons.cloud_outlined),
  local('On this device', Icons.download_done_outlined);

  const LibraryFilter(this.label, this.icon);

  final String label;
  final IconData icon;

  bool matches(Book book) => switch (this) {
        all => true,
        reading => book.isStarted,
        finished => book.isFinished,
        cloud => !book.isLocal,
        local => book.isLocal,
      };
}

enum LibrarySort {
  recent('Recently read'),
  title('Title'),
  added('Recently added');

  const LibrarySort(this.label);

  final String label;
}

/// Colours of the desktop sidebar, which stays dark in both themes.
abstract final class _Side {
  static const background = Color(0xFF182024);
  static const selected = Color(0xFF263238);
  static const text = Color(0xFFECF1EF);
  static const item = Color(0xFFC5D0CD);
  static const muted = Color(0xFF8A9A96);
  static const accent = Color(0xFF80CBC4);
}

class LibraryScreen extends StatefulWidget {
  const LibraryScreen({super.key, required this.store, required this.sync, required this.librarySync});

  final LibraryStore store;
  final SyncController sync;
  final LibrarySync librarySync;

  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen> {
  late final _covers = CoverRenderer(widget.store);
  final _search = TextEditingController();
  final _searchFocus = FocusNode();
  var _filter = LibraryFilter.all;

  /// Selected shelf; when set it replaces [_filter].
  String? _shelfId;
  var _sort = LibrarySort.recent;
  var _dragging = false;

  LibraryStore get store => widget.store;
  LibrarySync get librarySync => widget.librarySync;

  Shelf? get _shelf => _shelfId == null ? null : store.shelfById(_shelfId!);

  @override
  void initState() {
    super.initState();
    _search.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _search.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  void _select({LibraryFilter filter = LibraryFilter.all, String? shelfId}) => setState(() {
        _filter = filter;
        _shelfId = shelfId;
      });

  // --- Books ----------------------------------------------------------------

  Future<void> _addBooks() async {
    final files = await FilePicker.pickFiles(
      dialogTitle: 'Add PDFs to ShelfSync',
      type: FileType.custom,
      allowedExtensions: ['pdf'],
    );
    await _importPaths([for (final f in files) ?f.path]);
  }

  Future<void> _importPaths(List<String> paths) async {
    final pdfs = paths.where((p) => p.toLowerCase().endsWith('.pdf')).toList();
    final skipped = paths.length - pdfs.length;
    var added = 0, duplicates = 0;
    for (final path in pdfs) {
      try {
        if (await store.importFile(path) == ImportResult.added) {
          added++;
          // Adding while a shelf is open puts the book on it.
          final shelf = _shelf;
          if (shelf != null) await store.setOnShelf(shelf.id, await LibraryStore.hashFile(path), true);
        } else {
          duplicates++;
        }
      } on FileSystemException catch (e) {
        _snack("Couldn't add ${e.path ?? path}: ${e.message}");
      }
    }
    final parts = [
      if (added > 0) 'Added $added book${added == 1 ? '' : 's'}',
      if (duplicates > 0) '$duplicates already in library',
      if (skipped > 0) '$skipped not a PDF',
    ];
    if (parts.isNotEmpty) _snack(parts.join(' · '));
    if (added > 0) librarySync.syncNow();
  }

  Future<void> _showBookMenu(Book book, Offset position) async {
    final inCloud = book.driveFileId != null;
    final shelf = _shelf;
    final action = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(position.dx, position.dy, position.dx, position.dy),
      items: [
        PopupMenuItem(
          value: 'open',
          child: ListTile(
            leading: Icon(book.isLocal ? Icons.menu_book_outlined : Icons.cloud_download_outlined),
            title: Text(book.isLocal ? 'Open' : 'Download and open'),
          ),
        ),
        const PopupMenuItem(
          value: 'rename',
          child: ListTile(leading: Icon(Icons.edit_outlined), title: Text('Rename')),
        ),
        const PopupMenuItem(
          value: 'shelves',
          child: ListTile(leading: Icon(Icons.shelves), title: Text('Shelves…')),
        ),
        if (shelf != null)
          PopupMenuItem(
            value: 'unshelve',
            child: ListTile(leading: const Icon(Icons.remove_circle_outline), title: Text('Remove from ${shelf.name}')),
          ),
        if (inCloud && book.isLocal)
          const PopupMenuItem(
            value: 'remove-local',
            child: ListTile(leading: Icon(Icons.file_download_off_outlined), title: Text('Remove download')),
          ),
        PopupMenuItem(
          value: 'delete',
          child: ListTile(
            leading: const Icon(Icons.delete_outline),
            title: Text(inCloud ? 'Delete everywhere' : 'Remove'),
          ),
        ),
      ],
    );
    if (!mounted) return;
    switch (action) {
      case 'open':
        await _open(book);
      case 'rename':
        await _rename(book);
      case 'shelves':
        await _chooseShelves(book);
      case 'unshelve':
        await _putOnShelf(shelf!, book, false);
      case 'remove-local':
        await store.removeLocalCopy(book.id);
        _snack('Download removed. "${book.title}" stays in Google Drive.');
      case 'delete':
        await _confirmDelete(book);
    }
  }

  Future<String?> _askName({required String title, required String action, String initial = '', String label = 'Name'}) async {
    final input = TextEditingController(text: initial);
    input.selection = TextSelection(baseOffset: 0, extentOffset: initial.length);
    final result = await showDialog<String>(
      context: context,
      builder: (context) {
        void submit() => Navigator.pop(context, input.text);
        return AlertDialog(
          title: Text(title),
          content: SizedBox(
            width: 420,
            child: TextField(
              controller: input,
              autofocus: true,
              textCapitalization: TextCapitalization.sentences,
              decoration: InputDecoration(labelText: label),
              onSubmitted: (_) => submit(),
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
            FilledButton(onPressed: submit, child: Text(action)),
          ],
        );
      },
    );
    input.dispose();
    final name = result?.trim();
    return name == null || name.isEmpty || name == initial ? null : name;
  }

  Future<void> _rename(Book book) async {
    final title = await _askName(title: 'Rename book', action: 'Rename', initial: book.title, label: 'Title');
    if (title != null) await librarySync.rename(book, title);
  }

  Future<void> _confirmDelete(Book book) async {
    final inCloud = book.driveFileId != null;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(inCloud ? 'Delete everywhere?' : 'Remove book?'),
        content: Text(inCloud
            ? '"${book.title}" will be moved to the trash in your Google Drive and removed from all your devices.'
            : '"${book.title}" will be removed from this device.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(inCloud ? 'Delete' : 'Remove'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await librarySync.deleteEverywhere(book);
    } catch (e) {
      _snack(e is StateError ? e.message : "Couldn't delete: $e");
    }
  }

  Future<void> _open(Book book) async {
    if (!book.isLocal) {
      try {
        await librarySync.download(book);
      } catch (e) {
        _snack(e is StateError ? e.message : 'Download failed: $e');
        return;
      }
      if (!book.isLocal || !mounted) return;
    }
    store.markOpened(book.id);
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => ReaderScreen(store: store, librarySync: librarySync, book: book)),
    );
  }

  // --- Shelves --------------------------------------------------------------

  Future<Shelf?> _newShelf() async {
    final name = await _askName(title: 'New shelf', action: 'Create');
    if (name == null) return null;
    final shelf = await store.createShelf(name);
    librarySync.syncNow();
    return shelf;
  }

  Future<void> _putOnShelf(Shelf shelf, Book book, bool on) async {
    await store.setOnShelf(shelf.id, book.id, on);
    librarySync.syncNow();
    _snack(on ? 'Added "${book.title}" to ${shelf.name}' : 'Removed "${book.title}" from ${shelf.name}');
  }

  Future<void> _chooseShelves(Book book) async {
    await showDialog<void>(
      context: context,
      builder: (context) => ListenableBuilder(
        listenable: store,
        builder: (context, _) => AlertDialog(
          title: Text('Shelves for "${book.title}"', maxLines: 2, overflow: TextOverflow.ellipsis),
          content: SizedBox(
            width: 400,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (store.shelves.isEmpty)
                  const Padding(
                    padding: EdgeInsets.only(bottom: 8),
                    child: Text('No shelves yet. Shelves group books, like "Semester 8" or "Novels".'),
                  ),
                for (final shelf in store.shelves)
                  CheckboxListTile(
                    value: shelf.bookIds.contains(book.id),
                    onChanged: (on) {
                      store.setOnShelf(shelf.id, book.id, on ?? false);
                      librarySync.syncNow();
                    },
                    secondary: _ShelfDot(shelf),
                    title: Text(shelf.name),
                  ),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    onPressed: () async {
                      final shelf = await _newShelf();
                      if (shelf != null) await store.setOnShelf(shelf.id, book.id, true);
                    },
                    icon: const Icon(Icons.add),
                    label: const Text('New shelf'),
                  ),
                ),
              ],
            ),
          ),
          actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Done'))],
        ),
      ),
    );
  }

  Future<void> _showShelfMenu(Shelf shelf, Offset position) async {
    final action = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(position.dx, position.dy, position.dx, position.dy),
      items: const [
        PopupMenuItem(value: 'rename', child: ListTile(leading: Icon(Icons.edit_outlined), title: Text('Rename shelf'))),
        PopupMenuItem(value: 'delete', child: ListTile(leading: Icon(Icons.delete_outline), title: Text('Delete shelf'))),
      ],
    );
    if (!mounted) return;
    switch (action) {
      case 'rename':
        final name = await _askName(title: 'Rename shelf', action: 'Rename', initial: shelf.name);
        if (name != null) {
          await store.renameShelf(shelf.id, name);
          librarySync.syncNow();
        }
      case 'delete':
        final confirmed = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text('Delete "${shelf.name}"?'),
            content: const Text('The shelf is removed on all your devices. Its books stay in your library.'),
            actions: [
              TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
              FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Delete')),
            ],
          ),
        );
        if (confirmed != true) return;
        if (_shelfId == shelf.id) _select();
        await store.deleteShelf(shelf.id);
        librarySync.syncNow();
    }
  }

  // --- What to show ---------------------------------------------------------

  int _shelfCount(Shelf shelf) => shelf.bookIds.where((id) => store.byId(id) != null).length;

  List<Book> get _visibleBooks {
    final query = _search.text.trim().toLowerCase();
    final shelf = _shelf;
    final books = store.books
        .where((b) =>
            (shelf == null ? _filter.matches(b) : shelf.bookIds.contains(b.id)) &&
            (query.isEmpty || b.title.toLowerCase().contains(query)))
        .toList();
    switch (_sort) {
      case LibrarySort.recent:
        books.sort((a, b) => (b.lastReadAt ?? b.addedAt).compareTo(a.lastReadAt ?? a.addedAt));
      case LibrarySort.title:
        books.sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));
      case LibrarySort.added:
        books.sort((a, b) => b.addedAt.compareTo(a.addedAt));
    }
    return books;
  }

  /// Books being read anywhere, most recent first. Only on the plain view.
  List<Book> get _continueReading {
    if (_filter != LibraryFilter.all || _shelf != null || _search.text.trim().isNotEmpty) return const [];
    return store.books.where((b) => b.isStarted).toList()..sort((a, b) => b.lastReadAt!.compareTo(a.lastReadAt!));
  }

  String get _heading => _shelf?.name ?? _filter.label;

  static const _shortcuts = [
    ('Ctrl+O', 'Add PDFs'),
    ('Ctrl+K', 'Search'),
    ('Right-click a book', 'Open, rename, shelves, remove'),
    ('Drag a book onto a shelf', 'Add it to the shelf'),
    ('Drop PDFs on the window', 'Add them to the library'),
    ('?', 'Show this list'),
  ];

  @override
  Widget build(BuildContext context) {
    final desktop = useDesktopLayout(context);
    final body = ListenableBuilder(
      listenable: Listenable.merge([store, librarySync]),
      builder: (context, _) {
        if (_shelfId != null && _shelf == null) _shelfId = null; // deleted elsewhere
        return desktop ? _desktop(context) : _touch(context);
      },
    );
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyO, control: true): _addBooks,
        const SingleActivator(LogicalKeyboardKey.keyK, control: true): _searchFocus.requestFocus,
        const SingleActivator(LogicalKeyboardKey.keyF, control: true): _searchFocus.requestFocus,
        const CharacterActivator('?'): () => showShortcutsDialog(context, _shortcuts),
      },
      child: Focus(
        autofocus: true,
        child: !desktop
            ? body
            : DropTarget(
                onDragEntered: (_) => setState(() => _dragging = true),
                onDragExited: (_) => setState(() => _dragging = false),
                onDragDone: (details) {
                  setState(() => _dragging = false);
                  _importPaths([for (final f in details.files) f.path]);
                },
                child: Stack(children: [body, if (_dragging) const _DropOverlay()]),
              ),
      ),
    );
  }

  // --- Tablet ---------------------------------------------------------------

  Widget _touch(BuildContext context) {
    final theme = Theme.of(context);
    final books = _visibleBooks;
    final current = _continueReading;
    final localLabel = Platform.isAndroid ? 'On this tablet' : 'On this device';
    final chips = <Widget>[
      _Pill(label: 'All', selected: _shelfId == null && _filter == LibraryFilter.all, onTap: () => _select()),
      _Pill(
        label: localLabel,
        selected: _shelfId == null && _filter == LibraryFilter.local,
        onTap: () => _select(filter: LibraryFilter.local),
      ),
      _Pill(
        label: 'Finished',
        selected: _shelfId == null && _filter == LibraryFilter.finished,
        onTap: () => _select(filter: LibraryFilter.finished),
      ),
      for (final shelf in store.shelves)
        _Pill(
          label: shelf.name,
          dot: Color(shelfColors[shelf.color % shelfColors.length]),
          selected: _shelfId == shelf.id,
          onTap: () => _select(shelfId: shelf.id),
          onMenu: (position) => _showShelfMenu(shelf, position),
        ),
      _Pill(label: '+ New shelf', selected: false, onTap: () async {
        final shelf = await _newShelf();
        if (shelf != null) _select(shelfId: shelf.id);
      }),
    ];
    return Scaffold(
      floatingActionButton: FloatingActionButton.extended(
        backgroundColor: theme.colorScheme.inverseSurface,
        foregroundColor: theme.colorScheme.onInverseSurface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        onPressed: _addBooks,
        icon: const Icon(Icons.add),
        label: const Text('Add PDF', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
      ),
      body: SafeArea(
        bottom: false,
        child: RefreshIndicator(
          onRefresh: librarySync.syncNow,
          notificationPredicate: (n) => n.depth == 0 && widget.sync.status == SyncStatus.connected,
          child: CustomScrollView(
            physics: const AlwaysScrollableScrollPhysics(),
            slivers: [
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(32, 28, 32, 0),
                sliver: SliverList.list(children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          'Library',
                          style: theme.textTheme.displaySmall?.copyWith(fontFamily: serifFamily, fontWeight: FontWeight.w600),
                        ),
                      ),
                      SyncButton(sync: widget.sync, librarySync: librarySync),
                      const SizedBox(width: 12),
                      AccountAvatar(sync: widget.sync, librarySync: librarySync),
                    ],
                  ),
                  const SizedBox(height: 28),
                  SearchBar(
                    controller: _search,
                    focusNode: _searchFocus,
                    hintText: 'Search your books',
                    elevation: const WidgetStatePropertyAll(0),
                    constraints: const BoxConstraints(minHeight: 56),
                    leading: const Padding(padding: EdgeInsets.only(left: 8), child: Icon(Icons.search)),
                    trailing: [
                      if (_search.text.isNotEmpty)
                        IconButton(tooltip: 'Clear', icon: const Icon(Icons.close), onPressed: _search.clear),
                    ],
                  ),
                  if (current.isNotEmpty) ...[
                    const SizedBox(height: 32),
                    const _SectionLabel('Continue reading', size: 15),
                    const SizedBox(height: 14),
                    _ContinueHero(
                      book: current.first,
                      cover: _covers.coverFor(current.first),
                      transfer: librarySync.transferFor(current.first.id),
                      onOpen: () => _open(current.first),
                    ),
                  ],
                  const SizedBox(height: 32),
                  Row(
                    children: [
                      _SectionLabel(_shelf?.name ?? (_filter == LibraryFilter.all ? 'All books' : _heading), size: 15),
                      const SizedBox(width: 16),
                      Expanded(
                        child: SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          reverse: true,
                          child: Row(
                            children: [
                              for (final chip in chips) Padding(padding: const EdgeInsets.only(left: 10), child: chip),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 18),
                ]),
              ),
              _grid(
                books,
                padding: const EdgeInsets.fromLTRB(32, 0, 32, 120),
                maxExtent: 190,
                aspect: 0.56,
                spacing: (28, 22),
                tile: (book) => _TabletTile(
                  book: book,
                  cover: _covers.coverFor(book),
                  transfer: librarySync.transferFor(book.id),
                  onTap: () => _open(book),
                  onMenu: (position) => _showBookMenu(book, position),
                ),
                emptyHint: 'Tap "Add PDF" to import a book.',
              ),
            ],
          ),
        ),
      ),
    );
  }

  // --- Desktop --------------------------------------------------------------

  Widget _desktop(BuildContext context) {
    final theme = Theme.of(context);
    final books = _visibleBooks;
    final current = _continueReading;
    final counts = {for (final f in LibraryFilter.values) f: store.books.where(f.matches).length};
    final border = theme.colorScheme.outlineVariant;
    return Scaffold(
      body: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _Sidebar(
            filter: _shelfId == null ? _filter : null,
            shelfId: _shelfId,
            counts: counts,
            shelves: [for (final s in store.shelves) (s, _shelfCount(s))],
            onFilter: (f) => _select(filter: f),
            onShelf: (s) => _select(shelfId: s.id),
            onShelfMenu: _showShelfMenu,
            onNewShelf: () async {
              final shelf = await _newShelf();
              if (shelf != null) _select(shelfId: shelf.id);
            },
            onDropOnShelf: (shelf, bookId) {
              final book = store.byId(bookId);
              if (book != null) _putOnShelf(shelf, book, true);
            },
            account: SidebarAccount(sync: widget.sync, librarySync: librarySync),
          ),
          Expanded(
            child: CustomScrollView(
              slivers: [
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(40, 28, 40, 0),
                  sliver: SliverList.list(children: [
                    Wrap(
                      crossAxisAlignment: WrapCrossAlignment.center,
                      spacing: 12,
                      runSpacing: 12,
                      children: [
                        ConstrainedBox(
                          constraints: const BoxConstraints(minWidth: 220),
                          child: Text(
                            _heading,
                            style: theme.textTheme.headlineMedium?.copyWith(fontFamily: serifFamily, fontWeight: FontWeight.w600),
                          ),
                        ),
                        SizedBox(
                          width: 320,
                          height: 42,
                          child: TextField(
                            controller: _search,
                            focusNode: _searchFocus,
                            style: const TextStyle(fontSize: 15),
                            decoration: InputDecoration(
                              hintText: 'Search books',
                              prefixIcon: const Icon(Icons.search, size: 18),
                              suffixIcon: _search.text.isEmpty
                                  ? const Padding(padding: EdgeInsets.all(10), child: _Kbd('Ctrl K'))
                                  : IconButton(tooltip: 'Clear', icon: const Icon(Icons.close, size: 18), onPressed: _search.clear),
                              isDense: true,
                              filled: true,
                              fillColor: theme.colorScheme.surface,
                              contentPadding: const EdgeInsets.symmetric(vertical: 10),
                              enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: border)),
                              focusedBorder: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(10),
                                borderSide: BorderSide(color: theme.colorScheme.primary, width: 1.5),
                              ),
                            ),
                          ),
                        ),
                        PopupMenuButton<LibrarySort>(
                          tooltip: 'Sort',
                          initialValue: _sort,
                          onSelected: (s) => setState(() => _sort = s),
                          itemBuilder: (_) => [for (final s in LibrarySort.values) PopupMenuItem(value: s, child: Text(s.label))],
                          child: Container(
                            height: 42,
                            padding: const EdgeInsets.only(left: 14, right: 8),
                            decoration: BoxDecoration(
                              color: theme.colorScheme.surface,
                              border: Border.all(color: border),
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [Text('Sort: ${_sort.label}', style: const TextStyle(fontSize: 15)), const Icon(Icons.arrow_drop_down)],
                            ),
                          ),
                        ),
                        SizedBox(
                          height: 42,
                          child: FilledButton.icon(
                            style: FilledButton.styleFrom(
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                              textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                            ),
                            onPressed: _addBooks,
                            icon: const Icon(Icons.add, size: 20),
                            label: const Text('Add PDF'),
                          ),
                        ),
                      ],
                    ),
                    if (current.isNotEmpty) ...[
                      const SizedBox(height: 30),
                      const _SectionLabel('Continue reading'),
                      const SizedBox(height: 14),
                      LayoutBuilder(builder: (context, constraints) {
                        final columns = ((constraints.maxWidth + 16) / 316).floor().clamp(1, 3);
                        final shown = current.take(columns).toList();
                        return Row(
                          children: [
                            for (var i = 0; i < columns; i++) ...[
                              if (i > 0) const SizedBox(width: 16),
                              Expanded(
                                child: i < shown.length
                                    ? _ContinueCard(book: shown[i], cover: _covers.coverFor(shown[i]), onOpen: () => _open(shown[i]))
                                    : const SizedBox(),
                              ),
                            ],
                          ],
                        );
                      }),
                    ],
                    const SizedBox(height: 30),
                    _SectionLabel(current.isEmpty ? 'Books' : 'Library'),
                    const SizedBox(height: 14),
                  ]),
                ),
                _grid(
                  books,
                  padding: const EdgeInsets.fromLTRB(40, 0, 40, 40),
                  maxExtent: 160,
                  aspect: 0.64,
                  spacing: (24, 20),
                  tile: (book) => _DesktopTile(
                    book: book,
                    cover: _covers.coverFor(book),
                    transfer: librarySync.transferFor(book.id),
                    onTap: () => _open(book),
                    onMenu: (position) => _showBookMenu(book, position),
                  ),
                  emptyHint: _shelf != null
                      ? 'Drag books onto "${_shelf!.name}" in the sidebar, or right-click a book → Shelves.'
                      : 'Click "Add PDF" or drop PDF files anywhere in this window.',
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _grid(
    List<Book> books, {
    required EdgeInsets padding,
    required double maxExtent,
    required double aspect,
    required (double, double) spacing,
    required Widget Function(Book) tile,
    required String emptyHint,
  }) {
    if (books.isEmpty) {
      final libraryEmpty = store.books.isEmpty;
      return SliverFillRemaining(
        hasScrollBody: false,
        child: _EmptyState(
          title: libraryEmpty ? 'Your library is empty' : (_shelf != null ? 'This shelf is empty' : 'No books here'),
          hint: libraryEmpty || _shelf != null ? emptyHint : 'Try another filter or search.',
        ),
      );
    }
    return SliverPadding(
      padding: padding,
      sliver: SliverGrid.builder(
        gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
          maxCrossAxisExtent: maxExtent,
          mainAxisSpacing: spacing.$1,
          crossAxisSpacing: spacing.$2,
          childAspectRatio: aspect,
        ),
        itemCount: books.length,
        itemBuilder: (context, i) => tile(books[i]),
      ),
    );
  }
}

// --- Small pieces -----------------------------------------------------------

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text, {this.size = 13});

  final String text;
  final double size;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Text(
      text.toUpperCase(),
      style: TextStyle(
        fontSize: size,
        letterSpacing: 1,
        fontWeight: FontWeight.w600,
        color: theme.colorScheme.onSurfaceVariant,
      ),
    );
  }
}

class _Kbd extends StatelessWidget {
  const _Kbd(this.keys);

  final String keys;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(color: theme.colorScheme.surfaceContainerHighest, borderRadius: BorderRadius.circular(5)),
      child: Text(keys, style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
    );
  }
}

class _ShelfDot extends StatelessWidget {
  const _ShelfDot(this.shelf);

  final Shelf shelf;

  @override
  Widget build(BuildContext context) => Container(
        width: 10,
        height: 10,
        decoration: BoxDecoration(
          color: Color(shelfColors[shelf.color % shelfColors.length]),
          borderRadius: BorderRadius.circular(3),
        ),
      );
}

/// Tablet filter pill: filled dark when selected, outlined otherwise.
class _Pill extends StatelessWidget {
  const _Pill({required this.label, required this.selected, required this.onTap, this.dot, this.onMenu});

  final String label;
  final bool selected;
  final VoidCallback onTap;
  final Color? dot;
  final ValueChanged<Offset>? onMenu;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return GestureDetector(
      onLongPressStart: onMenu == null ? null : (d) => onMenu!(d.globalPosition),
      onSecondaryTapUp: onMenu == null ? null : (d) => onMenu!(d.globalPosition),
      child: Material(
        color: selected ? scheme.inverseSurface : Colors.transparent,
        shape: StadiumBorder(side: selected ? BorderSide.none : BorderSide(color: scheme.outlineVariant)),
        child: InkWell(
          customBorder: const StadiumBorder(),
          onTap: onTap,
          child: Container(
            height: 40,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            alignment: Alignment.center,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (dot != null) ...[
                  Container(width: 10, height: 10, decoration: BoxDecoration(color: dot, borderRadius: BorderRadius.circular(3))),
                  const SizedBox(width: 8),
                ],
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
                    color: selected ? scheme.onInverseSurface : scheme.onSurface,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.title, required this.hint});

  final String title;
  final String hint;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.auto_stories_outlined, size: 64, color: theme.colorScheme.primary),
          const SizedBox(height: 16),
          Text(title, style: theme.textTheme.titleLarge),
          const SizedBox(height: 8),
          Text(
            hint,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

class _DropOverlay extends StatelessWidget {
  const _DropOverlay();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Positioned.fill(
      child: IgnorePointer(
        child: Container(
          margin: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: scheme.primaryContainer.withValues(alpha: 0.85),
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: scheme.primary, width: 3),
          ),
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.file_download_outlined, size: 64, color: scheme.onPrimaryContainer),
                const SizedBox(height: 12),
                Text(
                  'Drop PDFs to add them',
                  style: Theme.of(context).textTheme.headlineSmall?.copyWith(color: scheme.onPrimaryContainer),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Sidebar extends StatelessWidget {
  const _Sidebar({
    required this.filter,
    required this.shelfId,
    required this.counts,
    required this.shelves,
    required this.onFilter,
    required this.onShelf,
    required this.onShelfMenu,
    required this.onNewShelf,
    required this.onDropOnShelf,
    required this.account,
  });

  final LibraryFilter? filter;
  final String? shelfId;
  final Map<LibraryFilter, int> counts;
  final List<(Shelf, int)> shelves;
  final ValueChanged<LibraryFilter> onFilter;
  final ValueChanged<Shelf> onShelf;
  final void Function(Shelf, Offset) onShelfMenu;
  final VoidCallback onNewShelf;
  final void Function(Shelf, String bookId) onDropOnShelf;
  final Widget account;

  static const _nav = [LibraryFilter.all, LibraryFilter.reading, LibraryFilter.finished, LibraryFilter.cloud];

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 248,
      color: _Side.background,
      padding: const EdgeInsets.fromLTRB(16, 24, 16, 16),
      child: Theme(
        data: ThemeData(colorSchemeSeed: const Color(0xFF00897B), brightness: Brightness.dark),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 24),
              child: Row(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(9),
                    child: Image.asset('assets/icons/shelfsync.png', width: 36, height: 36),
                  ),
                  const SizedBox(width: 12),
                  const Text('ShelfSync', style: TextStyle(color: _Side.text, fontSize: 19, fontWeight: FontWeight.w700)),
                ],
              ),
            ),
            for (final f in _nav)
              _SideItem(
                icon: Icon(f.icon, size: 20),
                label: f.label,
                count: counts[f] ?? 0,
                selected: f == filter,
                height: 44,
                onTap: () => onFilter(f),
              ),
            const Padding(
              padding: EdgeInsets.fromLTRB(12, 22, 12, 8),
              child: Text(
                'SHELVES',
                style: TextStyle(color: _Side.muted, fontSize: 12, fontWeight: FontWeight.w600, letterSpacing: 1),
              ),
            ),
            Expanded(
              child: ListView(
                padding: EdgeInsets.zero,
                children: [
                  for (final (shelf, count) in shelves)
                    DragTarget<String>(
                      onAcceptWithDetails: (d) => onDropOnShelf(shelf, d.data),
                      builder: (context, candidates, _) => _SideItem(
                        icon: _ShelfDot(shelf),
                        label: shelf.name,
                        count: count,
                        selected: shelf.id == shelfId,
                        highlighted: candidates.isNotEmpty,
                        height: 40,
                        onTap: () => onShelf(shelf),
                        onMenu: (position) => onShelfMenu(shelf, position),
                      ),
                    ),
                  _SideItem(
                    icon: const SizedBox(width: 10),
                    label: '+ New shelf',
                    muted: true,
                    height: 40,
                    onTap: onNewShelf,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            account,
          ],
        ),
      ),
    );
  }
}

class _SideItem extends StatelessWidget {
  const _SideItem({
    required this.icon,
    required this.label,
    required this.height,
    required this.onTap,
    this.count,
    this.selected = false,
    this.highlighted = false,
    this.muted = false,
    this.onMenu,
  });

  final Widget icon;
  final String label;
  final double height;
  final VoidCallback onTap;
  final int? count;
  final bool selected;
  final bool highlighted;
  final bool muted;
  final ValueChanged<Offset>? onMenu;

  @override
  Widget build(BuildContext context) {
    final color = muted ? _Side.muted : (selected ? _Side.text : _Side.item);
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: GestureDetector(
        onSecondaryTapUp: onMenu == null ? null : (d) => onMenu!(d.globalPosition),
        onLongPressStart: onMenu == null ? null : (d) => onMenu!(d.globalPosition),
        child: Material(
          color: highlighted ? const Color(0xFF1F3B38) : (selected ? _Side.selected : Colors.transparent),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
            side: highlighted ? const BorderSide(color: _Side.accent) : BorderSide.none,
          ),
          child: InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: onTap,
            child: SizedBox(
              height: height,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Row(
                  children: [
                    IconTheme.merge(data: IconThemeData(color: color), child: icon),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: color, fontSize: 15, fontWeight: selected ? FontWeight.w600 : FontWeight.normal),
                      ),
                    ),
                    if (count != null) Text('$count', style: const TextStyle(color: _Side.muted, fontSize: 14)),
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

String _tabletStatus(Book book, Transfer? transfer) {
  final t = transfer;
  if (t != null) {
    final verb = t.kind == TransferKind.upload ? 'Uploading' : 'Downloading';
    final p = t.progress;
    return p == null ? '$verb…' : '$verb ${(p * 100).round()}%';
  }
  if (book.isFinished) return 'Finished';
  if (book.isStarted) {
    final percent = (book.progress * 100).round();
    return percent == 0 ? 'Just started' : '$percent% read';
  }
  final size = book.sizeBytes;
  return !book.isLocal && size != null ? 'New · ${formatSize(size)}' : 'New';
}

class _TransferOverlay extends StatelessWidget {
  const _TransferOverlay(this.transfer);

  final Transfer transfer;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: Colors.black38,
      child: Center(
        child: SizedBox.square(
          dimension: 40,
          child: CircularProgressIndicator(
            value: transfer.progress,
            strokeWidth: 4,
            color: Colors.white,
            backgroundColor: Colors.white24,
          ),
        ),
      ),
    );
  }
}

/// Tablet grid tile: cover, progress bar and a one-line status.
class _TabletTile extends StatelessWidget {
  const _TabletTile({required this.book, required this.cover, required this.transfer, required this.onTap, required this.onMenu});

  final Book book;
  final Future<File?> cover;
  final Transfer? transfer;
  final VoidCallback onTap;
  final ValueChanged<Offset> onMenu;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final t = transfer;
    return Semantics(
      label: book.title,
      child: GestureDetector(
        onLongPressStart: (d) => onMenu(d.globalPosition),
        onSecondaryTapUp: (d) => onMenu(d.globalPosition),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(child: BookCoverFrame(book: book, cover: cover, overlay: t == null ? null : _TransferOverlay(t))),
              const SizedBox(height: 10),
              ProgressLine(value: book.progress),
              const SizedBox(height: 8),
              Text(
                _tabletStatus(book, t),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Desktop grid tile: cover and a thin progress bar; drag it onto a shelf.
class _DesktopTile extends StatelessWidget {
  const _DesktopTile({required this.book, required this.cover, required this.transfer, required this.onTap, required this.onMenu});

  final Book book;
  final Future<File?> cover;
  final Transfer? transfer;
  final VoidCallback onTap;
  final ValueChanged<Offset> onMenu;

  @override
  Widget build(BuildContext context) {
    final t = transfer;
    final coverWidget = BookCoverFrame(book: book, cover: cover, overlay: t == null ? null : _TransferOverlay(t));
    return Draggable<String>(
      data: book.id,
      dragAnchorStrategy: pointerDragAnchorStrategy,
      feedback: Opacity(
        opacity: 0.85,
        child: SizedBox(width: 70, height: 100, child: BookCoverFrame(book: book, cover: cover)),
      ),
      child: Tooltip(
        message: '${book.title}\n${_tabletStatus(book, t)}',
        waitDuration: const Duration(milliseconds: 500),
        child: GestureDetector(
          onSecondaryTapUp: (d) => onMenu(d.globalPosition),
          onLongPressStart: (d) => onMenu(d.globalPosition),
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(6),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(child: coverWidget),
                const SizedBox(height: 8),
                ProgressLine(value: book.progress, height: 3),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

String _pageLine(Book book) {
  final count = book.pageCount;
  return count == null ? 'Page ${book.lastPage}' : 'Page ${book.lastPage} of $count';
}

/// The big "Continue reading" card on the tablet library.
class _ContinueHero extends StatelessWidget {
  const _ContinueHero({required this.book, required this.cover, required this.transfer, required this.onOpen});

  final Book book;
  final Future<File?> cover;
  final Transfer? transfer;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final t = transfer;
    final last = lastReadLine(book);
    return Card(
      elevation: 2,
      shadowColor: Colors.black26,
      color: theme.colorScheme.surfaceContainerLowest,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      clipBehavior: Clip.antiAlias,
      margin: EdgeInsets.zero,
      child: InkWell(
        onTap: onOpen,
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 150,
                height: 212,
                child: BookCoverFrame(book: book, cover: cover, overlay: t == null ? null : _TransferOverlay(t)),
              ),
              const SizedBox(width: 28),
              Expanded(
                child: SizedBox(
                  height: 212,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        book.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontFamily: serifFamily, fontSize: 26, fontWeight: FontWeight.w600, height: 1.2),
                      ),
                      if (book.chapter != null) ...[
                        const SizedBox(height: 10),
                        Text(book.chapter!, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 16, color: muted)),
                      ],
                      const SizedBox(height: 18),
                      ProgressLine(value: book.progress, height: 8),
                      const SizedBox(height: 8),
                      Text(
                        last == null ? _pageLine(book) : '${_pageLine(book)} · ${last[0].toLowerCase()}${last.substring(1)}',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 15, color: muted),
                      ),
                      const Spacer(),
                      SizedBox(
                        height: 52,
                        child: FilledButton.icon(
                          style: FilledButton.styleFrom(
                            padding: const EdgeInsets.symmetric(horizontal: 28),
                            textStyle: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
                          ),
                          onPressed: onOpen,
                          icon: Icon(book.isLocal ? Icons.play_arrow_rounded : Icons.cloud_download_outlined),
                          label: Text(book.isLocal ? 'Continue' : 'Download and continue'),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Compact "Continue reading" card on the desktop library.
class _ContinueCard extends StatelessWidget {
  const _ContinueCard({required this.book, required this.cover, required this.onOpen});

  final Book book;
  final Future<File?> cover;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final last = lastReadLine(book);
    return Material(
      color: theme.colorScheme.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: theme.colorScheme.outlineVariant),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onOpen,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              SizedBox(width: 64, height: 90, child: BookCoverFrame(book: book, cover: cover)),
              const SizedBox(width: 16),
              Expanded(
                child: SizedBox(
                  height: 90,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        book.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        last?.replaceFirst(', ', ' · ') ?? '',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 14, color: muted),
                      ),
                      const Spacer(),
                      ProgressLine(value: book.progress, height: 5),
                      const SizedBox(height: 6),
                      Text(_pageLine(book), style: TextStyle(fontSize: 13, color: muted)),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

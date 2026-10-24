import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/book.dart';
import '../services/cover_renderer.dart';
import '../services/library_store.dart';
import '../sync/library_sync.dart';
import '../sync/sync_controller.dart';
import 'common.dart';
import 'reader_screen.dart';
import 'sync_button.dart';

enum LibraryFilter {
  all('All books', 'All', Icons.auto_stories_outlined),
  reading('Reading now', 'Reading', Icons.schedule),
  finished('Finished', 'Finished', Icons.check),
  cloud('Only in Drive', 'In Drive', Icons.cloud_outlined),
  local('On this device', 'On this device', Icons.download_done_outlined);

  const LibraryFilter(this.label, this.shortLabel, this.icon);

  final String label;
  final String shortLabel;
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
  var _sort = LibrarySort.recent;
  var _dragging = false;

  LibraryStore get store => widget.store;
  LibrarySync get librarySync => widget.librarySync;

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
      case 'remove-local':
        await store.removeLocalCopy(book.id);
        _snack('Download removed. "${book.title}" stays in Google Drive.');
      case 'delete':
        await _confirmDelete(book);
    }
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

  List<Book> get _visibleBooks {
    final query = _search.text.trim().toLowerCase();
    final books = store.books
        .where((b) => _filter.matches(b) && (query.isEmpty || b.title.toLowerCase().contains(query)))
        .toList();
    switch (_sort) {
      case LibrarySort.recent:
        break; // store order
      case LibrarySort.title:
        books.sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));
      case LibrarySort.added:
        books.sort((a, b) => b.addedAt.compareTo(a.addedAt));
    }
    return books;
  }

  /// Books being read anywhere, most recent first. Only on the plain view.
  List<Book> get _continueReading {
    if (_filter != LibraryFilter.all || _search.text.trim().isNotEmpty) return const [];
    return store.books.where((b) => b.isStarted).toList()
      ..sort((a, b) => b.lastReadAt!.compareTo(a.lastReadAt!));
  }

  _LibraryView _view() => _LibraryView(
        books: _visibleBooks,
        continueReading: _continueReading,
        libraryEmpty: store.books.isEmpty,
        covers: _covers,
        librarySync: librarySync,
        onOpen: _open,
        onMenu: _showBookMenu,
      );

  Widget _sortButton() => PopupMenuButton<LibrarySort>(
        tooltip: 'Sort',
        initialValue: _sort,
        onSelected: (s) => setState(() => _sort = s),
        itemBuilder: (_) => [for (final s in LibrarySort.values) PopupMenuItem(value: s, child: Text(s.label))],
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [const Icon(Icons.sort, size: 20), const SizedBox(width: 6), Text(_sort.label)],
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final desktop = useDesktopLayout(context);
    final body = ListenableBuilder(
      listenable: Listenable.merge([store, librarySync]),
      builder: (context, _) => desktop ? _desktop(context) : _touch(context),
    );
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyO, control: true): _addBooks,
        const SingleActivator(LogicalKeyboardKey.keyK, control: true): _searchFocus.requestFocus,
        const SingleActivator(LogicalKeyboardKey.keyF, control: true): _searchFocus.requestFocus,
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

  Widget _touch(BuildContext context) {
    final theme = Theme.of(context);
    final view = _view();
    return Scaffold(
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _addBooks,
        icon: const Icon(Icons.add),
        label: const Text('Add PDF'),
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
                padding: const EdgeInsets.fromLTRB(24, 20, 24, 0),
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
                    ],
                  ),
                  const SizedBox(height: 20),
                  SearchBar(
                    controller: _search,
                    focusNode: _searchFocus,
                    hintText: 'Search your books',
                    elevation: const WidgetStatePropertyAll(0),
                    leading: const Padding(padding: EdgeInsets.only(left: 8), child: Icon(Icons.search)),
                    trailing: [
                      if (_search.text.isNotEmpty)
                        IconButton(tooltip: 'Clear', icon: const Icon(Icons.close), onPressed: _search.clear),
                    ],
                  ),
                  if (view.continueReading.isNotEmpty) ...[
                    const SizedBox(height: 28),
                    const _SectionLabel('Continue reading'),
                    const SizedBox(height: 12),
                    _ContinueHero(
                      book: view.continueReading.first,
                      cover: _covers.coverFor(view.continueReading.first),
                      transfer: librarySync.transferFor(view.continueReading.first.id),
                      onOpen: () => _open(view.continueReading.first),
                    ),
                  ],
                  const SizedBox(height: 28),
                  Row(
                    children: [
                      Expanded(child: _SectionLabel(_filter.label)),
                      _sortButton(),
                    ],
                  ),
                  const SizedBox(height: 8),
                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: [
                        for (final f in [LibraryFilter.all, LibraryFilter.reading, LibraryFilter.finished, LibraryFilter.local])
                          Padding(
                            padding: const EdgeInsets.only(right: 8),
                            child: ChoiceChip(
                              label: Text(f.shortLabel),
                              selected: _filter == f,
                              onSelected: (_) => setState(() => _filter = f),
                            ),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                ]),
              ),
              ...view.gridSlivers(
                context,
                padding: const EdgeInsets.fromLTRB(24, 0, 24, 112),
                maxExtent: 180,
                emptyHint: 'Tap "Add PDF" to import a book.',
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _desktop(BuildContext context) {
    final theme = Theme.of(context);
    final view = _view();
    final counts = {for (final f in LibraryFilter.values) f: store.books.where(f.matches).length};
    return Scaffold(
      body: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _Sidebar(
            filter: _filter,
            counts: counts,
            onFilter: (f) => setState(() => _filter = f),
            account: SidebarAccount(sync: widget.sync, librarySync: librarySync),
          ),
          Expanded(
            child: CustomScrollView(
              slivers: [
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(40, 28, 40, 0),
                  sliver: SliverList.list(children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            _filter.label,
                            style: theme.textTheme.headlineMedium?.copyWith(fontFamily: serifFamily, fontWeight: FontWeight.w600),
                          ),
                        ),
                        SizedBox(
                          width: 320,
                          height: 44,
                          child: TextField(
                            controller: _search,
                            focusNode: _searchFocus,
                            decoration: InputDecoration(
                              hintText: 'Search books',
                              prefixIcon: const Icon(Icons.search, size: 20),
                              suffixIcon: _search.text.isEmpty
                                  ? const Padding(padding: EdgeInsets.all(10), child: _Kbd('Ctrl K'))
                                  : IconButton(tooltip: 'Clear', icon: const Icon(Icons.close, size: 18), onPressed: _search.clear),
                              isDense: true,
                              filled: true,
                              border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        _sortButton(),
                        const SizedBox(width: 8),
                        FilledButton.icon(onPressed: _addBooks, icon: const Icon(Icons.add), label: const Text('Add PDF')),
                      ],
                    ),
                    if (view.continueReading.isNotEmpty) ...[
                      const SizedBox(height: 28),
                      const _SectionLabel('Continue reading'),
                      const SizedBox(height: 12),
                      LayoutBuilder(builder: (context, constraints) {
                        final columns = (constraints.maxWidth / 340).floor().clamp(1, 3);
                        final books = view.continueReading.take(columns).toList();
                        return Row(
                          children: [
                            for (var i = 0; i < columns; i++) ...[
                              if (i > 0) const SizedBox(width: 16),
                              Expanded(
                                child: i < books.length
                                    ? _ContinueCard(
                                        book: books[i],
                                        cover: _covers.coverFor(books[i]),
                                        onOpen: () => _open(books[i]),
                                      )
                                    : const SizedBox(),
                              ),
                            ],
                          ],
                        );
                      }),
                    ],
                    const SizedBox(height: 28),
                    _SectionLabel(view.continueReading.isEmpty ? 'Books' : 'Library'),
                    const SizedBox(height: 14),
                  ]),
                ),
                ...view.gridSlivers(
                  context,
                  padding: const EdgeInsets.fromLTRB(40, 0, 40, 24),
                  maxExtent: 160,
                  emptyHint: 'Click "Add PDF" or drop PDF files anywhere in this window.',
                ),
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(40, 0, 40, 24),
                  sliver: SliverToBoxAdapter(
                    child: DefaultTextStyle.merge(
                      style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                      child: const Wrap(
                        spacing: 20,
                        runSpacing: 8,
                        children: [
                          Text('Drop PDFs anywhere in this window to add them'),
                          _Hint(keys: 'Ctrl O', text: 'add PDF'),
                          _Hint(keys: 'Ctrl K', text: 'search'),
                          _Hint(keys: 'Right-click', text: 'book options'),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// What both layouts show: the filtered grid, the continue-reading list and
/// the empty states.
class _LibraryView {
  const _LibraryView({
    required this.books,
    required this.continueReading,
    required this.libraryEmpty,
    required this.covers,
    required this.librarySync,
    required this.onOpen,
    required this.onMenu,
  });

  final List<Book> books;
  final List<Book> continueReading;
  final bool libraryEmpty;
  final CoverRenderer covers;
  final LibrarySync librarySync;
  final void Function(Book) onOpen;
  final void Function(Book, Offset) onMenu;

  List<Widget> gridSlivers(
    BuildContext context, {
    required EdgeInsets padding,
    required double maxExtent,
    required String emptyHint,
  }) {
    if (books.isEmpty) {
      return [
        SliverFillRemaining(
          hasScrollBody: false,
          child: _EmptyState(
            title: libraryEmpty ? 'Your library is empty' : 'No books here',
            hint: libraryEmpty ? emptyHint : 'Try another filter or search.',
          ),
        ),
      ];
    }
    return [
      SliverPadding(
        padding: padding,
        sliver: SliverGrid.builder(
          gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
            maxCrossAxisExtent: maxExtent,
            mainAxisSpacing: 28,
            crossAxisSpacing: 20,
            childAspectRatio: 0.5,
          ),
          itemCount: books.length,
          itemBuilder: (context, i) {
            final book = books[i];
            return _BookTile(
              book: book,
              cover: covers.coverFor(book),
              transfer: librarySync.transferFor(book.id),
              onTap: () => onOpen(book),
              onMenu: (position) => onMenu(book, position),
            );
          },
        ),
      ),
    ];
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Text(
      text.toUpperCase(),
      style: theme.textTheme.labelMedium?.copyWith(
        letterSpacing: 1.2,
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
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(5),
      ),
      child: Text(keys, style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
    );
  }
}

class _Hint extends StatelessWidget {
  const _Hint({required this.keys, required this.text});

  final String keys;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Row(mainAxisSize: MainAxisSize.min, children: [_Kbd(keys), const SizedBox(width: 6), Text(text)]);
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
  const _Sidebar({required this.filter, required this.counts, required this.onFilter, required this.account});

  final LibraryFilter filter;
  final Map<LibraryFilter, int> counts;
  final ValueChanged<LibraryFilter> onFilter;
  final Widget account;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: 256,
      color: theme.colorScheme.surfaceContainerLow,
      padding: const EdgeInsets.fromLTRB(14, 24, 14, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 0, 10, 24),
            child: Row(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: Image.asset('assets/icons/shelfsync.png', width: 34, height: 34),
                ),
                const SizedBox(width: 12),
                Text('ShelfSync', style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
              ],
            ),
          ),
          for (final f in LibraryFilter.values)
            Padding(
              padding: const EdgeInsets.only(bottom: 2),
              child: ListTile(
                dense: true,
                selected: f == filter,
                selectedTileColor: theme.colorScheme.secondaryContainer,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                leading: Icon(f.icon, size: 20),
                title: Text(f.label, style: const TextStyle(fontSize: 15)),
                trailing: Text('${counts[f] ?? 0}', style: theme.textTheme.bodySmall),
                onTap: () => onFilter(f),
              ),
            ),
          const Spacer(),
          account,
        ],
      ),
    );
  }
}

String _bookStatus(Book book, Transfer? transfer) {
  final t = transfer;
  if (t != null) {
    final verb = t.kind == TransferKind.upload ? 'Uploading' : 'Downloading';
    final p = t.progress;
    return p == null ? '$verb…' : '$verb ${(p * 100).round()}%';
  }
  final count = book.pageCount;
  if (!book.isLocal && !book.isStarted) {
    final size = book.sizeBytes;
    return size == null ? 'In Google Drive' : 'In Google Drive · ${formatSize(size)}';
  }
  if (book.isFinished) return 'Finished';
  if (!book.isStarted) return count == null ? 'New' : 'New · $count pages';
  if (count == null) return 'Page ${book.lastPage}';
  return '${(book.progress * 100).round()}% · page ${book.lastPage} of $count';
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
          dimension: 44,
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

class _BookTile extends StatelessWidget {
  const _BookTile({
    required this.book,
    required this.cover,
    required this.transfer,
    required this.onTap,
    required this.onMenu,
  });

  final Book book;
  final Future<File?> cover;
  final Transfer? transfer;
  final VoidCallback onTap;
  final ValueChanged<Offset> onMenu;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final t = transfer;
    final showProgress = book.isStarted || book.isFinished;
    return GestureDetector(
      onLongPressStart: (d) => onMenu(d.globalPosition),
      onSecondaryTapUp: (d) => onMenu(d.globalPosition),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: BookCoverFrame(
                book: book,
                cover: cover,
                overlay: t == null ? null : _TransferOverlay(t),
              ),
            ),
            const SizedBox(height: 8),
            SizedBox(height: 4, child: showProgress ? ProgressLine(value: book.progress) : null),
            const SizedBox(height: 8),
            Text(
              book.title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.titleSmall?.copyWith(height: 1.25),
            ),
            const SizedBox(height: 2),
            Text(
              _bookStatus(book, t),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ],
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
    final muted = theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final t = transfer;
    return Card(
      elevation: 0,
      color: theme.colorScheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onOpen,
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 132,
                height: 188,
                child: BookCoverFrame(book: book, cover: cover, overlay: t == null ? null : _TransferOverlay(t)),
              ),
              const SizedBox(width: 24),
              Expanded(
                child: SizedBox(
                  height: 188,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        book.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.headlineSmall?.copyWith(fontFamily: serifFamily, fontWeight: FontWeight.w600),
                      ),
                      if (book.chapter != null) ...[
                        const SizedBox(height: 4),
                        Text(book.chapter!, maxLines: 1, overflow: TextOverflow.ellipsis, style: muted),
                      ],
                      const Spacer(),
                      ProgressLine(value: book.progress, height: 6),
                      const SizedBox(height: 8),
                      Text(
                        [_pageLine(book), ?lastReadLine(book)].join(' · '),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                      ),
                      const SizedBox(height: 14),
                      FilledButton.icon(
                        onPressed: onOpen,
                        icon: Icon(book.isLocal ? Icons.play_arrow_rounded : Icons.cloud_download_outlined),
                        label: Text(book.isLocal ? 'Continue' : 'Download and continue'),
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
    final small = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    return Card(
      elevation: 0,
      color: theme.colorScheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onOpen,
        child: Padding(
          padding: const EdgeInsets.all(14),
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
                      Text(book.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.titleSmall),
                      const SizedBox(height: 4),
                      Text(lastReadLine(book) ?? '', maxLines: 1, overflow: TextOverflow.ellipsis, style: small),
                      const Spacer(),
                      ProgressLine(value: book.progress),
                      const SizedBox(height: 6),
                      Text(_pageLine(book), style: small),
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

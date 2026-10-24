import 'dart:io';
import 'dart:math' show max, min, pi;

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/gestures.dart' show kDoubleTapTimeout, kPrimaryButton;
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

  /// Books picked with Ctrl- or Shift-click on the desktop grid.
  final _picked = <String>{};
  String? _pickAnchor;

  /// Books being dragged onto a shelf; they fade in the grid meanwhile.
  Set<String> _dragIds = const {};

  /// While the sidebar's "Create shelf" form is open: the books to put on the
  /// new shelf (empty when it was opened from the sidebar).
  List<String>? _creatingFor;

  /// The shelf being renamed in the sidebar; it uses the same form.
  String? _editingShelfId;

  /// Last primary click on a sidebar shelf, to spot a double-click (which
  /// renames it) without delaying the single click that opens it.
  (String, Duration)? _lastShelfClick;
  final _shelfName = TextEditingController();
  final _shelfNameFocus = FocusNode();
  var _shelfColor = 0;

  /// Right-click menu of a desktop book.
  final _menu = MenuController();
  final _menuAnchor = GlobalKey();
  Book? _menuBook;

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
    _shelfName.dispose();
    _shelfNameFocus.dispose();
    super.dispose();
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  void _select({LibraryFilter filter = LibraryFilter.all, String? shelfId}) => setState(() {
    _filter = filter;
    _shelfId = shelfId;
    _picked.clear();
    _creatingFor = null;
    _editingShelfId = null;
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

  Future<String?> _askName({
    required String title,
    required String action,
    String initial = '',
    String label = 'Name',
  }) async {
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
        content: Text(
          inCloud
              ? '"${book.title}" will be moved to the trash in your Google Drive and removed from all your devices.'
              : '"${book.title}" will be removed from this device.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(inCloud ? 'Delete' : 'Remove')),
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
      MaterialPageRoute(
        builder: (_) => ReaderScreen(store: store, librarySync: librarySync, book: book),
      ),
    );
  }

  /// Del on a selected book: free the download, or remove a book that only
  /// exists here (after confirming).
  Future<void> _removeWithKey(Book book) async {
    if (book.isLocal && book.driveFileId != null) {
      await store.removeLocalCopy(book.id);
      _snack('Download removed. "${book.title}" stays in Google Drive.');
    } else if (book.isLocal) {
      await _confirmDelete(book);
    }
  }

  // --- Shelves --------------------------------------------------------------

  Future<Shelf?> _newShelf() async {
    final name = await _askName(title: 'Create shelf', action: 'Create');
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
                    child: Text('No shelves yet. Shelves group books, like "Textbooks" or "Novels".'),
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
                    label: const Text('Create shelf'),
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

  /// Opens the sidebar's inline "Create shelf" form; the new shelf gets
  /// [bookIds].
  void _startCreateShelf([List<String> bookIds = const []]) {
    setState(() {
      _creatingFor = bookIds;
      _editingShelfId = null;
      _shelfName.clear();
      _shelfColor = store.nextShelfColor;
    });
    // After a menu closes it hands focus back, so ask once it has.
    WidgetsBinding.instance.addPostFrameCallback((_) => _shelfNameFocus.requestFocus());
  }

  /// Turns the shelf's sidebar row into the name-and-colour form.
  void _startEditShelf(Shelf shelf) {
    setState(() {
      _creatingFor = null;
      _editingShelfId = shelf.id;
      _shelfName.text = shelf.name;
      _shelfName.selection = TextSelection(baseOffset: 0, extentOffset: shelf.name.length);
      _shelfColor = shelf.color % shelfColors.length;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _shelfNameFocus.requestFocus());
  }

  /// Closes the sidebar's create or rename form without saving.
  void _cancelShelfForm() => setState(() {
    _creatingFor = null;
    _editingShelfId = null;
  });

  void _cancelCreateShelf() => _cancelShelfForm();

  Future<void> _finishEditShelf() async {
    final id = _editingShelfId;
    if (id == null) return;
    setState(() => _editingShelfId = null);
    await store.editShelf(id, name: _shelfName.text, color: _shelfColor);
    librarySync.syncNow();
  }

  void _clickShelf(Shelf shelf, Duration at) {
    final last = _lastShelfClick;
    _lastShelfClick = (shelf.id, at);
    if (last != null && last.$1 == shelf.id && at - last.$2 < kDoubleTapTimeout) {
      _lastShelfClick = null;
      _startEditShelf(shelf);
    }
  }

  Future<void> _deleteShelf(Shelf shelf) async {
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
    if (_editingShelfId == shelf.id) _cancelShelfForm();
    await store.deleteShelf(shelf.id);
    librarySync.syncNow();
  }

  /// The desktop rename dialog, with title suggestions from the file name.
  Future<void> _renameBook(Book book) async {
    final title = await showDialog<String>(
      context: context,
      builder: (_) => _RenameBookDialog(book: book, cover: _covers.coverFor(book)),
    );
    final trimmed = title?.trim() ?? '';
    if (trimmed.isNotEmpty && trimmed != book.title) await librarySync.rename(book, trimmed);
  }

  Future<void> _finishCreateShelf() async {
    final bookIds = _creatingFor;
    final name = _shelfName.text.trim();
    if (bookIds == null) return;
    if (name.isEmpty) return _cancelCreateShelf();
    setState(() => _creatingFor = null);
    final shelf = await store.createShelf(name, color: _shelfColor);
    if (bookIds.isEmpty) {
      _select(shelfId: shelf.id);
      librarySync.syncNow();
    } else {
      await _addToShelf(shelf, bookIds);
    }
  }

  Future<void> _addToShelf(Shelf shelf, List<String> bookIds) async {
    final added = await store.addToShelf(shelf.id, bookIds);
    librarySync.syncNow();
    if (!mounted) return;
    setState(_picked.clear);
    final one = bookIds.length == 1 ? store.byId(bookIds.first) : null;
    if (added == 0) {
      _snack(one != null ? '"${one.title}" is already on ${shelf.name}' : 'Already on ${shelf.name}');
    } else {
      _snack(
        one != null
            ? 'Added "${one.title}" to ${shelf.name}'
            : 'Added $added book${added == 1 ? '' : 's'} to ${shelf.name}',
      );
    }
  }

  Future<void> _renameShelf(Shelf shelf) async {
    final name = await _askName(title: 'Rename shelf', action: 'Rename', initial: shelf.name);
    if (name != null) {
      await store.renameShelf(shelf.id, name);
      librarySync.syncNow();
    }
  }

  Future<void> _addBooksTo(Shelf shelf) async {
    final books = [...store.books]..sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));
    final picked = await showDialog<List<String>>(
      context: context,
      builder: (_) => _AddBooksDialog(shelf: shelf, books: books, coverFor: _covers.coverFor),
    );
    if (picked != null && picked.isNotEmpty) await _addToShelf(shelf, picked);
  }

  // --- Desktop selection and menu -------------------------------------------

  /// Click opens; Ctrl-click picks one more book, Shift-click a range.
  void _tapTile(Book book, List<Book> shown) {
    final keys = HardwareKeyboard.instance;
    final anchor = _pickAnchor;
    if (keys.isShiftPressed && anchor != null) {
      final ids = [for (final b in shown) b.id];
      final from = ids.indexOf(anchor), to = ids.indexOf(book.id);
      if (from >= 0) {
        setState(() => _picked.addAll(ids.sublist(min(from, to), max(from, to) + 1)));
        return;
      }
    }
    if (keys.isControlPressed || keys.isShiftPressed) {
      setState(() {
        if (!_picked.remove(book.id)) _picked.add(book.id);
        _pickAnchor = book.id;
      });
      return;
    }
    setState(_picked.clear);
    _open(book);
  }

  /// What dragging [book] moves: every picked book if it is one of them.
  List<String> _dragSet(Book book, List<Book> shown) => _picked.contains(book.id)
      ? [
          for (final b in shown)
            if (_picked.contains(b.id)) b.id,
        ]
      : [book.id];

  String get _pickedLine => switch (_picked.length) {
    1 => '1 selected · drag it onto a shelf',
    2 => '2 selected · drag either cover to move both',
    final n => '$n selected · drag any cover to move them all',
  };

  void _showDesktopMenu(Book book, Offset globalPosition) {
    final box = _menuAnchor.currentContext?.findRenderObject() as RenderBox?;
    if (box == null) return;
    setState(() => _menuBook = book);
    _menu.open(position: box.globalToLocal(globalPosition));
  }

  List<Widget> _desktopMenuItems() {
    final book = _menuBook;
    if (book == null) return const [];
    final inCloud = book.driveFileId != null;
    return [
      MenuItemButton(
        style: _Menu.item,
        onPressed: () => _open(book),
        child: Text(book.isLocal ? 'Open' : 'Download and open'),
      ),
      MenuItemButton(style: _Menu.item, onPressed: () => _renameBook(book), child: const Text('Rename')),
      SubmenuButton(
        style: _Menu.submenu,
        menuStyle: _Menu.style,
        alignmentOffset: const Offset(12, 0),
        submenuIcon: const WidgetStatePropertyAll(Text('›', style: TextStyle(fontSize: 17))),
        menuChildren: [
          for (final shelf in store.shelves)
            MenuItemButton(
              style: _Menu.item,
              closeOnActivate: false,
              onPressed: () {
                store.setOnShelf(shelf.id, book.id, !shelf.bookIds.contains(book.id));
                librarySync.syncNow();
              },
              child: Row(
                children: [
                  SizedBox(
                    width: 18,
                    child: Text(
                      shelf.bookIds.contains(book.id) ? '✓' : '',
                      style: const TextStyle(color: _Menu.teal, fontWeight: FontWeight.w700),
                    ),
                  ),
                  _ShelfDot(shelf),
                  const SizedBox(width: 10),
                  Text(shelf.name),
                ],
              ),
            ),
          if (store.shelves.isNotEmpty) const _MenuDivider(),
          MenuItemButton(
            style: _Menu.item,
            onPressed: () => _startCreateShelf([book.id]),
            child: const Text(
              '+ Create shelf…',
              style: TextStyle(color: _Menu.tealText, fontWeight: FontWeight.w600),
            ),
          ),
        ],
        child: const Text('Add to shelf'),
      ),
      const _MenuDivider(),
      if (inCloud && book.isLocal)
        MenuItemButton(
          style: _Menu.item,
          onPressed: () async {
            await store.removeLocalCopy(book.id);
            _snack('Download removed. "${book.title}" stays in Google Drive.');
          },
          child: const Text('Remove download'),
        ),
      MenuItemButton(
        style: _Menu.danger,
        onPressed: () => _confirmDelete(book),
        child: Text(inCloud ? 'Delete everywhere' : 'Remove'),
      ),
    ];
  }

  Future<void> _showShelfMenu(Shelf shelf, Offset position) async {
    final action = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(position.dx, position.dy, position.dx, position.dy),
      items: const [
        PopupMenuItem(
          value: 'rename',
          child: ListTile(leading: Icon(Icons.edit_outlined), title: Text('Rename shelf')),
        ),
        PopupMenuItem(
          value: 'delete',
          child: ListTile(leading: Icon(Icons.delete_outline), title: Text('Delete shelf')),
        ),
      ],
    );
    if (!mounted) return;
    switch (action) {
      case 'rename':
        if (useDesktopLayout(context)) {
          _startEditShelf(shelf);
        } else {
          await _renameShelf(shelf);
        }
      case 'delete':
        await _deleteShelf(shelf);
    }
  }

  // --- What to show ---------------------------------------------------------

  int _shelfCount(Shelf shelf) => shelf.bookIds.where((id) => store.byId(id) != null).length;

  List<Book> get _visibleBooks {
    final query = _search.text.trim().toLowerCase();
    final shelf = _shelf;
    final books = store.books
        .where(
          (b) =>
              (shelf == null ? _filter.matches(b) : shelf.bookIds.contains(b.id)) &&
              (query.isEmpty || b.title.toLowerCase().contains(query)),
        )
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
    ('Ctrl+F', 'Search'),
    ('Tab / arrow keys', 'Select a book'),
    ('Enter', 'Open the selected book'),
    ('Del', 'Remove the selected book\'s download'),
    ('Right-click a book', 'Open, rename, add to shelf, remove'),
    ('Ctrl+click / Shift+click', 'Select several books'),
    ('F2', 'Rename the selected book, or the open shelf'),
    ('Double-click a shelf', 'Rename it or change its colour'),
    ('Esc', 'Cancel, or clear the selection'),
    ('Drag books onto a shelf', 'Add them to the shelf'),
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
        const SingleActivator(LogicalKeyboardKey.keyF, control: true): _searchFocus.requestFocus,
      },
      child: Focus(
        autofocus: true,
        onKeyEvent: (_, event) {
          if (event is KeyDownEvent && event.logicalKey == LogicalKeyboardKey.f2 && desktop) {
            // A focused book handles F2 itself; here: one picked book, else the open shelf.
            final picked = _picked.length == 1 ? store.byId(_picked.single) : null;
            final shelf = _shelf;
            if (picked != null) {
              _renameBook(picked);
            } else if (shelf != null) {
              _startEditShelf(shelf);
            }
            return KeyEventResult.handled;
          }
          if (event is KeyDownEvent && event.logicalKey == LogicalKeyboardKey.escape) {
            // Wherever the focus is, Esc closes the sidebar's shelf form first,
            // then clears the selection.
            if (_creatingFor != null || _editingShelfId != null) {
              _cancelShelfForm();
              return KeyEventResult.handled;
            }
            if (_picked.isNotEmpty) {
              setState(_picked.clear);
              return KeyEventResult.handled;
            }
          }
          return questionMarkOpens(event, () => showShortcutsDialog(context, _shortcuts));
        },
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
      _Pill(
        label: '+ Create shelf',
        selected: false,
        onTap: () async {
          final shelf = await _newShelf();
          if (shelf != null) _select(shelfId: shelf.id);
        },
      ),
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
                sliver: SliverList.list(
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            'Library',
                            style: theme.textTheme.displaySmall?.copyWith(
                              fontFamily: serifFamily,
                              fontWeight: FontWeight.w600,
                            ),
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
                        _SectionLabel(
                          _shelf?.name ?? (_filter == LibraryFilter.all ? 'All books' : _heading),
                          size: 15,
                        ),
                        const SizedBox(width: 16),
                        Expanded(
                          child: SingleChildScrollView(
                            scrollDirection: Axis.horizontal,
                            reverse: true,
                            child: Row(
                              children: [
                                for (final chip in chips)
                                  Padding(padding: const EdgeInsets.only(left: 10), child: chip),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 18),
                  ],
                ),
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
    final muted = theme.colorScheme.onSurfaceVariant;
    final books = _visibleBooks;
    final current = _continueReading;
    final shelf = _shelf;
    final counts = {for (final f in LibraryFilter.values) f: store.books.where(f.matches).length};
    final border = theme.colorScheme.outlineVariant;
    final creating = _creatingFor != null;
    final outlined = OutlinedButton.styleFrom(
      minimumSize: const Size(0, 42),
      padding: const EdgeInsets.symmetric(horizontal: 16),
      backgroundColor: theme.colorScheme.surface,
      foregroundColor: theme.colorScheme.onSurface,
      side: BorderSide(color: border),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.normal),
    );
    final filled = FilledButton.styleFrom(
      minimumSize: const Size(0, 42),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
    );
    const headingStyle = TextStyle(fontFamily: serifFamily, fontSize: 32, fontWeight: FontWeight.w600);
    final Widget toolbar;
    if (shelf != null) {
      toolbar = Row(
        children: [
          _ShelfDot(shelf, size: 16),
          const SizedBox(width: 12),
          Flexible(
            flex: 0,
            child: Text(shelf.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: headingStyle),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              '${books.length} book${books.length == 1 ? '' : 's'}',
              maxLines: 1,
              style: TextStyle(fontSize: 15, color: muted),
            ),
          ),
          if (_picked.isNotEmpty)
            Text(_pickedLine, style: TextStyle(fontSize: 14, color: muted))
          else ...[
            OutlinedButton(
              // While the sidebar form renames this shelf the button stays lit.
              // (merge keeps the receiver's values, so the highlight goes first.)
              style: _editingShelfId == shelf.id
                  ? OutlinedButton.styleFrom(
                      backgroundColor: const Color(0xFFE0F2F1),
                      foregroundColor: const Color(0xFF00695C),
                      side: const BorderSide(color: Color(0xFF00897B), width: 2),
                      textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                    ).merge(outlined)
                  : outlined,
              onPressed: () => _startEditShelf(shelf),
              child: const Text('Rename shelf'),
            ),
            const SizedBox(width: 12),
            FilledButton.icon(
              style: filled,
              onPressed: () => _addBooksTo(shelf),
              icon: const Icon(Icons.add, size: 20),
              label: const Text('Add books'),
            ),
          ],
        ],
      );
    } else {
      toolbar = Row(
        children: [
          Expanded(
            child: Text(_heading, maxLines: 1, overflow: TextOverflow.ellipsis, style: headingStyle),
          ),
          if (_picked.isNotEmpty)
            Text(_pickedLine, style: TextStyle(fontSize: 14, color: muted))
          else ...[
            const SizedBox(width: 16),
            Flexible(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 320),
                child: SizedBox(
                  height: 42,
                  child: TextField(
                    controller: _search,
                    focusNode: _searchFocus,
                    style: const TextStyle(fontSize: 15),
                    decoration: InputDecoration(
                      hintText: 'Search books',
                      prefixIcon: const Icon(Icons.search, size: 18),
                      suffixIcon: _search.text.isEmpty
                          ? const Padding(padding: EdgeInsets.all(10), child: _Kbd('Ctrl F'))
                          : IconButton(
                              tooltip: 'Clear',
                              icon: const Icon(Icons.close, size: 18),
                              onPressed: _search.clear,
                            ),
                      isDense: true,
                      filled: true,
                      fillColor: theme.colorScheme.surface,
                      contentPadding: const EdgeInsets.symmetric(vertical: 10),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                        borderSide: BorderSide(color: border),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                        borderSide: BorderSide(color: theme.colorScheme.primary, width: 1.5),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 12),
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
                  children: [
                    Text('Sort: ${_sort.label}', style: const TextStyle(fontSize: 15)),
                    const Icon(Icons.arrow_drop_down),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 12),
            FilledButton.icon(
              style: filled,
              onPressed: _addBooks,
              icon: const Icon(Icons.add, size: 20),
              label: const Text('Add PDF'),
            ),
          ],
        ],
      );
    }
    return Scaffold(
      body: MenuAnchor(
        controller: _menu,
        style: _Menu.style,
        menuChildren: _desktopMenuItems(),
        child: Row(
          key: _menuAnchor,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _Sidebar(
              filter: _shelfId == null ? _filter : null,
              shelfId: _shelfId,
              counts: counts,
              shelves: [for (final s in store.shelves) (s, _shelfCount(s))],
              onFilter: (f) => _select(filter: f),
              // Clicking the open shelf again (as a double-click does) keeps
              // any rename form open.
              onShelf: (s) {
                if (_shelfId != s.id) _select(shelfId: s.id);
              },
              onShelfMenu: _showShelfMenu,
              onNewShelf: _startCreateShelf,
              onDropOnShelf: _addToShelf,
              onShelfClick: _clickShelf,
              createForm: !creating
                  ? null
                  : _ShelfForm(
                      name: _shelfName,
                      focusNode: _shelfNameFocus,
                      color: _shelfColor,
                      action: 'Create',
                      hint: 'Enter to create · Esc to cancel',
                      onColor: (c) => setState(() => _shelfColor = c),
                      onSubmit: _finishCreateShelf,
                      onCancel: _cancelShelfForm,
                    ),
              editingShelfId: _editingShelfId,
              editForm: _editingShelfId == null
                  ? null
                  : _ShelfForm(
                      name: _shelfName,
                      focusNode: _shelfNameFocus,
                      color: _shelfColor,
                      action: 'Save',
                      hint: 'Enter to save · Esc to cancel',
                      topMargin: 0,
                      onColor: (c) => setState(() => _shelfColor = c),
                      onSubmit: _finishEditShelf,
                      onCancel: _cancelShelfForm,
                      onDelete: () {
                        final shelf = store.shelfById(_editingShelfId!);
                        if (shelf != null) _deleteShelf(shelf);
                      },
                    ),
              account: SidebarAccount(sync: widget.sync, librarySync: librarySync),
            ),
            Expanded(
              child: CustomScrollView(
                slivers: [
                  SliverPadding(
                    padding: const EdgeInsets.fromLTRB(40, 28, 40, 0),
                    sliver: SliverList.list(
                      children: [
                        toolbar,
                        if (current.isNotEmpty) ...[
                          const SizedBox(height: 30),
                          const _SectionLabel('Continue reading'),
                          const SizedBox(height: 14),
                          LayoutBuilder(
                            builder: (context, constraints) {
                              // Like CSS auto-fit: as many 300px+ columns as fit, one per
                              // book, sharing the full width. A single book still takes
                              // only half, the size it has next to a second one.
                              final fit = ((constraints.maxWidth + 16) / 316).floor().clamp(1, 3);
                              final columns = min(fit, max(current.length, 2));
                              final shown = current.take(columns).toList();
                              return Row(
                                children: [
                                  for (var i = 0; i < columns; i++) ...[
                                    if (i > 0) const SizedBox(width: 16),
                                    Expanded(
                                      child: i < shown.length
                                          ? _ContinueCard(
                                              book: shown[i],
                                              cover: _covers.coverFor(shown[i]),
                                              onOpen: () => _open(shown[i]),
                                            )
                                          : const SizedBox(),
                                    ),
                                  ],
                                ],
                              );
                            },
                          ),
                        ],
                        if (shelf != null)
                          const SizedBox(height: 24)
                        else ...[
                          const SizedBox(height: 30),
                          _SectionLabel(current.isEmpty ? 'Books' : 'Library'),
                          const SizedBox(height: 14),
                        ],
                      ],
                    ),
                  ),
                  _grid(
                    books,
                    padding: const EdgeInsets.fromLTRB(40, 0, 40, 40),
                    maxExtent: 160,
                    aspect: 0.64,
                    spacing: (24, 20),
                    tile: (book) {
                      final drag = _dragSet(book, books);
                      return _DesktopTile(
                        book: book,
                        cover: _covers.coverFor(book),
                        transfer: librarySync.transferFor(book.id),
                        picked: _picked.contains(book.id),
                        faded: _dragIds.contains(book.id),
                        dragIds: drag,
                        dragFeedback: _DragFeedback(
                          books: [for (final id in drag.take(2)) ?store.byId(id)],
                          count: drag.length,
                          coverFor: _covers.coverFor,
                        ),
                        onDragStarted: () => setState(() => _dragIds = drag.toSet()),
                        onDragEnded: () => setState(() => _dragIds = const {}),
                        onTap: () => _tapTile(book, books),
                        onMenu: (position) => _showDesktopMenu(book, position),
                        onDelete: () => _removeWithKey(book),
                        onRename: () => _renameBook(book),
                      );
                    },
                    emptyHint: shelf != null
                        ? 'Click "Add books", drag books onto "${shelf.name}" in the sidebar, '
                              'or right-click a book → Add to shelf.'
                        : 'Click "Add PDF" or drop PDF files anywhere in this window.',
                  ),
                ],
              ),
            ),
          ],
        ),
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
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(5),
      ),
      child: Text(keys, style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
    );
  }
}

class _ShelfDot extends StatelessWidget {
  const _ShelfDot(this.shelf, {this.size = 10});

  final Shelf shelf;
  final double size;

  @override
  Widget build(BuildContext context) => _ColorDot(shelfColors[shelf.color % shelfColors.length], size: size);
}

class _ColorDot extends StatelessWidget {
  const _ColorDot(this.argb, {this.size = 10});

  final int argb;
  final double size;

  @override
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    decoration: BoxDecoration(color: Color(argb), borderRadius: BorderRadius.circular(size / 4 + 0.5)),
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
                  Container(
                    width: 10,
                    height: 10,
                    decoration: BoxDecoration(color: dot, borderRadius: BorderRadius.circular(3)),
                  ),
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
    required this.createForm,
    required this.onShelfClick,
    required this.editingShelfId,
    required this.editForm,
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
  final void Function(Shelf, List<String> bookIds) onDropOnShelf;

  /// The inline "Create shelf" form, shown in place of the "+ Create shelf" item.
  final Widget? createForm;

  /// Every primary press on a shelf row, for double-click detection.
  final void Function(Shelf, Duration timeStamp) onShelfClick;

  /// The shelf whose row is replaced by [editForm].
  final String? editingShelfId;
  final Widget? editForm;
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
                  const Flexible(
                    child: Text(
                      'ShelfSync',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: _Side.text, fontSize: 19, fontWeight: FontWeight.w700),
                    ),
                  ),
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
                    if (shelf.id == editingShelfId && editForm != null)
                      editForm!
                    else
                      DragTarget<List<String>>(
                        onAcceptWithDetails: (d) => onDropOnShelf(shelf, d.data),
                        builder: (context, candidates, _) => Listener(
                          onPointerDown: (e) {
                            if (e.buttons == kPrimaryButton) onShelfClick(shelf, e.timeStamp);
                          },
                          child: _SideItem(
                            icon: _ShelfDot(shelf),
                            label: shelf.name,
                            count: count,
                            selected: shelf.id == shelfId || candidates.isNotEmpty,
                            highlighted: candidates.isNotEmpty,
                            height: 40,
                            onTap: () => onShelf(shelf),
                            onMenu: (position) => onShelfMenu(shelf, position),
                          ),
                        ),
                      ),
                  createForm ??
                      _SideItem(
                        icon: const SizedBox(width: 10),
                        label: '+ Create shelf',
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
                    IconTheme.merge(
                      data: IconThemeData(color: color),
                      child: icon,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: color,
                          fontSize: 15,
                          fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
                        ),
                      ),
                    ),
                    if (highlighted)
                      const Text(
                        'Drop to add',
                        style: TextStyle(color: _Side.accent, fontSize: 13, fontWeight: FontWeight.w600),
                      )
                    else if (count != null)
                      Text('$count', style: const TextStyle(color: _Side.muted, fontSize: 14)),
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
  const _TabletTile({
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
              Expanded(
                child: BookCoverFrame(book: book, cover: cover, overlay: t == null ? null : _TransferOverlay(t)),
              ),
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

/// Desktop grid tile: cover and a thin progress bar. Drag it (with any other
/// picked books) onto a shelf. Tab or the arrow keys select a tile, Enter
/// opens it, Del removes the download.
class _DesktopTile extends StatefulWidget {
  const _DesktopTile({
    required this.book,
    required this.cover,
    required this.transfer,
    required this.picked,
    required this.faded,
    required this.dragIds,
    required this.dragFeedback,
    required this.onDragStarted,
    required this.onDragEnded,
    required this.onTap,
    required this.onMenu,
    required this.onDelete,
    required this.onRename,
  });

  final Book book;
  final Future<File?> cover;
  final Transfer? transfer;

  /// Picked with Ctrl- or Shift-click.
  final bool picked;

  /// Being dragged onto a shelf.
  final bool faded;
  final List<String> dragIds;
  final Widget dragFeedback;
  final VoidCallback onDragStarted;
  final VoidCallback onDragEnded;
  final VoidCallback onTap;
  final ValueChanged<Offset> onMenu;
  final VoidCallback onDelete;
  final VoidCallback onRename;

  @override
  State<_DesktopTile> createState() => _DesktopTileState();
}

class _DesktopTileState extends State<_DesktopTile> {
  var _focused = false;

  @override
  Widget build(BuildContext context) {
    final book = widget.book;
    final t = widget.transfer;
    final primary = Theme.of(context).colorScheme.primary;
    return Draggable<List<String>>(
      data: widget.dragIds,
      dragAnchorStrategy: pointerDragAnchorStrategy,
      feedback: widget.dragFeedback,
      onDragStarted: widget.onDragStarted,
      onDragEnd: (_) => widget.onDragEnded(),
      child: Opacity(
        opacity: widget.faded ? 0.45 : 1,
        child: Tooltip(
          message: '${book.title}\n${_tabletStatus(book, t)}',
          waitDuration: const Duration(milliseconds: 500),
          child: GestureDetector(
            onSecondaryTapUp: (d) => widget.onMenu(d.globalPosition),
            onLongPressStart: (d) => widget.onMenu(d.globalPosition),
            child: CallbackShortcuts(
              bindings: {
                const SingleActivator(LogicalKeyboardKey.delete): widget.onDelete,
                const SingleActivator(LogicalKeyboardKey.f2): widget.onRename,
              },
              child: InkWell(
                onTap: widget.onTap,
                onFocusChange: (focused) => setState(() => _focused = focused),
                focusColor: Colors.transparent,
                borderRadius: BorderRadius.circular(6),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(
                      child: DecoratedBox(
                        position: DecorationPosition.foreground,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(8),
                          border: _focused || widget.picked
                              ? Border.all(color: primary, width: 3, strokeAlign: BorderSide.strokeAlignOutside + 2 / 3)
                              : null,
                        ),
                        child: BookCoverFrame(
                          book: book,
                          cover: widget.cover,
                          overlay: t == null ? null : _TransferOverlay(t),
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    ProgressLine(value: book.progress, height: 3),
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

/// What follows the pointer while dragging books: the first cover, a second
/// one peeking out behind when there are more, and how many there are.
class _DragFeedback extends StatelessWidget {
  const _DragFeedback({required this.books, required this.count, required this.coverFor});

  final List<Book> books;
  final int count;
  final Future<File?> Function(Book) coverFor;

  @override
  Widget build(BuildContext context) {
    return Transform.rotate(
      angle: -4 * pi / 180,
      child: SizedBox(
        width: 100,
        height: 136,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            if (books.length > 1)
              Positioned(
                left: 8,
                top: 10,
                width: 84,
                height: 120,
                child: BookCoverFrame(book: books[1], cover: coverFor(books[1])),
              ),
            if (books.isNotEmpty)
              Positioned(
                left: 0,
                top: 16,
                width: 84,
                height: 120,
                child: BookCoverFrame(book: books[0], cover: coverFor(books[0])),
              ),
            if (count > 1)
              Positioned(
                left: 72,
                top: 2,
                child: Container(
                  constraints: const BoxConstraints(minWidth: 24),
                  height: 24,
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: const Color(0xFF00897B),
                    borderRadius: BorderRadius.circular(12),
                    boxShadow: const [BoxShadow(color: Colors.black38, blurRadius: 6, offset: Offset(0, 2))],
                  ),
                  child: Text(
                    '$count',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      decoration: TextDecoration.none,
                      fontFamily: uiFamily,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// The sidebar's inline shelf form: name, colour and Create (a new shelf) or
/// Save and "Delete shelf…" (renaming one in place).
class _ShelfForm extends StatelessWidget {
  const _ShelfForm({
    required this.name,
    required this.focusNode,
    required this.color,
    required this.action,
    required this.hint,
    required this.onColor,
    required this.onSubmit,
    required this.onCancel,
    this.onDelete,
    this.topMargin = 4,
  });

  final TextEditingController name;
  final FocusNode focusNode;
  final int color;
  final String action;
  final String hint;
  final ValueChanged<int> onColor;
  final VoidCallback onSubmit;
  final VoidCallback onCancel;
  final VoidCallback? onDelete;
  final double topMargin;

  static const _names = ['Blue', 'Green', 'Red', 'Amber', 'Purple', 'Orange', 'Teal', 'Pink'];

  @override
  Widget build(BuildContext context) {
    return CallbackShortcuts(
      bindings: {const SingleActivator(LogicalKeyboardKey.escape): onCancel},
      child: Container(
        margin: EdgeInsets.only(top: topMargin, bottom: 2),
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: const Color(0xFF202A2E),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: const Color(0xFF4DB6AC)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                _ColorDot(shelfColors[color]),
                const SizedBox(width: 10),
                Expanded(
                  child: TextField(
                    controller: name,
                    focusNode: focusNode,
                    textCapitalization: TextCapitalization.sentences,
                    cursorColor: _Side.accent,
                    style: const TextStyle(color: _Side.text, fontSize: 15),
                    decoration: const InputDecoration.collapsed(
                      hintText: 'Shelf name',
                      hintStyle: TextStyle(color: _Side.muted, fontSize: 15),
                    ),
                    onSubmitted: (_) => onSubmit(),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            // All colours on one row, as large as the sidebar allows (up to 22px).
            LayoutBuilder(
              builder: (context, constraints) {
                const gap = 5.0;
                final n = shelfColors.length;
                final size = min(22.0, (constraints.maxWidth - gap * (n - 1)) / n);
                return Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    for (var i = 0; i < n; i++)
                      Semantics(
                        label: _names[i],
                        selected: i == color,
                        button: true,
                        child: GestureDetector(
                          onTap: () => onColor(i),
                          child: MouseRegion(
                            cursor: SystemMouseCursors.click,
                            child: Container(
                              width: size,
                              height: size,
                              decoration: BoxDecoration(
                                color: Color(shelfColors[i]),
                                borderRadius: BorderRadius.circular(size * 0.27),
                                border: Border.all(color: i == color ? _Side.text : Colors.transparent, width: 2),
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                );
              },
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                SizedBox(
                  height: 32,
                  child: FilledButton(
                    style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xFF00897B),
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(horizontal: 14),
                      minimumSize: const Size(0, 32),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                      textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
                    ),
                    onPressed: onSubmit,
                    child: Text(action),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(hint, style: const TextStyle(color: _Side.muted, fontSize: 12, height: 1.3)),
                ),
              ],
            ),
            if (onDelete != null) ...[
              const SizedBox(height: 10),
              Align(
                alignment: Alignment.centerLeft,
                child: MouseRegion(
                  cursor: SystemMouseCursors.click,
                  child: GestureDetector(
                    onTap: onDelete,
                    child: const Text('Delete shelf…', style: TextStyle(color: Color(0xFFEF9A9A), fontSize: 13)),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Desktop "Rename book": the cover, the title, suggestions made from the
/// file name, and a note that Drive (and so every device) follows.
class _RenameBookDialog extends StatefulWidget {
  const _RenameBookDialog({required this.book, required this.cover});

  final Book book;
  final Future<File?> cover;

  @override
  State<_RenameBookDialog> createState() => _RenameBookDialogState();
}

class _RenameBookDialogState extends State<_RenameBookDialog> {
  late final _title = TextEditingController(text: widget.book.title)
    ..selection = TextSelection(baseOffset: 0, extentOffset: widget.book.title.length);
  final _focus = FocusNode();
  late final _suggestions = LibraryStore.renameSuggestions(widget.book.fileName, widget.book.title);

  @override
  void dispose() {
    _title.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _submit() => Navigator.pop(context, _title.text);

  void _use(String suggestion) {
    _title.value = TextEditingValue(
      text: suggestion,
      selection: TextSelection.collapsed(offset: suggestion.length),
    );
    _focus.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    const muted = Color(0xFF5B6764);
    const teal = Color(0xFF00897B);
    final book = widget.book;
    final pages = book.pageCount;
    return Dialog(
      backgroundColor: Colors.white,
      surfaceTintColor: Colors.transparent,
      insetPadding: const EdgeInsets.all(24),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 600),
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 72,
                    height: 102,
                    child: BookCoverFrame(book: book, cover: widget.cover),
                  ),
                  const SizedBox(width: 20),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Rename book',
                          style: TextStyle(fontFamily: serifFamily, fontSize: 24, fontWeight: FontWeight.w600),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          pages == null ? book.fileName : '${book.fileName} · $pages pages',
                          style: const TextStyle(fontSize: 14, color: muted),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 20),
              const Text(
                'Title',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Color(0xFF00796B)),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _title,
                focusNode: _focus,
                autofocus: true,
                textCapitalization: TextCapitalization.sentences,
                style: const TextStyle(fontSize: 17),
                decoration: InputDecoration(
                  isDense: true,
                  contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: const BorderSide(color: teal, width: 2),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: const BorderSide(color: teal, width: 2),
                  ),
                ),
                onSubmitted: (_) => _submit(),
              ),
              if (_suggestions.isNotEmpty) ...[
                const SizedBox(height: 20),
                const Text(
                  'Suggestions',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: muted),
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final suggestion in _suggestions)
                      Material(
                        color: const Color(0xFFF6F5F1),
                        shape: const StadiumBorder(side: BorderSide(color: Color(0xFFC9D1CE))),
                        child: InkWell(
                          customBorder: const StadiumBorder(),
                          onTap: () => _use(suggestion),
                          child: Container(
                            height: 34,
                            padding: const EdgeInsets.symmetric(horizontal: 14),
                            alignment: Alignment.centerLeft,
                            child: Text(
                              suggestion,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 14, color: _Menu.ink),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ],
              if (book.driveFileId != null) ...[
                const SizedBox(height: 20),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                  decoration: BoxDecoration(color: const Color(0xFFE0F2F1), borderRadius: BorderRadius.circular(12)),
                  child: const Row(
                    children: [
                      Icon(Icons.cloud_outlined, size: 18, color: Color(0xFF00695C)),
                      SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          'Also renames it in Google Drive and on your other devices.',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 14, color: Color(0xFF00695C)),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
              const SizedBox(height: 20),
              Row(
                children: [
                  const Expanded(
                    child: Text(
                      'F2 renames the selected book',
                      style: TextStyle(fontSize: 13, color: Color(0xFF8A9A96)),
                    ),
                  ),
                  OutlinedButton(
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size(0, 42),
                      padding: const EdgeInsets.symmetric(horizontal: 18),
                      foregroundColor: _Menu.ink,
                      side: const BorderSide(color: Color(0xFFDDE2E0)),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                      textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.normal),
                    ),
                    onPressed: () => Navigator.pop(context),
                    child: const Text('Cancel'),
                  ),
                  const SizedBox(width: 12),
                  FilledButton(
                    style: FilledButton.styleFrom(
                      minimumSize: const Size(0, 42),
                      padding: const EdgeInsets.symmetric(horizontal: 22),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                      textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                    ),
                    onPressed: _submit,
                    child: const Text('Rename'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Look of the desktop book menu and its "Add to shelf" submenu.
abstract final class _Menu {
  static const ink = Color(0xFF1D2321);
  static const teal = Color(0xFF00897B);
  static const tealText = Color(0xFF00796B);
  static const red = Color(0xFFC62828);

  static final style = MenuStyle(
    backgroundColor: const WidgetStatePropertyAll(Colors.white),
    surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
    elevation: const WidgetStatePropertyAll(10),
    shadowColor: const WidgetStatePropertyAll(Colors.black45),
    padding: const WidgetStatePropertyAll(EdgeInsets.all(6)),
    minimumSize: const WidgetStatePropertyAll(Size(250, 0)),
    shape: WidgetStatePropertyAll(
      RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: const BorderSide(color: Color(0x0F000000)),
      ),
    ),
  );

  static ButtonStyle _item(Color color, {Color? active, Color? activeText}) => ButtonStyle(
    minimumSize: const WidgetStatePropertyAll(Size(238, 40)),
    maximumSize: const WidgetStatePropertyAll(Size(238, 40)),
    padding: const WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 12)),
    shape: WidgetStatePropertyAll(RoundedRectangleBorder(borderRadius: BorderRadius.circular(8))),
    textStyle: WidgetStateProperty.resolveWith(
      (states) => TextStyle(
        fontFamily: uiFamily,
        fontSize: 15,
        fontWeight: activeText != null && (states.contains(WidgetState.hovered) || states.contains(WidgetState.focused))
            ? FontWeight.w600
            : FontWeight.normal,
      ),
    ),
    foregroundColor: WidgetStateProperty.resolveWith(
      (states) => activeText != null && (states.contains(WidgetState.hovered) || states.contains(WidgetState.focused))
          ? activeText
          : color,
    ),
    backgroundColor: WidgetStateProperty.resolveWith(
      (states) => states.contains(WidgetState.hovered) || states.contains(WidgetState.focused)
          ? (active ?? const Color(0xFFF1F4F3))
          : Colors.transparent,
    ),
    overlayColor: const WidgetStatePropertyAll(Colors.transparent),
  );

  static final item = _item(ink);
  static final danger = _item(red, active: const Color(0xFFFDECEC));
  static final submenu = _item(ink, active: const Color(0xFFE0F2F1), activeText: const Color(0xFF00695C));
}

class _MenuDivider extends StatelessWidget {
  const _MenuDivider();

  @override
  Widget build(BuildContext context) => Container(
    height: 1,
    margin: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
    color: const Color(0xFFE6EAE8),
  );
}

/// The "Add books to …" dialog: pick books from the whole library.
class _AddBooksDialog extends StatefulWidget {
  const _AddBooksDialog({required this.shelf, required this.books, required this.coverFor});

  final Shelf shelf;
  final List<Book> books;
  final Future<File?> Function(Book) coverFor;

  @override
  State<_AddBooksDialog> createState() => _AddBooksDialogState();
}

class _AddBooksDialogState extends State<_AddBooksDialog> {
  final _search = TextEditingController();
  final _picked = <String>{};

  @override
  void initState() {
    super.initState();
    _search.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    const muted = Color(0xFF5B6764);
    const line = Color(0xFFDDE2E0);
    final query = _search.text.trim().toLowerCase();
    final books = [
      for (final b in widget.books)
        if (query.isEmpty || b.title.toLowerCase().contains(query)) b,
    ];
    final n = _picked.length;
    return Dialog(
      backgroundColor: Colors.white,
      surfaceTintColor: Colors.transparent,
      insetPadding: const EdgeInsets.all(24),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 760),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(28, 24, 28, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'Add books to ${widget.shelf.name}',
                    style: const TextStyle(fontFamily: serifFamily, fontSize: 24, fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 14),
                  SizedBox(
                    height: 42,
                    child: TextField(
                      controller: _search,
                      autofocus: true,
                      style: const TextStyle(fontSize: 15),
                      decoration: InputDecoration(
                        hintText: 'Search your library',
                        prefixIcon: const Icon(Icons.search, size: 18, color: muted),
                        isDense: true,
                        contentPadding: const EdgeInsets.symmetric(vertical: 10),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10),
                          borderSide: const BorderSide(color: line),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10),
                          borderSide: const BorderSide(color: _Menu.teal, width: 1.5),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Flexible(
              child: books.isEmpty
                  ? const Padding(
                      padding: EdgeInsets.fromLTRB(28, 24, 28, 40),
                      child: Text(
                        'No books match.',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: muted),
                      ),
                    )
                  : GridView.builder(
                      shrinkWrap: true,
                      padding: const EdgeInsets.fromLTRB(28, 4, 28, 20),
                      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                        maxCrossAxisExtent: 134,
                        mainAxisSpacing: 18,
                        crossAxisSpacing: 16,
                        childAspectRatio: 0.58,
                      ),
                      itemCount: books.length,
                      itemBuilder: (context, i) {
                        final book = books[i];
                        final already = widget.shelf.bookIds.contains(book.id);
                        final picked = _picked.contains(book.id);
                        return _PickTile(
                          book: book,
                          cover: widget.coverFor(book),
                          picked: picked,
                          already: already,
                          onTap: already
                              ? null
                              : () => setState(() {
                                  if (!_picked.remove(book.id)) _picked.add(book.id);
                                }),
                        );
                      },
                    ),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 16),
              decoration: const BoxDecoration(
                border: Border(top: BorderSide(color: Color(0xFFE6EAE8))),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text('$n selected', style: const TextStyle(fontSize: 15, color: muted)),
                  ),
                  OutlinedButton(
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size(0, 42),
                      padding: const EdgeInsets.symmetric(horizontal: 18),
                      foregroundColor: _Menu.ink,
                      side: const BorderSide(color: line),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                      textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.normal),
                    ),
                    onPressed: () => Navigator.pop(context),
                    child: const Text('Cancel'),
                  ),
                  const SizedBox(width: 12),
                  FilledButton(
                    style: FilledButton.styleFrom(
                      minimumSize: const Size(0, 42),
                      padding: const EdgeInsets.symmetric(horizontal: 20),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                      textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                    ),
                    onPressed: n == 0
                        ? null
                        : () => Navigator.pop(context, [
                            for (final b in widget.books)
                              if (_picked.contains(b.id)) b.id,
                          ]),
                    child: Text(n == 1 ? 'Add 1 book' : 'Add $n books'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A cover in the "Add books" picker, with its check mark.
class _PickTile extends StatelessWidget {
  const _PickTile({
    required this.book,
    required this.cover,
    required this.picked,
    required this.already,
    required this.onTap,
  });

  final Book book;
  final Future<File?> cover;
  final bool picked;
  final bool already;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: book.title,
      selected: picked,
      button: true,
      child: Opacity(
        opacity: already ? 0.5 : 1,
        child: MouseRegion(
          cursor: onTap == null ? SystemMouseCursors.basic : SystemMouseCursors.click,
          child: GestureDetector(
            onTap: onTap,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      DecoratedBox(
                        position: DecorationPosition.foreground,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(7),
                          border: picked
                              ? Border.all(
                                  color: _Menu.teal,
                                  width: 3,
                                  strokeAlign: BorderSide.strokeAlignOutside + 2 / 3,
                                )
                              : null,
                        ),
                        child: BookCoverFrame(book: book, cover: cover),
                      ),
                      Positioned(
                        top: 6,
                        right: 6,
                        child: Container(
                          width: 24,
                          height: 24,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: picked
                                ? _Menu.teal
                                : (already ? const Color(0xFF8A9A96) : Colors.black.withValues(alpha: 0.25)),
                            border: Border.all(color: Colors.white, width: 2),
                          ),
                          child: picked || already
                              ? const Text(
                                  '✓',
                                  style: TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w700),
                                )
                              : null,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  already ? 'Already on this shelf' : '',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12, color: Color(0xFF5B6764)),
                ),
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
                        style: const TextStyle(
                          fontFamily: serifFamily,
                          fontSize: 26,
                          fontWeight: FontWeight.w600,
                          height: 1.2,
                        ),
                      ),
                      if (book.chapter != null) ...[
                        const SizedBox(height: 10),
                        Text(
                          book.chapter!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 16, color: muted),
                        ),
                      ],
                      const SizedBox(height: 18),
                      ProgressLine(value: book.progress, height: 8),
                      const SizedBox(height: 8),
                      Text(
                        last == null
                            ? _pageLine(book)
                            : '${_pageLine(book)} · ${last[0].toLowerCase()}${last.substring(1)}',
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
              SizedBox(
                width: 64,
                height: 90,
                child: BookCoverFrame(book: book, cover: cover),
              ),
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

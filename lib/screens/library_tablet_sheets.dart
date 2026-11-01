part of 'library_screen.dart';

/// Tablet sheets for creating, editing and deleting shelves, and renaming a
/// book. Each rises with the keyboard and syncs its change everywhere.
extension _TabletSheets on _LibraryScreenState {
  Future<T?> _tabletSheet<T>(Widget child) => _blurredBehind(
    () => showModalBottomSheet<T>(
      context: context,
      isScrollControlled: true,
      constraints: const BoxConstraints(maxWidth: 840),
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(34))),
      builder: (context) => Theme(data: tabletTheme(), child: child),
    ),
  );

  /// Blurs the library while [show]'s sheet or dialog is up.
  Future<T> _blurredBehind<T>(Future<T> Function() show) async {
    _update(() => _blurLibrary = true);
    try {
      return await show();
    } finally {
      if (mounted) _update(() => _blurLibrary = false);
    }
  }

  /// "Create shelf"; with [bookIds], they go on it. Returns the new shelf.
  Future<Shelf?> _tabletCreateShelf({List<String> bookIds = const []}) async {
    final result = await _tabletSheet<_ShelfEdit>(
      _ShelfSheet(
        color: store.nextShelfColor % shelfColors.length,
        books: [for (final id in bookIds) ?store.byId(id)],
        coverFor: _covers.coverFor,
      ),
    );
    if (result == null || !mounted) return null;
    final shelf = await store.createShelf(result.name, color: result.color);
    if (bookIds.isEmpty) {
      librarySync.syncNow();
    } else {
      await _addToShelf(shelf, bookIds);
    }
    return shelf;
  }

  /// "Edit shelf": rename, recolour, or go on to delete it.
  Future<void> _tabletEditShelf(Shelf shelf) async {
    final result = await _tabletSheet<_ShelfEdit>(
      _ShelfSheet(
        shelf: shelf,
        color: shelf.color % shelfColors.length,
        books: _shelfBooks(shelf),
        coverFor: _covers.coverFor,
      ),
    );
    if (result == null || !mounted) return;
    if (result.delete) return _tabletDeleteShelf(shelf);
    await store.editShelf(shelf.id, name: result.name, color: result.color);
    librarySync.syncNow();
  }

  /// Asks, deletes, then offers Undo for a few seconds.
  Future<void> _tabletDeleteShelf(Shelf shelf) async {
    final books = _shelfBooks(shelf);
    final confirmed = await _blurredBehind(
      () => showDialog<bool>(
        context: context,
        barrierColor: const Color(0xA806090A),
        builder: (context) => Theme(
          data: tabletTheme(),
          child: _DeleteShelfDialog(shelf: shelf, books: books, coverFor: _covers.coverFor),
        ),
      ),
    );
    if (confirmed != true || !mounted) return;
    final index = store.shelves.indexOf(shelf);
    final copy = Shelf(id: shelf.id, name: shelf.name, color: shelf.color, bookIds: {...shelf.bookIds});
    if (_shelfId == shelf.id) _select();
    await store.deleteShelf(shelf.id);
    librarySync.syncNow();
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text('“${copy.name}” deleted'),
          duration: const Duration(seconds: 6),
          action: SnackBarAction(
            label: 'Undo',
            onPressed: () async {
              await store.restoreShelf(copy, index);
              librarySync.syncNow();
            },
          ),
        ),
      );
  }

  /// "Rename book", with suggestions from the file name.
  Future<void> _tabletRenameBook(Book book) async {
    final title = await _tabletSheet<String>(_RenameBookSheet(book: book, cover: _covers.coverFor(book)));
    final trimmed = title?.trim() ?? '';
    if (trimmed.isNotEmpty && trimmed != book.title) await librarySync.rename(book, trimmed);
  }
}

/// What the shelf sheet hands back.
class _ShelfEdit {
  const _ShelfEdit(this.name, this.color) : delete = false;
  const _ShelfEdit.delete() : name = '', color = 0, delete = true;

  final String name;
  final int color;
  final bool delete;
}

/// The shared top of a tablet sheet: handle, then the content with the
/// keyboard's room kept clear below it.
class _SheetFrame extends StatelessWidget {
  const _SheetFrame({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(40, 14, 40, 32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [const SheetHandle(), const SizedBox(height: 22), ...children],
          ),
        ),
      ),
    );
  }
}

/// Text field in the sheets: dark, rounded, outlined in [color].
InputDecoration _sheetField(Color color, {String? hint, Widget? suffix}) => InputDecoration(
  hintText: hint,
  hintStyle: const TextStyle(color: TabletColors.faint),
  filled: true,
  fillColor: const Color(0x59000000),
  contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 19),
  suffixIcon: suffix,
  enabledBorder: OutlineInputBorder(
    borderRadius: BorderRadius.circular(18),
    borderSide: BorderSide(color: color.withValues(alpha: 0.6), width: 1.5),
  ),
  focusedBorder: OutlineInputBorder(
    borderRadius: BorderRadius.circular(18),
    borderSide: BorderSide(color: color, width: 1.5),
  ),
);

/// Cancel, then the sheet's main action.
class _SheetActions extends StatelessWidget {
  const _SheetActions({required this.label, required this.onPressed, this.icon, this.leading});

  final String label;
  final IconData? icon;
  final VoidCallback? onPressed;
  final Widget? leading;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        // The note or Delete link takes all the free room on the left.
        Expanded(
          child: leading == null ? const SizedBox() : Align(alignment: Alignment.centerLeft, child: leading),
        ),
        const SizedBox(width: 12),
        TextButton(
          style: TextButton.styleFrom(
            foregroundColor: TabletColors.soft,
            minimumSize: const Size(0, 56),
            padding: const EdgeInsets.symmetric(horizontal: 24),
            shape: const StadiumBorder(),
            textStyle: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600, fontFamily: uiFamily),
          ),
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        const SizedBox(width: 12),
        TealButton(
          label: label,
          icon: icon,
          height: 56,
          fontSize: 17,
          padding: EdgeInsets.only(left: icon == null ? 30 : 24, right: 30),
          onPressed: onPressed,
        ),
      ],
    );
  }
}

/// Create shelf / Edit shelf: name, colour, and a live preview of its card.
class _ShelfSheet extends StatefulWidget {
  const _ShelfSheet({this.shelf, required this.color, required this.books, required this.coverFor});

  /// The shelf being edited; null to create one.
  final Shelf? shelf;
  final int color;

  /// Shown fanned on the preview card.
  final List<Book> books;
  final Future<File?> Function(Book) coverFor;

  @override
  State<_ShelfSheet> createState() => _ShelfSheetState();
}

class _ShelfSheetState extends State<_ShelfSheet> {
  late final _name = TextEditingController(text: widget.shelf?.name ?? '');
  late var _color = widget.color;

  bool get _editing => widget.shelf != null;

  @override
  void initState() {
    super.initState();
    // Editing: the name is selected, so typing replaces it.
    _name.selection = TextSelection(baseOffset: 0, extentOffset: _name.text.length);
    _name.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _submit() {
    final name = _name.text.trim();
    if (name.isEmpty) return;
    Navigator.pop(context, _ShelfEdit(name, _color));
  }

  @override
  Widget build(BuildContext context) {
    final colour = Color(shelfColors[_color]);
    final name = _name.text.trim();
    final count = widget.books.length;
    final preview = Shelf(
      id: 'preview',
      name: name.isEmpty ? (_editing ? widget.shelf!.name : 'Your shelf') : name,
      color: _color,
    );
    return _SheetFrame(
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _editing ? 'Edit shelf' : 'Create shelf',
                    style: const TextStyle(fontFamily: serifFamily, fontSize: 30, fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    _editing
                        ? (count == 0
                              ? 'It’s empty for now. The change reaches your other devices.'
                              : 'Renaming keeps its $count book${count == 1 ? '' : 's'}. The change reaches your other devices.')
                        : 'Group books your way, like “Textbooks” or “Novels”. It appears on your other devices too.',
                    style: const TextStyle(fontSize: 15, height: 1.4, color: TabletColors.dim),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 28),
            Column(
              children: [
                const TabletLabel('Preview'),
                const SizedBox(height: 10),
                SizedBox(
                  height: 116,
                  child: IgnorePointer(
                    child: _ShelfCard(
                      shelf: preview,
                      count: count,
                      note: count == 0 ? 'Empty for now' : null,
                      books: widget.books.take(3).toList(),
                      coverFor: widget.coverFor,
                      onTap: () {},
                      onMenu: (_) {},
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
        const SizedBox(height: 22),
        TextField(
          controller: _name,
          autofocus: true,
          textCapitalization: TextCapitalization.sentences,
          cursorColor: colour,
          style: const TextStyle(fontSize: 21),
          textInputAction: TextInputAction.done,
          onSubmitted: (_) => _submit(),
          decoration: _sheetField(colour, hint: 'Shelf name'),
        ),
        const SizedBox(height: 22),
        const TabletLabel('Colour'),
        const SizedBox(height: 12),
        Wrap(
          spacing: 14,
          runSpacing: 12,
          children: [
            for (var i = 0; i < shelfColors.length; i++)
              Semantics(
                selected: i == _color,
                button: true,
                label: 'Colour ${i + 1}',
                child: GestureDetector(
                  onTap: () => setState(() => _color = i),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 150),
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: Color(shelfColors[i]),
                      shape: BoxShape.circle,
                      border: i == _color ? Border.all(color: TabletColors.sheet, width: 3) : null,
                      boxShadow: [if (i == _color) BoxShadow(color: Color(shelfColors[i]), spreadRadius: 2.5)],
                    ),
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 22),
        _SheetActions(
          label: _editing ? 'Save' : 'Create shelf',
          icon: _editing ? null : Icons.add_rounded,
          onPressed: name.isEmpty ? null : _submit,
          leading: !_editing
              ? null
              : TextButton.icon(
                  style: TextButton.styleFrom(
                    foregroundColor: TabletColors.danger,
                    minimumSize: const Size(0, 56),
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                    textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600, fontFamily: uiFamily),
                  ),
                  onPressed: () => Navigator.pop(context, const _ShelfEdit.delete()),
                  icon: const Icon(Icons.delete_outline_rounded, size: 20),
                  label: const Text('Delete shelf…'),
                ),
        ),
      ],
    );
  }
}

class _DeleteShelfDialog extends StatelessWidget {
  const _DeleteShelfDialog({required this.shelf, required this.books, required this.coverFor});

  final Shelf shelf;
  final List<Book> books;
  final Future<File?> Function(Book) coverFor;

  @override
  Widget build(BuildContext context) {
    final color = Color(shelfColors[shelf.color % shelfColors.length]);
    final n = books.length;
    return Dialog(
      backgroundColor: TabletColors.card,
      insetPadding: const EdgeInsets.symmetric(horizontal: 40, vertical: 24),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(32),
        side: const BorderSide(color: Color(0x17FFFFFF)),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 580),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(34, 34, 34, 26),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 150,
                height: 110,
                child: Stack(
                  clipBehavior: Clip.none,
                  alignment: Alignment.topCenter,
                  children: [
                    Positioned(
                      top: 6,
                      child: CoverFan(
                        books: books.take(3).toList(),
                        coverFor: coverFor,
                        coverSize: const Size(56, 80),
                        spread: 33,
                        angles: const [-0.24, 0, 0.21],
                        colors: [color.withValues(alpha: 0.5), color.withValues(alpha: 0.7), color],
                      ),
                    ),
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 0,
                      child: Container(
                        height: 6,
                        decoration: BoxDecoration(
                          color: color.withValues(alpha: 0.8),
                          borderRadius: BorderRadius.circular(3),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 18),
              Text(
                'Delete the “${shelf.name}” shelf?',
                textAlign: TextAlign.center,
                style: const TextStyle(fontFamily: serifFamily, fontSize: 30, fontWeight: FontWeight.w600, height: 1.2),
              ),
              const SizedBox(height: 18),
              Text.rich(
                n == 0
                    ? const TextSpan(text: 'It’s empty. It goes from all your devices.')
                    : TextSpan(
                        text: n == 1 ? 'Its ' : 'Its ',
                        children: [
                          TextSpan(
                            text: n == 1 ? 'book stays in your library' : '$n books stay in your library',
                            style: const TextStyle(fontWeight: FontWeight.w700, color: TabletColors.text),
                          ),
                          const TextSpan(text: ' and in Google Drive. Only the shelf goes, on all your devices.'),
                        ],
                      ),
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 17, height: 1.5, color: Color(0xFFA9B8B4)),
              ),
              const SizedBox(height: 28),
              Row(
                children: [
                  Expanded(
                    child: SizedBox(
                      height: 58,
                      child: OutlinedButton(
                        style: OutlinedButton.styleFrom(
                          foregroundColor: TabletColors.text,
                          side: const BorderSide(color: Color(0x29FFFFFF)),
                          shape: const StadiumBorder(),
                          textStyle: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600, fontFamily: uiFamily),
                        ),
                        onPressed: () => Navigator.pop(context, false),
                        child: const Text('Keep it'),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: SizedBox(
                      height: 58,
                      child: FilledButton(
                        style: FilledButton.styleFrom(
                          backgroundColor: const Color(0xFFEF4444),
                          foregroundColor: Colors.white,
                          shape: const StadiumBorder(),
                          textStyle: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700, fontFamily: uiFamily),
                        ),
                        onPressed: () => Navigator.pop(context, true),
                        child: const Text('Delete shelf'),
                      ),
                    ),
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

class _RenameBookSheet extends StatefulWidget {
  const _RenameBookSheet({required this.book, required this.cover});

  final Book book;
  final Future<File?> cover;

  @override
  State<_RenameBookSheet> createState() => _RenameBookSheetState();
}

class _RenameBookSheetState extends State<_RenameBookSheet> {
  late final _title = TextEditingController(text: widget.book.title);
  late final _suggestions = LibraryStore.renameSuggestions(widget.book.fileName, widget.book.title);

  @override
  void initState() {
    super.initState();
    _title.selection = TextSelection(baseOffset: 0, extentOffset: _title.text.length);
    _title.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _title.dispose();
    super.dispose();
  }

  void _submit() {
    final title = _title.text.trim();
    if (title.isNotEmpty) Navigator.pop(context, title);
  }

  @override
  Widget build(BuildContext context) {
    final text = _title.text.trim();
    return _SheetFrame(
      children: [
        Row(
          children: [
            MiniCover(book: widget.book, cover: widget.cover, width: 74, height: 106),
            const SizedBox(width: 22),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Rename book',
                    style: TextStyle(fontFamily: serifFamily, fontSize: 30, fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'File: ${widget.book.fileName}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 14, color: TabletColors.faint),
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 22),
        TextField(
          controller: _title,
          autofocus: true,
          textCapitalization: TextCapitalization.words,
          cursorColor: TabletColors.accent,
          style: const TextStyle(fontSize: 21),
          textInputAction: TextInputAction.done,
          onSubmitted: (_) => _submit(),
          decoration: _sheetField(
            TabletColors.accent,
            hint: 'Title',
            suffix: _title.text.isEmpty
                ? null
                : Padding(
                    padding: const EdgeInsets.only(right: 10),
                    child: GlassIconButton(
                      icon: Icons.close_rounded,
                      iconSize: 18,
                      size: 40,
                      border: false,
                      tooltip: 'Clear',
                      onPressed: _title.clear,
                    ),
                  ),
          ),
        ),
        if (_suggestions.isNotEmpty) ...[
          const SizedBox(height: 22),
          const TabletLabel('Suggestions'),
          const SizedBox(height: 10),
          for (final s in _suggestions) ...[
            _Suggestion(
              text: s,
              note: s.toLowerCase().contains('edition') ? 'with the edition' : 'from the file name',
              selected: s == text,
              onTap: () => setState(() {
                _title.text = s;
                _title.selection = TextSelection.collapsed(offset: s.length);
              }),
            ),
            const SizedBox(height: 10),
          ],
        ],
        const SizedBox(height: 14),
        _SheetActions(
          label: 'Rename',
          onPressed: text.isEmpty ? null : _submit,
          leading: const Row(
            children: [
              Icon(Icons.sync_rounded, size: 16, color: TabletColors.dim),
              SizedBox(width: 8),
              Flexible(
                child: Text(
                  'Also renames it in Google Drive and on your other devices.',
                  style: TextStyle(fontSize: 14, color: TabletColors.dim),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _Suggestion extends StatelessWidget {
  const _Suggestion({required this.text, required this.note, required this.selected, required this.onTap});

  final String text;
  final String note;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: selected ? const Color(0x1F5EEAD4) : const Color(0x0AFFFFFF),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: selected
            ? const BorderSide(color: Color(0x805EEAD4), width: 1.5)
            : const BorderSide(color: Color(0x17FFFFFF)),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 56),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
            child: Row(
              children: [
                Icon(
                  selected ? Icons.check_rounded : Icons.auto_awesome_outlined,
                  size: 18,
                  color: selected ? TabletColors.accent : TabletColors.dim,
                ),
                const SizedBox(width: 14),
                Expanded(child: Text(text, style: const TextStyle(fontSize: 17))),
                const SizedBox(width: 12),
                Text(note, style: const TextStyle(fontSize: 13, color: TabletColors.faint)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

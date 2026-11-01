part of 'library_screen.dart';

/// Filters on an open shelf (tablet).
enum _ShelfFilter {
  all('All'),
  reading('Reading'),
  notStarted('Not started'),
  finished('Finished');

  const _ShelfFilter(this.label);

  final String label;

  bool matches(Book book) => switch (this) {
    all => true,
    reading => book.isStarted,
    notStarted => !book.isStarted && !book.isFinished,
    finished => book.isFinished,
  };
}

/// The tablet library: the book being read glows at the top, shelves are
/// cards, then every cover. Long-press a cover to lift it and act on it.
extension _TabletLibrary on _LibraryScreenState {
  Widget _tablet(BuildContext context) {
    final shelf = _shelf;
    final books = _visibleBooks.where(shelf == null ? (_) => true : _shelfFilter.matches).toList();
    final topInset = MediaQuery.paddingOf(context).top;
    final slivers = _selecting
        ? [_selectionHeader(context, books, topInset), _tabletGrid(books)]
        : shelf != null
        ? [_shelfHeader(context, shelf, topInset), _tabletGrid(books)]
        : _homeSlivers(context, books, topInset);
    return Theme(
      data: tabletTheme(),
      child: PopScope(
        canPop: !_selecting && shelf == null,
        onPopInvokedWithResult: (didPop, _) {
          if (didPop) return;
          if (_selecting) {
            _endSelection();
          } else {
            _select();
          }
        },
        child: Scaffold(
          backgroundColor: TabletColors.background,
          floatingActionButton: _selecting ? null : _AddPdfButton(onPressed: _addBooks),
          bottomNavigationBar: _selecting
              ? _SelectionBar(count: _picked.length, onAdd: _picked.isEmpty ? null : _showAddToShelfSheet)
              : null,
          body: TweenAnimationBuilder<double>(
            tween: Tween(end: _blurLibrary ? 6 : 0),
            duration: const Duration(milliseconds: 220),
            // Always wrapped (only enabled while blurred), so the scroll
            // position survives.
            builder: (context, sigma, child) => ImageFiltered(
              enabled: sigma > 0,
              imageFilter: ui.ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
              child: child,
            ),
            child: RefreshIndicator(
              onRefresh: librarySync.syncNow,
              color: TabletColors.accent,
              backgroundColor: TabletColors.card,
              edgeOffset: topInset,
              notificationPredicate: (n) => n.depth == 0 && widget.sync.status == SyncStatus.connected,
              child: CustomScrollView(physics: const AlwaysScrollableScrollPhysics(), slivers: slivers),
            ),
          ),
        ),
      ),
    );
  }

  // --- Home -----------------------------------------------------------------

  List<Widget> _homeSlivers(BuildContext context, List<Book> books, double topInset) {
    final query = _search.text.trim();
    final current = _continueReading;
    final hero = current.isEmpty ? null : current.first;
    final top = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(height: topInset + 14),
        _homeHeader(context),
        if (_searchOpen) ...[const SizedBox(height: 20), _searchField()],
        if (query.isEmpty) ...[
          if (hero != null)
            _Hero(
              book: hero,
              cover: _covers.coverFor(hero),
              transfer: librarySync.transferFor(hero.id),
              greeting: greeting(widget.sync.account?.displayName),
              jump: librarySync.pendingJumpFor(hero.id),
              onOpen: () async {
                // Another device got further: Continue goes there.
                if (librarySync.pendingJumpFor(hero.id) != null) await librarySync.acceptJump(hero.id);
                await _open(hero);
              },
              onContents: () => _open(hero, contents: true),
            )
          else
            Padding(
              padding: const EdgeInsets.fromLTRB(40, 36, 40, 0),
              child: Text(
                greeting(widget.sync.account?.displayName),
                style: const TextStyle(fontFamily: serifFamily, fontSize: 36, fontWeight: FontWeight.w600),
              ),
            ),
          if (current.length > 1)
            Padding(
              padding: const EdgeInsets.fromLTRB(40, 44, 40, 0),
              child: Row(
                children: [
                  for (final (i, book) in current.skip(1).take(2).indexed) ...[
                    if (i > 0) const SizedBox(width: 16),
                    Expanded(
                      child: _AlsoReading(book: book, cover: _covers.coverFor(book), onTap: () => _open(book)),
                    ),
                  ],
                  if (current.length == 2) ...[const SizedBox(width: 16), const Spacer()],
                ],
              ),
            ),
        ],
      ],
    );
    return [
      SliverToBoxAdapter(
        child: hero == null || query.isNotEmpty
            ? top
            : CoverTintBuilder(
                book: hero,
                cover: _covers.coverFor(hero),
                builder: (context, tint) => Stack(
                  children: [
                    Positioned.fill(child: _Ambient(tint: tint)),
                    top,
                  ],
                ),
              ),
      ),
      if (query.isEmpty) SliverToBoxAdapter(child: _shelvesRow(context)),
      SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(40, 40, 40, 20),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                child: Text.rich(
                  TextSpan(
                    text: query.isEmpty ? 'All books' : 'Results',
                    children: [
                      TextSpan(
                        text: '  ${books.length}',
                        style: const TextStyle(
                          fontFamily: uiFamily,
                          fontSize: 16,
                          fontWeight: FontWeight.w500,
                          color: TabletColors.dim,
                        ),
                      ),
                    ],
                  ),
                  style: const TextStyle(fontFamily: serifFamily, fontSize: 26, fontWeight: FontWeight.w600),
                ),
              ),
              _sortPill(),
            ],
          ),
        ),
      ),
      _tabletGrid(books),
    ];
  }

  Widget _homeHeader(BuildContext context) {
    final account = widget.sync.account;
    final name = account == null ? null : (account.displayName.isNotEmpty ? account.displayName : account.email);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 40),
      child: Row(
        children: [
          Image.asset('assets/icons/shelfsync.png', width: 40, height: 40, filterQuality: FilterQuality.medium),
          const SizedBox(width: 12),
          const Expanded(
            child: Text(
              'ShelfSync',
              maxLines: 1,
              overflow: TextOverflow.fade,
              softWrap: false,
              style: TextStyle(fontSize: 19, fontWeight: FontWeight.w700, letterSpacing: 0.2),
            ),
          ),
          TabletSyncPill(sync: widget.sync, librarySync: librarySync),
          const SizedBox(width: 12),
          GlassIconButton(
            icon: _searchOpen ? Icons.close_rounded : Icons.search_rounded,
            tooltip: _searchOpen ? 'Close search' : 'Search your books',
            onPressed: () {
              if (_searchOpen) {
                _search.clear();
                _update(() => _searchOpen = false);
              } else {
                _update(() => _searchOpen = true);
                WidgetsBinding.instance.addPostFrameCallback((_) => _searchFocus.requestFocus());
              }
            },
          ),
          const SizedBox(width: 12),
          AccountRing(
            initial: name?.characters.first.toUpperCase(),
            onTap: () => showAccountSheet(context, widget.sync, librarySync),
          ),
        ],
      ),
    );
  }

  Widget _searchField() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 40),
      child: Container(
        height: 56,
        padding: const EdgeInsets.symmetric(horizontal: 20),
        decoration: BoxDecoration(
          color: TabletColors.glass,
          borderRadius: BorderRadius.circular(28),
          border: Border.all(color: TabletColors.glassBorder),
        ),
        child: Row(
          children: [
            const Icon(Icons.search_rounded, color: TabletColors.dim),
            const SizedBox(width: 12),
            Expanded(
              child: TextField(
                controller: _search,
                focusNode: _searchFocus,
                style: const TextStyle(fontSize: 17, color: TabletColors.text),
                cursorColor: TabletColors.accent,
                textInputAction: TextInputAction.search,
                decoration: const InputDecoration(
                  hintText: 'Search your books',
                  hintStyle: TextStyle(color: TabletColors.faint),
                  border: InputBorder.none,
                  isDense: true,
                ),
              ),
            ),
            if (_search.text.isNotEmpty)
              IconButton(
                tooltip: 'Clear',
                color: TabletColors.dim,
                icon: const Icon(Icons.close_rounded),
                onPressed: _search.clear,
              ),
          ],
        ),
      ),
    );
  }

  Widget _sortPill() {
    return PopupMenuButton<LibrarySort>(
      tooltip: 'Sort',
      initialValue: _sort,
      position: PopupMenuPosition.under,
      onSelected: (sort) => _update(() => _sort = sort),
      itemBuilder: (_) => [
        for (final sort in LibrarySort.values)
          PopupMenuItem(
            value: sort,
            child: Row(
              children: [
                SizedBox(
                  width: 28,
                  child: sort == _sort ? const Icon(Icons.check_rounded, size: 18, color: TabletColors.accent) : null,
                ),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(sort.label, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                    Text(sort.hint, style: const TextStyle(fontSize: 13, color: TabletColors.dim)),
                  ],
                ),
              ],
            ),
          ),
      ],
      child: Container(
        height: 40,
        padding: const EdgeInsets.only(left: 16, right: 12),
        decoration: BoxDecoration(color: const Color(0x12FFFFFF), borderRadius: BorderRadius.circular(20)),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              _sort.label,
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: TabletColors.soft),
            ),
            const SizedBox(width: 6),
            const Icon(Icons.keyboard_arrow_down_rounded, size: 18, color: TabletColors.soft),
          ],
        ),
      ),
    );
  }

  Widget _shelvesRow(BuildContext context) {
    final shelves = store.shelves;
    return Padding(
      padding: const EdgeInsets.only(top: 40),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 40),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                const Expanded(
                  child: Text(
                    'Shelves',
                    style: TextStyle(fontFamily: serifFamily, fontSize: 26, fontWeight: FontWeight.w600),
                  ),
                ),
                if (shelves.isNotEmpty)
                  TextButton(
                    style: TextButton.styleFrom(
                      foregroundColor: TabletColors.accent,
                      textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600, fontFamily: uiFamily),
                    ),
                    onPressed: _showManageShelves,
                    child: const Text('Manage'),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          SizedBox(
            height: 116,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 40),
              children: [
                for (final shelf in shelves) ...[
                  _ShelfCard(
                    shelf: shelf,
                    count: _shelfCount(shelf),
                    books: _shelfBooks(shelf).take(3).toList(),
                    coverFor: _covers.coverFor,
                    onTap: () => _openShelf(shelf),
                    onMenu: (_) => _tabletEditShelf(shelf),
                  ),
                  const SizedBox(width: 14),
                ],
                _NewShelfCard(onTap: _createShelfAndOpen),
              ],
            ),
          ),
        ],
      ),
    );
  }

  List<Book> _shelfBooks(Shelf shelf) {
    final books = [for (final id in shelf.bookIds) ?store.byId(id)]
      ..sort((a, b) => (b.lastReadAt ?? b.addedAt).compareTo(a.lastReadAt ?? a.addedAt));
    return books;
  }

  void _openShelf(Shelf shelf) {
    _select(shelfId: shelf.id);
    _update(() => _shelfFilter = _ShelfFilter.all);
  }

  Future<void> _createShelfAndOpen() async {
    final shelf = await _tabletCreateShelf();
    if (shelf != null) _openShelf(shelf);
  }

  Future<void> _showManageShelves() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      constraints: const BoxConstraints(maxWidth: 840),
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(34))),
      builder: (context) => ListenableBuilder(
        listenable: store,
        builder: (context, _) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(32, 14, 32, 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const SheetHandle(),
                const SizedBox(height: 20),
                const Text(
                  'Your shelves',
                  style: TextStyle(fontFamily: serifFamily, fontSize: 28, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 12),
                for (final shelf in store.shelves)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Row(
                      children: [
                        _ColorDot(shelfColors[shelf.color % shelfColors.length], size: 12),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Text(
                            shelf.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
                          ),
                        ),
                        Text(
                          '${_shelfCount(shelf)} books',
                          style: const TextStyle(fontSize: 14, color: TabletColors.dim),
                        ),
                        const SizedBox(width: 8),
                        IconButton(
                          tooltip: 'Rename ${shelf.name}',
                          color: TabletColors.soft,
                          icon: const Icon(Icons.edit_outlined),
                          onPressed: () => _tabletEditShelf(shelf),
                        ),
                        IconButton(
                          tooltip: 'Delete ${shelf.name}',
                          color: TabletColors.danger,
                          icon: const Icon(Icons.delete_outline_rounded),
                          onPressed: () => _tabletDeleteShelf(shelf),
                        ),
                      ],
                    ),
                  ),
                const SizedBox(height: 12),
                Align(
                  alignment: Alignment.centerLeft,
                  child: GlassPillButton(
                    label: 'Create shelf',
                    icon: Icons.add_rounded,
                    height: 48,
                    fontSize: 16,
                    onPressed: () async {
                      Navigator.pop(context);
                      await _createShelfAndOpen();
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // --- Grid -----------------------------------------------------------------

  Widget _tabletGrid(List<Book> books) {
    if (books.isEmpty) {
      final libraryEmpty = store.books.isEmpty;
      return SliverFillRemaining(
        hasScrollBody: false,
        child: _EmptyState(
          title: libraryEmpty ? 'Your library is empty' : (_shelf != null ? 'Nothing here yet' : 'No books found'),
          hint: libraryEmpty
              ? 'Tap "Add PDF" to import a book.'
              : (_shelf != null ? 'Tap "Add books" to put books on this shelf.' : 'Try another search.'),
        ),
      );
    }
    final placeholders = _shelf == null && !_selecting && _search.text.trim().isEmpty ? librarySync.incoming : 0;
    return SliverLayoutBuilder(
      builder: (context, constraints) {
        const side = 40.0, gap = 20.0;
        final width = constraints.crossAxisExtent - side * 2;
        final columns = ((width + gap) / 145).floor().clamp(3, 9);
        final tile = (width - gap * (columns - 1)) / columns;
        return SliverPadding(
          padding: const EdgeInsets.fromLTRB(side, 0, side, 140),
          sliver: SliverGrid.builder(
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: columns,
              mainAxisSpacing: 28,
              crossAxisSpacing: gap,
              mainAxisExtent: tile / 0.7 + 44,
            ),
            // Books Drive has found but not added yet hold their places.
            itemCount: books.length + placeholders,
            itemBuilder: (context, i) {
              if (i >= books.length) return const _ArrivingTile();
              final book = books[i];
              return _GridTile(
                book: book,
                cover: _covers.coverFor(book),
                transfer: librarySync.transferFor(book.id),
                arrived: librarySync.arrived.contains(book.id),
                selecting: _selecting,
                selected: _picked.contains(book.id),
                onTap: () {
                  if (_selecting) {
                    _update(() {
                      if (!_picked.remove(book.id)) _picked.add(book.id);
                    });
                  } else {
                    _open(book);
                  }
                },
                onLongPress: () {
                  if (_selecting) {
                    _update(() => _picked.add(book.id));
                  } else {
                    _showBookActions(book);
                  }
                },
              );
            },
          ),
        );
      },
    );
  }

  // --- Shelf ----------------------------------------------------------------

  Widget _shelfHeader(BuildContext context, Shelf shelf, double topInset) {
    final color = Color(shelfColors[shelf.color % shelfColors.length]);
    final all = _shelfBooks(shelf);
    final reading = all.where((b) => b.isStarted).length;
    final finished = all.where((b) => b.isFinished).length;
    final counts = {for (final f in _ShelfFilter.values) f: all.where(f.matches).length};
    return SliverToBoxAdapter(
      child: Stack(
        children: [
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: RadialGradient(
                  center: const Alignment(0.5, -0.75),
                  radius: 1.1,
                  colors: [color.withValues(alpha: 0.42), color.withValues(alpha: 0)],
                ),
              ),
              child: const DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    stops: [0.5, 1],
                    colors: [Color(0x000C1012), TabletColors.background],
                  ),
                ),
              ),
            ),
          ),
          Padding(
            padding: EdgeInsets.fromLTRB(32, topInset + 14, 32, 22),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    GlassIconButton(
                      icon: Icons.chevron_left_rounded,
                      iconSize: 28,
                      size: 52,
                      tooltip: 'Back to library',
                      onPressed: () => _select(),
                    ),
                    const SizedBox(width: 10),
                    const Expanded(
                      child: Text('Library', style: TextStyle(fontSize: 16, color: TabletColors.muted)),
                    ),
                    GlassIconButton(
                      icon: Icons.more_horiz_rounded,
                      size: 52,
                      tooltip: 'Edit shelf',
                      onPressed: () => _tabletEditShelf(shelf),
                    ),
                  ],
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(8, 30, 8, 30),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Container(
                                  width: 12,
                                  height: 12,
                                  decoration: BoxDecoration(color: color, shape: BoxShape.circle),
                                ),
                                const SizedBox(width: 10),
                                TabletLabel('Shelf', color: Color.lerp(color, Colors.white, 0.35)!),
                              ],
                            ),
                            const SizedBox(height: 14),
                            Text(
                              shelf.name,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontFamily: serifFamily,
                                fontSize: 58,
                                fontWeight: FontWeight.w600,
                                height: 1,
                                letterSpacing: -1,
                              ),
                            ),
                            const SizedBox(height: 14),
                            Text(
                              [
                                '${all.length} book${all.length == 1 ? '' : 's'}',
                                if (reading > 0) '$reading in progress',
                                if (finished > 0) '$finished finished',
                              ].join(' · '),
                              style: const TextStyle(fontSize: 17, color: TabletColors.muted),
                            ),
                            const SizedBox(height: 26),
                            Wrap(
                              spacing: 10,
                              runSpacing: 10,
                              children: [
                                TealButton(
                                  label: 'Add books',
                                  icon: Icons.add_rounded,
                                  height: 54,
                                  fontSize: 17,
                                  padding: const EdgeInsets.only(left: 20, right: 24),
                                  onPressed: () => _addBooksTo(shelf),
                                ),
                                GlassPillButton(label: 'Rename', onPressed: () => _tabletEditShelf(shelf)),
                              ],
                            ),
                          ],
                        ),
                      ),
                      if (all.isNotEmpty && MediaQuery.sizeOf(context).width >= 640)
                        _ShelfFan(books: all.take(3).toList(), coverFor: _covers.coverFor),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Wrap(
                    spacing: 10,
                    runSpacing: 10,
                    children: [
                      for (final filter in _ShelfFilter.values)
                        TabletChip(
                          label: '${filter.label} ${counts[filter]}',
                          selected: _shelfFilter == filter,
                          onTap: () => _update(() => _shelfFilter = filter),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // --- Long-press: lift the cover -----------------------------------------------

  Future<void> _showBookActions(Book book) async {
    HapticFeedback.mediumImpact();
    final action = await showGeneralDialog<String>(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'Close',
      barrierColor: Colors.transparent,
      transitionDuration: const Duration(milliseconds: 220),
      transitionBuilder: (context, animation, _, child) {
        final curve = CurvedAnimation(parent: animation, curve: Curves.easeOutCubic);
        return FadeTransition(
          opacity: curve,
          child: ScaleTransition(scale: Tween(begin: 0.96, end: 1.0).animate(curve), child: child),
        );
      },
      pageBuilder: (dialogContext, _, _) => Theme(
        data: tabletTheme(),
        child: _BookActionsPage(
          book: book,
          cover: _covers.coverFor(book),
          store: store,
          onToggleShelf: (shelf, on) {
            store.setOnShelf(shelf.id, book.id, on);
            librarySync.syncNow();
          },
        ),
      ),
    );
    if (!mounted) return;
    switch (action) {
      case 'open':
        await _open(book);
      case 'rename':
        await _tabletRenameBook(book);
      case 'new-shelf':
        await _tabletCreateShelf(bookIds: [book.id]);
      case 'remove-local':
        await store.removeLocalCopy(book.id);
        _snack('Removed from this tablet. "${book.title}" stays in Google Drive.');
      case 'select':
        _update(() {
          _selecting = true;
          _picked
            ..clear()
            ..add(book.id);
        });
      case 'delete':
        await _confirmDelete(book);
    }
  }

  // --- Select several -----------------------------------------------------------

  void _endSelection() => _update(() {
    _selecting = false;
    _picked.clear();
  });

  Widget _selectionHeader(BuildContext context, List<Book> books, double topInset) {
    final all = books.isNotEmpty && books.every((b) => _picked.contains(b.id));
    return SliverPadding(
      padding: EdgeInsets.fromLTRB(16, topInset + 8, 16, 32),
      sliver: SliverToBoxAdapter(
        child: Container(
          height: 84,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            color: const Color(0xFF1B2427),
            borderRadius: BorderRadius.circular(26),
            border: Border.all(color: const Color(0x405EEAD4)),
          ),
          child: Row(
            children: [
              GlassIconButton(
                icon: Icons.close_rounded,
                size: 52,
                border: false,
                tooltip: 'Cancel selection',
                onPressed: _endSelection,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  '${_picked.length} selected',
                  style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
                ),
              ),
              GlassPillButton(
                label: all ? 'Select none' : 'Select all',
                height: 46,
                fontSize: 15,
                onPressed: () => _update(() {
                  if (all) {
                    _picked.clear();
                  } else {
                    _picked.addAll(books.map((b) => b.id));
                  }
                }),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _showAddToShelfSheet() async {
    final ids = [
      for (final b in _visibleBooks)
        if (_picked.contains(b.id)) b.id,
    ];
    final books = [for (final id in ids) ?store.byId(id)];
    if (books.isEmpty) return;
    final result = await showModalBottomSheet<(Shelf?, String?, int)>(
      context: context,
      isScrollControlled: true,
      constraints: const BoxConstraints(maxWidth: 840),
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(34))),
      builder: (context) => _AddToShelfSheet(
        books: books,
        shelves: store.shelves,
        coverFor: _covers.coverFor,
        shelfBooks: _shelfBooks,
        nextColor: store.nextShelfColor,
      ),
    );
    if (result == null || !mounted) return;
    final (existing, name, color) = result;
    final shelf = existing ?? await store.createShelf(name!, color: color);
    await _addToShelf(shelf, ids);
    _endSelection();
  }
}

// --- Pieces -------------------------------------------------------------------

/// The page's glow in the colour of the book being read, fading into the
/// background further down.
class _Ambient extends StatelessWidget {
  const _Ambient({required this.tint});

  final Color tint;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: RadialGradient(
            center: const Alignment(-0.56, -0.55),
            radius: 0.95,
            colors: [tint.withValues(alpha: 0.62), tint.withValues(alpha: 0)],
            stops: const [0, 0.85],
          ),
        ),
        child: const DecoratedBox(
          decoration: BoxDecoration(
            gradient: RadialGradient(
              center: Alignment(0.84, -1),
              radius: 0.7,
              colors: [Color(0x4714B8A6), Color(0x0014B8A6)],
            ),
          ),
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                stops: [0.55, 1],
                colors: [Color(0x000C1012), TabletColors.background],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The book being read: a large, slightly turned cover glowing in its own
/// colour, and a big Continue.
class _Hero extends StatelessWidget {
  const _Hero({
    required this.book,
    required this.cover,
    required this.transfer,
    required this.greeting,
    required this.jump,
    required this.onOpen,
    required this.onContents,
  });

  final Book book;
  final Future<File?> cover;
  final Transfer? transfer;
  final String greeting;

  /// A newer position from another device, which Continue will open at.
  final ProgressRecord? jump;
  final VoidCallback onOpen;
  final VoidCallback onContents;

  @override
  Widget build(BuildContext context) {
    final count = book.pageCount;
    final device = book.progressDevice;
    final when = book.lastReadAt;
    final last = when == null
        ? null
        : (device == null ? 'Last read here · ${timeAgo(when)}' : 'Last read on $device · ${timeAgo(when)}');
    final narrow = MediaQuery.sizeOf(context).width < 640;
    final coverWidth = narrow ? 150.0 : 232.0;
    return Padding(
      padding: const EdgeInsets.fromLTRB(40, 36, 40, 0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          GestureDetector(
            onTap: onOpen,
            child: SizedBox(
              width: coverWidth,
              height: coverWidth / 0.703,
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  Positioned(
                    left: 18,
                    right: 18,
                    bottom: -26,
                    child: CoverTintBuilder(
                      book: book,
                      cover: cover,
                      builder: (context, tint) =>
                          Glow(color: tint.withValues(alpha: 0.65), width: coverWidth - 36, height: 40),
                    ),
                  ),
                  Positioned.fill(
                    child: Transform(
                      alignment: Alignment.centerLeft,
                      transform: Matrix4.identity()
                        ..setEntry(3, 2, 0.0011)
                        ..rotateY(-0.157)
                        ..rotateZ(-0.017),
                      child: TabletCover(
                        book: book,
                        cover: cover,
                        transfer: transfer,
                        spine: 5,
                        shadow: const BoxShadow(
                          color: Color(0xE6000000),
                          blurRadius: 60,
                          offset: Offset(0, 30),
                          spreadRadius: -18,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 40),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(greeting, style: const TextStyle(fontSize: 16, color: Color(0xFFA9C4D8))),
                const SizedBox(height: 14),
                const TabletLabel('Continue reading', color: TabletColors.accent),
                const SizedBox(height: 14),
                Text(
                  book.title,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontFamily: serifFamily,
                    fontSize: 36,
                    fontWeight: FontWeight.w600,
                    height: 1.12,
                  ),
                ),
                if (book.chapter != null && jump == null) ...[
                  const SizedBox(height: 14),
                  Text(
                    chapterLine(book.chapter!),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 17, color: TabletColors.muted),
                  ),
                ],
                if (jump != null) ...[
                  const SizedBox(height: 20),
                  _JumpNote(jump: jump!),
                ] else ...[
                  const SizedBox(height: 20),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.baseline,
                    textBaseline: TextBaseline.alphabetic,
                    children: [
                      Text(percentRead(book), style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w700)),
                      if (count != null) ...[
                        const SizedBox(width: 10),
                        Text(
                          'Page ${book.lastPage} of $count',
                          style: const TextStyle(fontSize: 15, color: TabletColors.muted),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 10),
                  TabletProgress(value: book.progress, height: 8, glow: true),
                  if (last != null) ...[
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        Icon(
                          device == null ? Icons.tablet_android_outlined : Icons.laptop_outlined,
                          size: 16,
                          color: TabletColors.dim,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            last,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 14, color: TabletColors.dim),
                          ),
                        ),
                      ],
                    ),
                  ],
                ],
                const SizedBox(height: 24),
                Row(
                  children: [
                    Flexible(
                      child: TealButton(
                        label: jump != null
                            ? 'Continue on page ${jump!.page}'
                            : (book.isLocal ? 'Continue' : 'Download and continue'),
                        icon: book.isLocal ? Icons.play_arrow_rounded : Icons.cloud_download_outlined,
                        onPressed: onOpen,
                      ),
                    ),
                    const SizedBox(width: 12),
                    GlassIconButton(
                      icon: Icons.format_list_bulleted_rounded,
                      size: 60,
                      tooltip: 'Contents',
                      onPressed: onContents,
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// "You got to page 214 on thisara-PC 12 min ago. Continue opens there."
class _JumpNote extends StatelessWidget {
  const _JumpNote({required this.jump});

  final ProgressRecord jump;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: const Color(0x1A5EEAD4),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0x475EEAD4)),
      ),
      child: Row(
        children: [
          const Icon(Icons.laptop_outlined, size: 20, color: TabletColors.accent),
          const SizedBox(width: 12),
          Expanded(
            child: Text.rich(
              TextSpan(
                text: 'You got to ',
                children: [
                  TextSpan(
                    text: 'page ${jump.page}',
                    style: const TextStyle(fontWeight: FontWeight.w700, color: Colors.white),
                  ),
                  TextSpan(text: ' on ${jump.device} ${timeAgo(jump.updated)}. Continue opens there.'),
                ],
              ),
              style: const TextStyle(fontSize: 15, height: 1.35, color: Color(0xFFCCFBF1)),
            ),
          ),
        ],
      ),
    );
  }
}

class _AlsoReading extends StatelessWidget {
  const _AlsoReading({required this.book, required this.cover, required this.onTap});

  final Book book;
  final Future<File?> cover;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final device = book.progressDevice;
    final when = book.lastReadAt;
    final note = [
      percentRead(book),
      if (device != null) 'read on $device' else if (when != null) 'read ${timeAgo(when)}',
    ].join(' · ');
    return Material(
      color: const Color(0x0DFFFFFF),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: const BorderSide(color: TabletColors.line),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              MiniCover(book: book, cover: cover, width: 52, height: 74),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      book.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 8),
                    TabletProgress(value: book.progress, height: 4),
                    const SizedBox(height: 8),
                    Text(
                      note,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 13, color: TabletColors.dim),
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
}

class _ShelfCard extends StatelessWidget {
  const _ShelfCard({
    required this.shelf,
    required this.count,
    required this.books,
    required this.coverFor,
    required this.onTap,
    required this.onMenu,
    this.note,
  });

  final Shelf shelf;
  final int count;

  /// Replaces "N books" under the name.
  final String? note;
  final List<Book> books;
  final Future<File?> Function(Book) coverFor;
  final VoidCallback onTap;
  final ValueChanged<Offset> onMenu;

  @override
  Widget build(BuildContext context) {
    final color = Color(shelfColors[shelf.color % shelfColors.length]);
    return GestureDetector(
      onLongPressStart: (d) => onMenu(d.globalPosition),
      child: Material(
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(22),
          side: BorderSide(color: color.withValues(alpha: 0.3)),
        ),
        color: Colors.transparent,
        child: Ink(
          width: 198,
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [color.withValues(alpha: 0.3), const Color(0x08FFFFFF)],
            ),
          ),
          child: InkWell(
            onTap: onTap,
            child: Stack(
              children: [
                Positioned(
                  right: 10,
                  top: 6,
                  child: CoverFan(
                    books: books,
                    coverFor: coverFor,
                    coverSize: const Size(34, 48),
                    colors: [color.withValues(alpha: 0.5), color.withValues(alpha: 0.7), color],
                  ),
                ),
                Positioned(
                  left: 18,
                  right: 18,
                  bottom: 16,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        shelf.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        note ?? '$count book${count == 1 ? '' : 's'}',
                        style: const TextStyle(fontSize: 14, color: Color(0xFFA9B8B4)),
                      ),
                    ],
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

class _NewShelfCard extends StatelessWidget {
  const _NewShelfCard({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return DashedBorder(
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          borderRadius: BorderRadius.circular(22),
          onTap: onTap,
          child: const SizedBox(
            width: 128,
            height: 116,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.add_rounded, color: TabletColors.muted),
                SizedBox(height: 6),
                Text(
                  'Create shelf',
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: TabletColors.muted),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The shelf's first three covers fanned out beside its name.
class _ShelfFan extends StatelessWidget {
  const _ShelfFan({required this.books, required this.coverFor});

  final List<Book> books;
  final Future<File?> Function(Book) coverFor;

  @override
  Widget build(BuildContext context) {
    Widget at(int i, double left, double top, double angle, Size size) => Positioned(
      left: left,
      top: top,
      child: Transform.rotate(
        angle: angle,
        child: MiniCover(book: books[i], cover: coverFor(books[i]), width: size.width, height: size.height),
      ),
    );
    const side = Size(150, 214), front = Size(164, 234);
    return SizedBox(
      width: 300,
      height: 290,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          if (books.length > 1) at(1, 0, 50, -0.244, side),
          if (books.length > 2) at(2, 150, 48, 0.21, side),
          at(0, books.length == 1 ? 68 : 70, 20, 0, front),
        ],
      ),
    );
  }
}

/// A cover in the grid with its progress and a one-line status.
class _GridTile extends StatelessWidget {
  const _GridTile({
    required this.book,
    required this.cover,
    required this.transfer,
    required this.selecting,
    required this.selected,
    required this.onTap,
    required this.onLongPress,
    this.arrived = false,
  });

  final Book book;
  final Future<File?> cover;
  final Transfer? transfer;

  /// Came from Drive while the app was open (and hasn't been read yet).
  final bool arrived;
  final bool selecting;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  String get _note {
    final t = transfer;
    if (t != null) return t.kind == TransferKind.download ? 'Downloading…' : 'Uploading…';
    if (book.isFinished) return 'Finished';
    if (book.isStarted) return percentRead(book);
    if (arrived && book.lastOpenedAt == null) return 'Just synced · new';
    final size = book.sizeBytes;
    return !book.isLocal && size != null ? 'New · ${formatSize(size)}' : 'New';
  }

  @override
  Widget build(BuildContext context) {
    final dimmed = selecting && !selected;
    return Semantics(
      label: book.title,
      selected: selecting ? selected : null,
      button: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        onLongPress: onLongPress,
        child: AnimatedOpacity(
          duration: const Duration(milliseconds: 160),
          opacity: dimmed ? 0.6 : 1,
          child: AnimatedScale(
            duration: const Duration(milliseconds: 160),
            scale: selected ? 0.93 : 1,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: Stack(
                    clipBehavior: Clip.none,
                    fit: StackFit.expand,
                    children: [
                      TabletCover(book: book, cover: cover, transfer: transfer, badges: !selecting),
                      if (selected)
                        Positioned(
                          left: -7,
                          top: -7,
                          right: -7,
                          bottom: -7,
                          child: IgnorePointer(
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                border: Border.all(color: TabletColors.accent, width: 3),
                                borderRadius: BorderRadius.circular(11),
                              ),
                            ),
                          ),
                        ),
                      if (selecting) Positioned(top: 8, right: 8, child: _SelectMark(selected: selected)),
                    ],
                  ),
                ),
                const SizedBox(height: 10),
                selected ? const SizedBox(height: 3) : TabletProgress(value: book.isFinished ? 1 : book.progress),
                const SizedBox(height: 10),
                Text(
                  selected ? 'Selected' : _note,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13,
                    color: selected ? TabletColors.accent : TabletColors.dim,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
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

/// A book on its way from Drive: a cover-shaped placeholder with a sheen
/// sweeping across it.
class _ArrivingTile extends StatefulWidget {
  const _ArrivingTile();

  @override
  State<_ArrivingTile> createState() => _ArrivingTileState();
}

class _ArrivingTileState extends State<_ArrivingTile> with SingleTickerProviderStateMixin {
  late final _sheen = AnimationController(vsync: this, duration: const Duration(milliseconds: 1500))..repeat();

  @override
  void dispose() {
    _sheen.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    const base = Color(0xFF182023);
    return Semantics(
      label: 'A book arriving from Google Drive',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: AnimatedBuilder(
              animation: _sheen,
              builder: (context, _) {
                final x = -1.5 + 3 * _sheen.value;
                return DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: TabletCover.radius,
                    gradient: LinearGradient(
                      begin: Alignment(x - 0.6, -0.3),
                      end: Alignment(x + 0.6, 0.3),
                      colors: const [base, Color(0xFF222C30), base],
                    ),
                  ),
                );
              },
            ),
          ),
          const SizedBox(height: 10),
          Container(height: 3, color: base),
          const SizedBox(height: 10),
          Align(
            alignment: Alignment.centerLeft,
            child: Container(
              width: 64,
              height: 12,
              decoration: BoxDecoration(color: base, borderRadius: BorderRadius.circular(6)),
            ),
          ),
        ],
      ),
    );
  }
}

class _SelectMark extends StatelessWidget {
  const _SelectMark({required this.selected});

  final bool selected;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 30,
      height: 30,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: selected ? TabletColors.accent : const Color(0x59000000),
        border: Border.all(
          color: selected ? TabletColors.background : const Color(0xD9FFFFFF),
          width: selected ? 3 : 2,
        ),
      ),
      child: selected ? const Icon(Icons.check_rounded, size: 16, color: TabletColors.onAccent) : null,
    );
  }
}

class _AddPdfButton extends StatelessWidget {
  const _AddPdfButton({required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(right: 24, bottom: 24),
      decoration: const BoxDecoration(
        borderRadius: BorderRadius.all(Radius.circular(32)),
        boxShadow: [
          BoxShadow(color: Color(0xE6000000), blurRadius: 36, offset: Offset(0, 16), spreadRadius: -10),
          BoxShadow(color: Color(0x0FFFFFFF), spreadRadius: 6),
        ],
      ),
      child: Material(
        color: TabletColors.text,
        shape: const StadiumBorder(),
        child: InkWell(
          customBorder: const StadiumBorder(),
          onTap: onPressed,
          child: const SizedBox(
            height: 64,
            child: Padding(
              padding: EdgeInsets.only(left: 24, right: 28),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.add_rounded, size: 24, color: TabletColors.background),
                  SizedBox(width: 10),
                  Text(
                    'Add PDF',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: TabletColors.background),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _SelectionBar extends StatelessWidget {
  const _SelectionBar({required this.count, required this.onAdd});

  final int count;
  final VoidCallback? onAdd;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: TabletColors.sheet,
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
        border: Border(top: BorderSide(color: Color(0x17FFFFFF))),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(32, 16, 32, 16),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  count == 0 ? 'Tap covers to select them' : 'Put them on a shelf',
                  style: const TextStyle(fontSize: 16, color: TabletColors.dim),
                ),
              ),
              TealButton(
                label: count == 0 ? 'Add to shelf' : 'Add $count to a shelf',
                icon: Icons.shelves,
                height: 54,
                fontSize: 16,
                padding: const EdgeInsets.symmetric(horizontal: 22),
                onPressed: onAdd,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The lifted cover with what you can do with the book beside it.
class _BookActionsPage extends StatelessWidget {
  const _BookActionsPage({required this.book, required this.cover, required this.store, required this.onToggleShelf});

  final Book book;
  final Future<File?> cover;
  final LibraryStore store;
  final void Function(Shelf shelf, bool on) onToggleShelf;

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final showCover = size.width >= 720;
    final coverWidth = math.min(250.0, size.width * 0.3);
    return Material(
      type: MaterialType.transparency,
      child: Stack(
        children: [
          Positioned.fill(
            child: GestureDetector(
              onTap: () => Navigator.pop(context),
              child: BackdropFilter(
                filter: ui.ImageFilter.blur(sigmaX: 6, sigmaY: 6),
                child: const ColoredBox(color: Color(0x9E06090A)),
              ),
            ),
          ),
          SafeArea(
            child: Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    if (showCover) ...[
                      SizedBox(
                        width: coverWidth,
                        height: coverWidth / 0.703,
                        child: Stack(
                          clipBehavior: Clip.none,
                          children: [
                            Positioned(
                              left: 20,
                              right: 20,
                              bottom: -30,
                              child: CoverTintBuilder(
                                book: book,
                                cover: cover,
                                builder: (context, tint) => Glow(
                                  color: tint.withValues(alpha: 0.7),
                                  width: coverWidth - 40,
                                  height: 50,
                                  blur: 30,
                                ),
                              ),
                            ),
                            Positioned.fill(
                              child: Transform.rotate(
                                angle: -0.052,
                                child: Transform.scale(
                                  scale: 1.02,
                                  child: TabletCover(
                                    book: book,
                                    cover: cover,
                                    spine: 4,
                                    shadow: const BoxShadow(
                                      color: Colors.black,
                                      blurRadius: 70,
                                      offset: Offset(0, 40),
                                      spreadRadius: -20,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 34),
                    ],
                    ConstrainedBox(
                      constraints: BoxConstraints(maxWidth: math.min(428, size.width - 64)),
                      child: ListenableBuilder(listenable: store, builder: (context, _) => _card(context)),
                    ),
                  ],
                ),
              ),
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 48 + MediaQuery.paddingOf(context).bottom,
            child: const IgnorePointer(
              child: Text(
                'Tap anywhere outside to close',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 15, color: TabletColors.dim),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _card(BuildContext context) {
    final inCloud = book.driveFileId != null;
    final count = book.pageCount;
    final size = book.sizeBytes;
    final info = [
      if (count != null) 'Page ${book.lastPage} of $count',
      if (book.isStarted) percentRead(book),
      if (size != null) '${formatSize(size)} ${book.isLocal ? 'on this tablet' : 'in Drive'}',
    ].join(' · ');
    final openLabel = !book.isLocal
        ? 'Download and read'
        : (book.isStarted ? 'Continue on page ${book.lastPage}' : (book.isFinished ? 'Read again' : 'Start reading'));
    return Material(
      color: TabletColors.card,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(30),
        side: const BorderSide(color: Color(0x17FFFFFF)),
      ),
      elevation: 24,
      shadowColor: Colors.black,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 26, 18, 14),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    book.title,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontFamily: serifFamily,
                      fontSize: 26,
                      fontWeight: FontWeight.w600,
                      height: 1.15,
                    ),
                  ),
                  if (info.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    Text(info, style: const TextStyle(fontSize: 15, color: TabletColors.dim)),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 18),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: TealButton(
                label: openLabel,
                icon: book.isLocal ? Icons.play_arrow_rounded : Icons.cloud_download_outlined,
                height: 56,
                fontSize: 17,
                glow: false,
                expand: true,
                onPressed: () => Navigator.pop(context, 'open'),
              ),
            ),
            const SizedBox(height: 18),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const TabletLabel('On shelves'),
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final shelf in store.shelves)
                        _ShelfToggle(
                          shelf: shelf,
                          on: shelf.bookIds.contains(book.id),
                          onTap: () => onToggleShelf(shelf, !shelf.bookIds.contains(book.id)),
                        ),
                      DashedBorder(
                        radius: 21,
                        child: Material(
                          type: MaterialType.transparency,
                          child: InkWell(
                            customBorder: const StadiumBorder(),
                            onTap: () => Navigator.pop(context, 'new-shelf'),
                            child: const SizedBox(
                              height: 42,
                              child: Padding(
                                padding: EdgeInsets.symmetric(horizontal: 14),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(Icons.add_rounded, size: 18, color: TabletColors.muted),
                                    SizedBox(width: 6),
                                    Text(
                                      'Create shelf',
                                      style: TextStyle(
                                        fontSize: 15,
                                        fontWeight: FontWeight.w600,
                                        color: TabletColors.muted,
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
                ],
              ),
            ),
            const Padding(
              padding: EdgeInsets.fromLTRB(8, 20, 8, 4),
              child: Divider(height: 1, color: TabletColors.line),
            ),
            _ActionRow(icon: Icons.edit_outlined, label: 'Rename', onTap: () => Navigator.pop(context, 'rename')),
            if (inCloud && book.isLocal)
              _ActionRow(
                icon: Icons.mobile_off_outlined,
                label: 'Remove from this tablet',
                note: 'Stays in your Drive and on your PC',
                onTap: () => Navigator.pop(context, 'remove-local'),
              ),
            _ActionRow(
              icon: Icons.library_add_check_outlined,
              label: 'Select more books',
              onTap: () => Navigator.pop(context, 'select'),
            ),
            _ActionRow(
              icon: Icons.delete_outline_rounded,
              label: inCloud ? 'Delete everywhere' : 'Remove from library',
              note: inCloud ? 'From your Drive and all your devices' : null,
              danger: true,
              onTap: () => Navigator.pop(context, 'delete'),
            ),
          ],
        ),
      ),
    );
  }
}

class _ShelfToggle extends StatelessWidget {
  const _ShelfToggle({required this.shelf, required this.on, required this.onTap});

  final Shelf shelf;
  final bool on;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = Color(shelfColors[shelf.color % shelfColors.length]);
    return Semantics(
      toggled: on,
      child: Material(
        color: on ? color.withValues(alpha: 0.15) : Colors.transparent,
        shape: StadiumBorder(
          side: on ? BorderSide(color: color, width: 1.5) : const BorderSide(color: Color(0x29FFFFFF)),
        ),
        child: InkWell(
          customBorder: const StadiumBorder(),
          onTap: onTap,
          child: Container(
            height: 42,
            padding: const EdgeInsets.only(left: 12, right: 16),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                on
                    ? Icon(Icons.check_rounded, size: 17, color: color)
                    : Container(
                        width: 10,
                        height: 10,
                        decoration: BoxDecoration(color: color, shape: BoxShape.circle),
                      ),
                const SizedBox(width: 8),
                Text(
                  shelf.name,
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: on ? FontWeight.w700 : FontWeight.w600,
                    color: on ? Colors.white : TabletColors.soft,
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

class _ActionRow extends StatelessWidget {
  const _ActionRow({required this.icon, required this.label, required this.onTap, this.note, this.danger = false});

  final IconData icon;
  final String label;
  final String? note;
  final bool danger;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = danger ? TabletColors.danger : TabletColors.text;
    return InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: onTap,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 60),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          child: Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(color: const Color(0x0FFFFFFF), borderRadius: BorderRadius.circular(12)),
                child: Icon(icon, size: 20, color: color),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      label,
                      style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600, color: color),
                    ),
                    if (note != null) Text(note!, style: const TextStyle(fontSize: 13, color: TabletColors.dim)),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// "Add N books to a shelf": the shelves, or a new one made right here.
/// Pops (shelf, null, 0) for an existing shelf or (null, name, colour) for a
/// new one.
class _AddToShelfSheet extends StatefulWidget {
  const _AddToShelfSheet({
    required this.books,
    required this.shelves,
    required this.coverFor,
    required this.shelfBooks,
    required this.nextColor,
  });

  final List<Book> books;
  final List<Shelf> shelves;
  final Future<File?> Function(Book) coverFor;
  final List<Book> Function(Shelf) shelfBooks;
  final int nextColor;

  @override
  State<_AddToShelfSheet> createState() => _AddToShelfSheetState();
}

class _AddToShelfSheetState extends State<_AddToShelfSheet> {
  final _name = TextEditingController();
  late var _color = widget.nextColor % shelfColors.length;

  @override
  void initState() {
    super.initState();
    _name.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final books = widget.books;
    final n = books.length;
    final noun = n == 1 ? 'book' : '$n books';
    final colour = Color(shelfColors[_color]);
    final canCreate = _name.text.trim().isNotEmpty;
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(32, 14, 32, 32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SheetHandle(),
              const SizedBox(height: 18),
              Row(
                children: [
                  CoverFan(
                    books: books.take(3).toList(),
                    coverFor: widget.coverFor,
                    coverSize: const Size(32, 46),
                    spread: 18,
                    angles: const [-0.17, 0, 0.17],
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Add ${n == 1 ? 'this book' : '$n books'} to a shelf',
                          style: const TextStyle(fontFamily: serifFamily, fontSize: 28, fontWeight: FontWeight.w600),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          books.map((b) => b.title).join(', '),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 15, color: TabletColors.dim),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 18),
              for (final shelf in widget.shelves) ...[_shelfRow(shelf, n), const SizedBox(height: 12)],
              const SizedBox(height: 6),
              Container(
                padding: const EdgeInsets.all(18),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(20),
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [colour.withValues(alpha: 0.12), const Color(0x08FFFFFF)],
                  ),
                  border: Border.all(color: colour.withValues(alpha: 0.45), width: 1.5),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    TabletLabel('Create shelf', color: Color.lerp(colour, Colors.white, 0.45)!),
                    const SizedBox(height: 16),
                    TextField(
                      controller: _name,
                      textCapitalization: TextCapitalization.sentences,
                      cursorColor: colour,
                      style: const TextStyle(fontSize: 19),
                      onSubmitted: (_) => canCreate ? _create() : null,
                      decoration: InputDecoration(
                        hintText: 'Name it, like "Exam prep"',
                        hintStyle: const TextStyle(color: TabletColors.faint),
                        filled: true,
                        fillColor: const Color(0x59000000),
                        contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(16),
                          borderSide: const BorderSide(color: Color(0x24FFFFFF), width: 1.5),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(16),
                          borderSide: BorderSide(color: colour, width: 1.5),
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    Row(
                      children: [
                        Expanded(
                          child: Wrap(
                            spacing: 12,
                            runSpacing: 10,
                            children: [
                              for (var i = 0; i < shelfColors.length; i++)
                                Semantics(
                                  selected: i == _color,
                                  button: true,
                                  child: GestureDetector(
                                    onTap: () => setState(() => _color = i),
                                    child: Container(
                                      width: 34,
                                      height: 34,
                                      decoration: BoxDecoration(
                                        color: Color(shelfColors[i]),
                                        shape: BoxShape.circle,
                                        border: i == _color ? Border.all(color: TabletColors.sheet, width: 3) : null,
                                        boxShadow: [
                                          if (i == _color) BoxShadow(color: Color(shelfColors[i]), spreadRadius: 2),
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 12),
                        Opacity(
                          opacity: canCreate ? 1 : 0.45,
                          child: Material(
                            color: colour,
                            shape: const StadiumBorder(),
                            child: InkWell(
                              customBorder: const StadiumBorder(),
                              onTap: canCreate ? _create : null,
                              child: Container(
                                height: 50,
                                padding: const EdgeInsets.symmetric(horizontal: 22),
                                alignment: Alignment.center,
                                child: Text(
                                  n == 1 ? 'Create & add' : 'Create & add $n',
                                  style: TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.w700,
                                    color: colour.computeLuminance() > 0.4 ? const Color(0xFF2A2205) : Colors.white,
                                  ),
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
              if (widget.shelves.isEmpty) ...[
                const SizedBox(height: 12),
                Text(
                  'No shelves yet. Shelves group your $noun, like "Textbooks" or "Novels".',
                  style: const TextStyle(fontSize: 14, color: TabletColors.dim),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  void _create() => Navigator.pop(context, (null, _name.text.trim(), _color));

  Widget _shelfRow(Shelf shelf, int n) {
    final color = Color(shelfColors[shelf.color % shelfColors.length]);
    final already = widget.books.where((b) => shelf.bookIds.contains(b.id)).toList();
    final toAdd = n - already.length;
    final count = widget.shelfBooks(shelf).length;
    final note = already.isEmpty
        ? null
        : (already.length == 1 ? '${already.single.title} is already here' : '${already.length} are already here');
    return Material(
      color: const Color(0x0AFFFFFF),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: const BorderSide(color: TabletColors.line),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: toAdd == 0 ? null : () => Navigator.pop(context, (shelf, null, 0)),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
          child: Row(
            children: [
              CoverFan(
                books: widget.shelfBooks(shelf).take(3).toList(),
                coverFor: widget.coverFor,
                coverSize: const Size(32, 46),
                spread: 15,
                colors: [color.withValues(alpha: 0.5), color.withValues(alpha: 0.7), color],
              ),
              const SizedBox(width: 18),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Container(
                          width: 10,
                          height: 10,
                          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
                        ),
                        const SizedBox(width: 10),
                        Flexible(
                          child: Text(
                            shelf.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 3),
                    Text(
                      '$count book${count == 1 ? '' : 's'}',
                      style: const TextStyle(fontSize: 14, color: TabletColors.dim),
                    ),
                    if (note != null)
                      Text(
                        note,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 13, color: TabletColors.dim),
                      ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Container(
                height: 44,
                padding: const EdgeInsets.symmetric(horizontal: 18),
                alignment: Alignment.center,
                decoration: BoxDecoration(color: const Color(0x14FFFFFF), borderRadius: BorderRadius.circular(22)),
                child: Text(
                  toAdd == 0 ? 'Already here' : (n == 1 ? 'Add' : 'Add $toAdd'),
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    color: toAdd == 0 ? TabletColors.dim : TabletColors.text,
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

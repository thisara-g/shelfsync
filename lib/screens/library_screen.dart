import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../models/book.dart';
import '../services/cover_renderer.dart';
import '../services/library_store.dart';
import 'reader_screen.dart';

class LibraryScreen extends StatefulWidget {
  const LibraryScreen({super.key, required this.store});

  final LibraryStore store;

  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen> {
  late final _covers = CoverRenderer(widget.store);

  LibraryStore get store => widget.store;

  Future<void> _addBooks() async {
    final files = await FilePicker.pickFiles(
      dialogTitle: 'Add PDFs to ShelfSync',
      type: FileType.custom,
      allowedExtensions: ['pdf'],
    );
    var added = 0, duplicates = 0;
    for (final file in files) {
      final path = file.path;
      if (path == null) continue;
      final result = await store.importFile(path);
      if (result == ImportResult.added) {
        added++;
      } else {
        duplicates++;
      }
    }
    if (!mounted || files.isEmpty) return;
    final parts = [
      if (added > 0) 'Added $added book${added == 1 ? '' : 's'}',
      if (duplicates > 0) '$duplicates already in library',
    ];
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(parts.join(' · '))));
  }

  Future<void> _showBookMenu(Book book, Offset position) async {
    final action = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(position.dx, position.dy, position.dx, position.dy),
      items: const [
        PopupMenuItem(value: 'open', child: ListTile(leading: Icon(Icons.menu_book_outlined), title: Text('Open'))),
        PopupMenuItem(value: 'remove', child: ListTile(leading: Icon(Icons.delete_outline), title: Text('Remove'))),
      ],
    );
    if (!mounted) return;
    switch (action) {
      case 'open':
        _open(book);
      case 'remove':
        await _confirmRemove(book);
    }
  }

  Future<void> _confirmRemove(Book book) async {
    final remove = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Remove book?'),
        content: Text('"${book.title}" will be removed from this device.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Remove')),
        ],
      ),
    );
    if (remove == true) await store.remove(book.id);
  }

  void _open(Book book) {
    store.markOpened(book.id);
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => ReaderScreen(store: store, book: book)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _addBooks,
        icon: const Icon(Icons.add),
        label: const Text('Add PDF'),
      ),
      body: ListenableBuilder(
        listenable: store,
        builder: (context, _) {
          final books = store.books;
          return CustomScrollView(
            slivers: [
              const SliverAppBar.medium(title: Text('Library')),
              if (books.isEmpty)
                const SliverFillRemaining(hasScrollBody: false, child: _EmptyLibrary())
              else
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(20, 8, 20, 112),
                  sliver: SliverGrid.builder(
                    gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                      maxCrossAxisExtent: 190,
                      mainAxisSpacing: 28,
                      crossAxisSpacing: 20,
                      childAspectRatio: 0.56,
                    ),
                    itemCount: books.length,
                    itemBuilder: (context, i) {
                      final book = books[i];
                      return _BookCard(
                        book: book,
                        cover: _covers.coverFor(book),
                        onTap: () => _open(book),
                        onMenu: (position) => _showBookMenu(book, position),
                      );
                    },
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

class _EmptyLibrary extends StatelessWidget {
  const _EmptyLibrary();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.auto_stories_outlined, size: 72, color: theme.colorScheme.primary),
          const SizedBox(height: 16),
          Text('Your library is empty', style: theme.textTheme.titleLarge),
          const SizedBox(height: 8),
          Text(
            'Tap "Add PDF" to import a book.',
            style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

class _BookCard extends StatelessWidget {
  const _BookCard({required this.book, required this.cover, required this.onTap, required this.onMenu});

  final Book book;
  final Future<File?> cover;
  final VoidCallback onTap;
  final ValueChanged<Offset> onMenu;

  String get _status {
    final count = book.pageCount;
    if (book.lastOpenedAt == null) return count == null ? 'New' : 'New · $count pages';
    if (count == null) return 'Page ${book.lastPage}';
    if (book.lastPage >= count) return 'Finished';
    return 'Page ${book.lastPage} of $count';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final started = book.lastOpenedAt != null && book.pageCount != null;
    return GestureDetector(
      onLongPressStart: (d) => onMenu(d.globalPosition),
      onSecondaryTapUp: (d) => onMenu(d.globalPosition),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Material(
                elevation: 3,
                shadowColor: Colors.black54,
                borderRadius: BorderRadius.circular(8),
                clipBehavior: Clip.antiAlias,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    _CoverImage(book: book, cover: cover),
                    if (started)
                      Align(
                        alignment: Alignment.bottomCenter,
                        child: LinearProgressIndicator(
                          value: book.progress,
                          minHeight: 4,
                          backgroundColor: Colors.black26,
                        ),
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 10),
            Text(
              book.title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.titleSmall?.copyWith(height: 1.25),
            ),
            const SizedBox(height: 2),
            Text(
              _status,
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

class _CoverImage extends StatelessWidget {
  const _CoverImage({required this.book, required this.cover});

  final Book book;
  final Future<File?> cover;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<File?>(
      future: cover,
      builder: (context, snapshot) {
        final file = snapshot.data;
        if (file == null) return _PlaceholderCover(title: book.title);
        return Image.file(
          file,
          fit: BoxFit.cover,
          alignment: Alignment.topCenter,
          errorBuilder: (_, _, _) => _PlaceholderCover(title: book.title),
        );
      },
    );
  }
}

/// Shown while the cover renders, or if the PDF can't be rendered.
class _PlaceholderCover extends StatelessWidget {
  const _PlaceholderCover({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    final hue = (title.hashCode % 360).abs().toDouble();
    final top = HSLColor.fromAHSL(1, hue, 0.35, 0.42).toColor();
    final bottom = HSLColor.fromAHSL(1, (hue + 30) % 360, 0.40, 0.28).toColor();
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [top, bottom]),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Center(
          child: Text(
            title,
            textAlign: TextAlign.center,
            maxLines: 6,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w600, height: 1.3),
          ),
        ),
      ),
    );
  }
}

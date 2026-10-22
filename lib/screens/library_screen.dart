import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../models/book.dart';
import '../services/cover_renderer.dart';
import '../services/library_store.dart';
import '../sync/library_sync.dart';
import '../sync/sync_controller.dart';
import 'reader_screen.dart';
import 'sync_button.dart';

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

  LibraryStore get store => widget.store;
  LibrarySync get librarySync => widget.librarySync;

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
    if (files.isEmpty) return;
    final parts = [
      if (added > 0) 'Added $added book${added == 1 ? '' : 's'}',
      if (duplicates > 0) '$duplicates already in library',
    ];
    _snack(parts.join(' · '));
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
        listenable: Listenable.merge([store, librarySync]),
        builder: (context, _) {
          final books = store.books;
          return RefreshIndicator(
            onRefresh: librarySync.syncNow,
            notificationPredicate: (n) => n.depth == 0 && widget.sync.status == SyncStatus.connected,
            child: CustomScrollView(
              physics: const AlwaysScrollableScrollPhysics(),
              slivers: [
                SliverAppBar.medium(
                  title: const Text('Library'),
                  actions: [SyncButton(sync: widget.sync, librarySync: librarySync)],
                ),
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
                          transfer: librarySync.transferFor(book.id),
                          onTap: () => _open(book),
                          onMenu: (position) => _showBookMenu(book, position),
                        );
                      },
                    ),
                  ),
              ],
            ),
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

String _formatSize(int bytes) {
  if (bytes >= 1 << 30) return '${(bytes / (1 << 30)).toStringAsFixed(1)} GB';
  if (bytes >= 1 << 20) return '${(bytes / (1 << 20)).toStringAsFixed(1)} MB';
  return '${(bytes / 1024).ceil()} KB';
}

class _BookCard extends StatelessWidget {
  const _BookCard({
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

  String get _status {
    final t = transfer;
    if (t != null) {
      final verb = t.kind == TransferKind.upload ? 'Uploading' : 'Downloading';
      final p = t.progress;
      return p == null ? '$verb…' : '$verb ${(p * 100).round()}%';
    }
    final count = book.pageCount;
    if (!book.isLocal) {
      final size = book.sizeBytes;
      return size == null ? 'In Google Drive' : 'In Google Drive · ${_formatSize(size)}';
    }
    if (book.lastOpenedAt == null) return count == null ? 'New' : 'New · $count pages';
    if (count == null) return 'Page ${book.lastPage}';
    if (book.lastPage >= count) return 'Finished';
    return 'Page ${book.lastPage} of $count';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final started = book.lastOpenedAt != null && book.pageCount != null;
    final t = transfer;
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
                    Opacity(
                      opacity: book.isLocal ? 1 : 0.55,
                      child: _CoverImage(book: book, cover: cover),
                    ),
                    if (!book.isLocal && t == null)
                      const Align(alignment: Alignment.topRight, child: _CloudBadge()),
                    if (t != null)
                      ColoredBox(
                        color: Colors.black38,
                        child: Center(
                          child: SizedBox.square(
                            dimension: 44,
                            child: CircularProgressIndicator(
                              value: t.progress,
                              strokeWidth: 4,
                              color: Colors.white,
                              backgroundColor: Colors.white24,
                            ),
                          ),
                        ),
                      ),
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

class _CloudBadge extends StatelessWidget {
  const _CloudBadge();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.all(8),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: scheme.surface.withValues(alpha: 0.9),
          shape: BoxShape.circle,
          boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 4)],
        ),
        child: Padding(
          padding: const EdgeInsets.all(6),
          child: Icon(Icons.cloud_download_outlined, size: 18, color: scheme.primary),
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

import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:ui' show Offset;

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../models/book.dart';

/// Result of importing a file into the library.
enum ImportResult { added, duplicate }

/// Persists the library as `library.json` plus one `books/<id>.pdf` per book
/// under [rootDir].
class LibraryStore extends ChangeNotifier {
  LibraryStore(this.rootDir);

  final Directory rootDir;
  final Map<String, Book> _books = {};
  bool _darkReader = false;
  String? _syncAccount;

  /// Whether the reader shows pages in dark mode (applies to all books).
  bool get darkReader => _darkReader;

  File get _indexFile => File(p.join(rootDir.path, 'library.json'));
  Directory get _booksDir => Directory(p.join(rootDir.path, 'books'));

  /// Books ordered by most recently opened, then most recently added.
  List<Book> get books {
    final list = _books.values.toList();
    list.sort((a, b) {
      final aTime = a.lastOpenedAt ?? a.addedAt;
      final bTime = b.lastOpenedAt ?? b.addedAt;
      return bTime.compareTo(aTime);
    });
    return list;
  }

  Book? byId(String id) => _books[id];

  File fileFor(Book book) => File(p.join(_booksDir.path, '${book.id}.pdf'));

  /// Cached first-page thumbnail; may not exist yet (see CoverRenderer).
  File coverFor(Book book) => File(p.join(rootDir.path, 'covers', '${book.id}.png'));

  Future<void> load() async {
    await _booksDir.create(recursive: true);
    _books.clear();
    if (await _indexFile.exists()) {
      final json = jsonDecode(await _indexFile.readAsString()) as Map<String, dynamic>;
      final settings = json['settings'] as Map<String, dynamic>? ?? const {};
      _darkReader = settings['darkReader'] as bool? ?? false;
      _syncAccount = settings['syncAccount'] as String?;
      for (final entry in json['books'] as List<dynamic>) {
        final book = Book.fromJson(entry as Map<String, dynamic>);
        book.isLocal = await fileFor(book).exists();
        // Keep cloud-only entries; drop local ones whose file has vanished.
        if (book.isLocal || book.driveFileId != null) _books[book.id] = book;
      }
    }
    notifyListeners();
  }

  Future<void> _save() async {
    final tmp = File('${_indexFile.path}.tmp');
    final json = {
      'version': 1,
      'settings': {'darkReader': _darkReader, 'syncAccount': _syncAccount},
      'books': _books.values.map((b) => b.toJson()).toList(),
    };
    await tmp.writeAsString(const JsonEncoder.withIndent('  ').convert(json), flush: true);
    await tmp.rename(_indexFile.path);
  }

  /// Copies the file at [path] into the library, keyed by its content hash.
  ///
  /// Importing a file that's already in the library only as a cloud entry
  /// counts as downloading it.
  Future<ImportResult> importFile(String path) async {
    final id = await hashFile(path);
    final existing = _books[id];
    if (existing != null && existing.isLocal) return ImportResult.duplicate;

    final fileName = p.basename(path);
    final book = existing ??
        Book(
          id: id,
          title: p.basenameWithoutExtension(fileName),
          fileName: fileName,
          addedAt: DateTime.now(),
        );
    await File(path).copy(fileFor(book).path);
    book
      ..isLocal = true
      ..sizeBytes = await File(path).length();
    _books[id] = book;
    await _save();
    notifyListeners();
    return ImportResult.added;
  }

  /// Adds a book that exists in Drive but not on this device.
  Future<void> addRemote({
    required String id,
    required String title,
    required String driveFileId,
    required DateTime addedAt,
    int? sizeBytes,
  }) async {
    if (_books.containsKey(id)) return;
    _books[id] = Book(
      id: id,
      title: title,
      fileName: '$title.pdf',
      addedAt: addedAt,
      driveFileId: driveFileId,
      sizeBytes: sizeBytes,
      isLocal: false,
    );
    await _save();
    notifyListeners();
  }

  Future<void> setDriveFileId(String id, String? driveFileId) async {
    final book = _books[id];
    if (book == null || book.driveFileId == driveFileId) return;
    book.driveFileId = driveFileId;
    await _save();
    notifyListeners();
  }

  /// Moves a fully downloaded and verified temp file into place.
  Future<void> adoptDownload(String id, File downloaded) async {
    final book = _books[id];
    if (book == null) return;
    await downloaded.rename(fileFor(book).path);
    book.isLocal = true;
    await _save();
    notifyListeners();
  }

  /// Deletes the downloaded PDF but keeps the book (and its progress) as a
  /// cloud entry. Only valid for books that are in Drive.
  Future<void> removeLocalCopy(String id) async {
    final book = _books[id];
    if (book == null || book.driveFileId == null) return;
    final file = fileFor(book);
    if (await file.exists()) await file.delete();
    book.isLocal = false;
    await _save();
    notifyListeners();
  }

  Future<void> saveCover(Book book, List<int> png) async {
    final file = coverFor(book);
    await file.parent.create(recursive: true);
    await file.writeAsBytes(png, flush: true);
    notifyListeners();
  }

  /// Where in-progress downloads are written before verification.
  File downloadTempFor(Book book) => File('${fileFor(book).path}.part');

  /// Records which Google account the books' Drive ids belong to. When a
  /// different account signs in, those ids are meaningless: downloaded books
  /// are unlinked (and will upload to the new account) and cloud-only entries
  /// are dropped. Nothing on disk is deleted.
  Future<void> bindSyncAccount(String email) async {
    if (_syncAccount == email) return;
    if (_syncAccount != null) {
      _books.removeWhere((_, book) => !book.isLocal);
      for (final book in _books.values) {
        book.driveFileId = null;
      }
    }
    _syncAccount = email;
    await _save();
    notifyListeners();
  }

  Future<void> setDarkReader(bool value) async {
    if (_darkReader == value) return;
    _darkReader = value;
    await _save();
    notifyListeners();
  }

  Future<void> markOpened(String id) async {
    final book = _books[id];
    if (book == null) return;
    book.lastOpenedAt = DateTime.now();
    await _save();
    notifyListeners();
  }

  Future<void> updateProgress(
    String id, {
    required int page,
    int? pageCount,
    Offset? pageOffset,
    double? zoom,
  }) async {
    final book = _books[id];
    if (book == null) return;
    final unchanged = book.lastPage == page &&
        (pageCount == null || book.pageCount == pageCount) &&
        (pageOffset == null || (book.pageOffsetX == pageOffset.dx && book.pageOffsetY == pageOffset.dy)) &&
        (zoom == null || book.zoom == zoom);
    if (unchanged) return;
    book.lastPage = page;
    if (pageCount != null) book.pageCount = pageCount;
    if (pageOffset != null) {
      book.pageOffsetX = pageOffset.dx;
      book.pageOffsetY = pageOffset.dy;
    }
    if (zoom != null) book.zoom = zoom;
    await _save();
    notifyListeners();
  }

  Future<void> remove(String id) async {
    final book = _books.remove(id);
    if (book == null) return;
    for (final file in [fileFor(book), coverFor(book)]) {
      if (await file.exists()) await file.delete();
    }
    await _save();
    notifyListeners();
  }

  /// SHA-256 of the file contents as lowercase hex, computed off the UI isolate.
  static Future<String> hashFile(String path) => Isolate.run(() async {
        final digest = await sha256.bind(File(path).openRead()).first;
        return digest.toString();
      });
}

import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:ui' show Offset;

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../models/book.dart';
import '../models/shelf.dart';

/// Result of importing a file into the library.
enum ImportResult { added, duplicate }

/// How the reader colours pages.
enum ReaderTheme { light, sepia, dark }

/// Persists the library as `library.json` plus one `books/<id>.pdf` per book
/// under [rootDir].
class LibraryStore extends ChangeNotifier {
  LibraryStore(this.rootDir);

  final Directory rootDir;
  final Map<String, Book> _books = {};
  final List<Shelf> _shelves = [];
  DateTime? _shelvesUpdatedAt;
  bool _shelvesDirty = false;
  ReaderTheme _readerTheme = ReaderTheme.light;
  bool _autoJump = false;
  bool _welcomeDone = false;
  bool _twoPageSpread = false;
  String? _syncAccount;
  String _deviceId = '';
  String _deviceName = '';

  /// Random id identifying this installation in synced progress records.
  String get deviceId => _deviceId;

  /// Human-readable name shown on other devices ("from ubuntu-pc").
  String get deviceName => _deviceName;

  /// Page colours in the reader (applies to all books).
  ReaderTheme get readerTheme => _readerTheme;

  /// Move to a newer position from another device without asking.
  bool get autoJump => _autoJump;

  /// Whether the first-run welcome screen has been dismissed.
  bool get welcomeDone => _welcomeDone;

  /// Desktop reader shows facing pages side by side.
  bool get twoPageSpread => _twoPageSpread;

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

  /// Shelves in the order they were created.
  List<Shelf> get shelves => List.unmodifiable(_shelves);

  Shelf? shelfById(String id) {
    for (final s in _shelves) {
      if (s.id == id) return s;
    }
    return null;
  }

  /// Changed here since the last upload.
  bool get shelvesDirty => _shelvesDirty;

  ShelvesDocument get shelvesDocument =>
      ShelvesDocument(shelves: _shelves, updated: _shelvesUpdatedAt ?? DateTime.fromMillisecondsSinceEpoch(0));

  File fileFor(Book book) => File(p.join(_booksDir.path, '${book.id}.pdf'));

  /// Cached first-page thumbnail; may not exist yet (see CoverRenderer).
  File coverFor(Book book) => File(p.join(rootDir.path, 'covers', '${book.id}.png'));

  Future<void> load() async {
    await _booksDir.create(recursive: true);
    _books.clear();
    if (await _indexFile.exists()) {
      final json = jsonDecode(await _indexFile.readAsString()) as Map<String, dynamic>;
      final settings = json['settings'] as Map<String, dynamic>? ?? const {};
      _readerTheme = ReaderTheme.values.asNameMap()[settings['readerTheme']] ??
          (settings['darkReader'] == true ? ReaderTheme.dark : ReaderTheme.light);
      _autoJump = settings['autoJump'] as bool? ?? false;
      _twoPageSpread = settings['twoPageSpread'] as bool? ?? false;
      // Existing users (from 0.1) already know the app: skip the welcome.
      _welcomeDone = settings['welcomeDone'] as bool? ?? true;
      _syncAccount = settings['syncAccount'] as String?;
      _deviceId = settings['deviceId'] as String? ?? '';
      _deviceName = settings['deviceName'] as String? ?? '';
      final shelves = json['shelves'] as Map<String, dynamic>?;
      _shelves.clear();
      if (shelves != null) {
        final doc = ShelvesDocument.fromJson(shelves);
        _shelves.addAll(doc.shelves);
        _shelvesUpdatedAt = doc.updated.millisecondsSinceEpoch == 0 ? null : doc.updated;
        _shelvesDirty = shelves['dirty'] as bool? ?? false;
      }
      for (final entry in json['books'] as List<dynamic>) {
        final book = Book.fromJson(entry as Map<String, dynamic>);
        book.isLocal = await fileFor(book).exists();
        // Keep cloud-only entries; drop local ones whose file has vanished.
        if (book.isLocal || book.driveFileId != null) _books[book.id] = book;
      }
    }
    var changed = false;
    if (!await _indexFile.exists()) {
      _welcomeDone = false;
      changed = true;
    }
    if (_deviceId.isEmpty) {
      final random = Random.secure();
      _deviceId = List.generate(16, (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
      changed = true;
    }
    if (_deviceName.isEmpty) {
      _deviceName = _defaultDeviceName();
      changed = true;
    }
    if (changed) await _save();
    notifyListeners();
  }

  static String _defaultDeviceName() {
    if (Platform.isAndroid) return 'Android tablet';
    final host = Platform.localHostname;
    return host.isEmpty || host == 'localhost' ? Platform.operatingSystem : host;
  }

  Future<void> _save() async {
    final tmp = File('${_indexFile.path}.tmp');
    final json = {
      'version': 1,
      'settings': {
        'readerTheme': _readerTheme.name,
        'autoJump': _autoJump,
        'welcomeDone': _welcomeDone,
        'twoPageSpread': _twoPageSpread,
        'syncAccount': _syncAccount,
        'deviceId': _deviceId,
        'deviceName': _deviceName,
      },
      'books': _books.values.map((b) => b.toJson()).toList(),
      'shelves': {...shelvesDocument.toJson(), 'dirty': _shelvesDirty},
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
          title: titleFromFileName(fileName),
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

  /// Renames a book. [fromDrive] marks a title adopted from Drive, which needs
  /// no upload; a rename here is pushed to Drive by the next sync.
  Future<void> rename(String id, String title, {bool fromDrive = false}) async {
    final book = _books[id];
    final clean = title.trim();
    if (book == null || clean.isEmpty) return;
    if (book.title == clean && (fromDrive || !book.titleDirty)) {
      if (fromDrive && book.titleDirty) book.titleDirty = false;
      return;
    }
    book
      ..title = clean
      ..titleDirty = !fromDrive && book.driveFileId != null;
    await _save();
    notifyListeners();
  }

  /// Drive now has the book's current title.
  Future<void> markTitleSynced(String id) async {
    final book = _books[id];
    if (book == null || !book.titleDirty) return;
    book.titleDirty = false;
    await _save();
    notifyListeners();
  }

  /// "c-programming_2nd-ed.pdf" → "C programming 2nd ed". Names that already
  /// contain spaces are kept as they are.
  static String titleFromFileName(String fileName) {
    var title = p.basenameWithoutExtension(fileName).trim();
    if (!title.contains(' ') && RegExp(r'[-_.]').hasMatch(title)) {
      title = title.replaceAll(RegExp(r'[-_.]+'), ' ').trim();
    }
    if (title.isEmpty) return 'Untitled';
    return title[0].toUpperCase() + title.substring(1);
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

  Future<void> _shelvesChanged() async {
    _shelvesUpdatedAt = DateTime.now();
    _shelvesDirty = true;
    await _save();
    notifyListeners();
  }

  Future<Shelf> createShelf(String name) async {
    final random = Random.secure();
    final shelf = Shelf(
      id: List.generate(8, (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0')).join(),
      name: name.trim(),
      color: _shelves.length % shelfColors.length,
    );
    _shelves.add(shelf);
    await _shelvesChanged();
    return shelf;
  }

  Future<void> renameShelf(String id, String name) async {
    final shelf = shelfById(id);
    if (shelf == null || name.trim().isEmpty || shelf.name == name.trim()) return;
    shelf.name = name.trim();
    await _shelvesChanged();
  }

  /// Deletes the shelf; its books stay in the library.
  Future<void> deleteShelf(String id) async {
    _shelves.removeWhere((s) => s.id == id);
    await _shelvesChanged();
  }

  Future<void> setOnShelf(String shelfId, String bookId, bool on) async {
    final shelf = shelfById(shelfId);
    if (shelf == null) return;
    final changed = on ? shelf.bookIds.add(bookId) : shelf.bookIds.remove(bookId);
    if (changed) await _shelvesChanged();
  }

  /// Adopts shelves synced from another device.
  Future<void> applyRemoteShelves(ShelvesDocument doc) async {
    _shelves
      ..clear()
      ..addAll(doc.shelves);
    _shelvesUpdatedAt = doc.updated;
    _shelvesDirty = false;
    await _save();
    notifyListeners();
  }

  Future<void> markShelvesSynced() async {
    if (!_shelvesDirty) return;
    _shelvesDirty = false;
    await _save();
  }

  Future<void> setReaderTheme(ReaderTheme value) async {
    if (_readerTheme == value) return;
    _readerTheme = value;
    await _save();
    notifyListeners();
  }

  Future<void> setAutoJump(bool value) async {
    if (_autoJump == value) return;
    _autoJump = value;
    await _save();
    notifyListeners();
  }

  Future<void> setWelcomeDone() async {
    if (_welcomeDone) return;
    _welcomeDone = true;
    await _save();
    notifyListeners();
  }

  Future<void> setTwoPageSpread(bool value) async {
    if (_twoPageSpread == value) return;
    _twoPageSpread = value;
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
    String? chapter,
  }) async {
    final book = _books[id];
    if (book == null) return;
    final unchanged = book.lastPage == page &&
        (chapter == null || book.chapter == chapter) &&
        (pageCount == null || book.pageCount == pageCount) &&
        (pageOffset == null || (book.pageOffsetX == pageOffset.dx && book.pageOffsetY == pageOffset.dy)) &&
        (zoom == null || book.zoom == zoom);
    if (unchanged) return;
    if (_movedFrom(book, page, pageOffset)) {
      book
        ..progressUpdatedAt = DateTime.now()
        ..progressDevice = null;
    }
    book.lastPage = page;
    if (chapter != null) book.chapter = chapter;
    if (pageCount != null) book.pageCount = pageCount;
    if (pageOffset != null) {
      book.pageOffsetX = pageOffset.dx;
      book.pageOffsetY = pageOffset.dy;
    }
    if (zoom != null) book.zoom = zoom;
    await _save();
    notifyListeners();
  }

  /// Whether the reader genuinely moved. Re-deriving the in-page offset after
  /// opening a book differs by rounding noise, which must not count: a fresh
  /// timestamp would make a stale position beat newer progress from another
  /// device.
  static bool _movedFrom(Book book, int page, Offset? offset) {
    if (book.lastPage != page) return true;
    final x = book.pageOffsetX, y = book.pageOffsetY;
    if (offset == null || x == null || y == null) return false;
    return (offset.dx - x).abs() > 0.02 || (offset.dy - y).abs() > 0.02;
  }

  /// Adopts a reading position synced from another device. Zoom is left as
  /// is: it depends on this device's screen.
  Future<void> applyRemoteProgress(
    String id, {
    required int page,
    required Offset? pageOffset,
    required DateTime updatedAt,
    String? device,
  }) async {
    final book = _books[id];
    if (book == null) return;
    if (book.lastPage != page) book.chapter = null;
    book
      ..progressDevice = device
      ..lastPage = page
      ..pageOffsetX = pageOffset?.dx
      ..pageOffsetY = pageOffset?.dy
      ..progressUpdatedAt = updatedAt;
    await _save();
    notifyListeners();
  }

  /// Marks the local position as the newest, e.g. when the user declines to
  /// jump to another device's position, so this one wins and gets pushed.
  Future<void> touchProgress(String id) async {
    final book = _books[id];
    if (book == null) return;
    book
      ..progressUpdatedAt = DateTime.now()
      ..progressDevice = null;
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

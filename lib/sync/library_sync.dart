import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/book.dart';
import '../services/library_store.dart';
import 'drive_service.dart';
import 'sync_controller.dart';

enum TransferKind { upload, download }

class Transfer {
  Transfer(this.kind);

  final TransferKind kind;

  /// 0..1, or null before the first bytes move.
  double? progress;
}

/// Keeps the local library and the ShelfSync Drive folder in step.
///
/// The library on each device is the union of local and Drive books:
/// - local books not yet in Drive are uploaded;
/// - Drive books not on this device appear as cloud entries, downloaded on
///   demand;
/// - a book trashed in Drive (e.g. "Delete everywhere" on the other device)
///   is removed here too.
class LibrarySync extends ChangeNotifier {
  LibrarySync({required this.store, required this.sync});

  final LibraryStore store;
  final SyncController sync;

  final Map<String, Transfer> _transfers = {};
  Timer? _timer;
  bool _running = false;
  bool _again = false;
  String? _lastError;

  static const _interval = Duration(minutes: 5);

  Transfer? transferFor(String bookId) => _transfers[bookId];

  bool get isSyncing => _running;

  /// Message from the last failed sync, cleared by the next good one.
  String? get lastError => _lastError;

  void start() {
    sync.addListener(_onConnectionChanged);
    _timer = Timer.periodic(_interval, (_) => syncNow());
    _onConnectionChanged();
  }

  @override
  void dispose() {
    sync.removeListener(_onConnectionChanged);
    _timer?.cancel();
    super.dispose();
  }

  SyncStatus? _lastStatus;

  void _onConnectionChanged() {
    final status = sync.status;
    if (status == _lastStatus) return;
    _lastStatus = status;
    if (status == SyncStatus.connected) syncNow();
  }

  /// Runs a full sync. Calls made while one is running queue a single re-run.
  Future<void> syncNow() async {
    if (sync.status != SyncStatus.connected) return;
    if (_running) {
      _again = true;
      return;
    }
    _running = true;
    notifyListeners();
    try {
      do {
        _again = false;
        await _syncOnce();
      } while (_again);
      _lastError = null;
    } catch (e) {
      _lastError = '$e';
    } finally {
      _running = false;
      notifyListeners();
    }
  }

  Future<void> _syncOnce() async {
    final drive = sync.drive;
    final folderId = sync.folderId;
    final account = sync.account;
    if (drive == null || folderId == null || account == null) return;
    await store.bindSyncAccount(account.email);

    // Oldest copy of each book wins; later duplicates (the same book uploaded
    // from two devices before either synced) are trashed.
    final remote = <String, RemoteBook>{};
    for (final book in await drive.listBooks(folderId)) {
      if (remote.containsKey(book.bookId)) {
        await drive.trash(book.fileId);
      } else {
        remote[book.bookId] = book;
      }
    }

    for (final book in store.books) {
      final match = remote[book.id];
      if (match != null) {
        await store.setDriveFileId(book.id, match.fileId);
      } else if (book.driveFileId != null &&
          !_transfers.containsKey(book.id) &&
          await drive.isGone(book.driveFileId!)) {
        // Was in Drive, now trashed: deleted everywhere from another device.
        await store.remove(book.id);
      }
    }

    for (final r in remote.values) {
      if (store.byId(r.bookId) != null) continue;
      await store.addRemote(
        id: r.bookId,
        title: r.title,
        driveFileId: r.fileId,
        addedAt: r.createdTime,
        sizeBytes: r.sizeBytes,
      );
      final link = r.thumbnailLink;
      final book = store.byId(r.bookId);
      if (link != null && book != null) {
        final png = await drive.thumbnail(link);
        if (png != null) await store.saveCover(book, png);
      }
    }

    for (final book in store.books.where((b) => b.isLocal && b.driveFileId == null).toList()) {
      await _upload(drive, folderId, book);
    }
  }

  Future<void> _upload(DriveService drive, String folderId, Book book) async {
    final transfer = _transfers[book.id] = Transfer(TransferKind.upload);
    notifyListeners();
    try {
      final fileId = await drive.uploadBook(
        folderId: folderId,
        file: store.fileFor(book),
        bookId: book.id,
        title: book.title,
        onProgress: (p) => _progress(transfer, p),
      );
      await store.setDriveFileId(book.id, fileId);
    } finally {
      _transfers.remove(book.id);
      notifyListeners();
    }
  }

  /// Downloads a cloud-only book and verifies it against its content hash.
  Future<void> download(Book book) async {
    final drive = sync.drive;
    final fileId = book.driveFileId;
    if (book.isLocal || fileId == null || _transfers.containsKey(book.id)) return;
    if (drive == null) throw StateError('Sign in to Google Drive to download this book.');

    final transfer = _transfers[book.id] = Transfer(TransferKind.download);
    notifyListeners();
    final part = store.downloadTempFor(book);
    try {
      await drive.downloadBook(
        fileId: fileId,
        target: part,
        expectedBytes: book.sizeBytes,
        onProgress: (p) => _progress(transfer, p),
      );
      if (await LibraryStore.hashFile(part.path) != book.id) {
        throw StateError('Downloaded file is corrupted. Please try again.');
      }
      await store.adoptDownload(book.id, part);
    } finally {
      if (await part.exists()) await part.delete();
      _transfers.remove(book.id);
      notifyListeners();
    }
  }

  /// Trashes the book in Drive and removes it here. Other devices drop it on
  /// their next sync.
  Future<void> deleteEverywhere(Book book) async {
    final fileId = book.driveFileId;
    if (fileId != null) {
      final drive = sync.drive;
      if (drive == null) throw StateError('Sign in to Google Drive to delete this book everywhere.');
      await drive.trash(fileId);
    }
    await store.remove(book.id);
  }

  DateTime _lastNotify = DateTime.fromMillisecondsSinceEpoch(0);

  void _progress(Transfer transfer, double fraction) {
    transfer.progress = fraction;
    final now = DateTime.now();
    // Progress callbacks fire per chunk; repaint at most ~10x a second.
    if (now.difference(_lastNotify) > const Duration(milliseconds: 100) || fraction >= 1) {
      _lastNotify = now;
      notifyListeners();
    }
  }
}

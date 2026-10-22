import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/book.dart';
import '../services/library_store.dart';
import 'drive_service.dart';
import 'progress_record.dart';
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
///   is removed here too;
/// - reading positions sync through appDataFolder records. The latest wins,
///   but if it would move an already-read book to a different page, the
///   reader asks "Jump to page X (from …)?" instead of moving silently.
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
  static const _pushDelay = Duration(seconds: 5);

  /// Positions from another device waiting for the user to accept or decline.
  final Map<String, ProgressRecord> _pendingJumps = {};
  final Map<String, String> _progressFileIds = {};
  final Set<String> _dirtyProgress = {};
  Timer? _pushTimer;

  ProgressRecord? pendingJumpFor(String bookId) => _pendingJumps[bookId];

  /// The book currently open in the reader. Its position is never changed
  /// behind the reader's back (the reader would just overwrite it); a
  /// different page from another device always becomes a prompt.
  String? openBookId;

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
    _pushTimer?.cancel();
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

    final progress = await drive.listProgress();
    for (final book in store.books) {
      await _reconcile(book, progress[book.id]);
    }
    await _pushDirtyProgress();
  }

  /// Compares a book's local position with the synced one. Newer remote
  /// positions are adopted silently when nothing would be lost, otherwise
  /// queued as a "jump?" prompt; newer local positions are queued for upload.
  Future<void> _reconcile(Book book, StoredProgress? stored) async {
    if (stored != null) _progressFileIds[book.id] = stored.fileId;
    final remote = stored?.record;
    final local = book.progressUpdatedAt;

    if (remote != null && (local == null || remote.updated.isAfter(local))) {
      _dirtyProgress.remove(book.id);
      final samePlace = remote.page == book.lastPage;
      // Nothing read here yet (or not even downloaded): just take it.
      final silent = samePlace || (book.id != openBookId && (local == null || !book.isLocal));
      if (silent) {
        _pendingJumps.remove(book.id);
        await store.applyRemoteProgress(
          book.id,
          page: remote.page,
          pageOffset: remote.pageOffset,
          updatedAt: remote.updated,
        );
      } else {
        _pendingJumps[book.id] = remote;
        notifyListeners();
      }
    } else if (local != null && (remote == null || local.isAfter(remote.updated))) {
      // Read on here since the prompt appeared: this position is newer now.
      if (_pendingJumps.remove(book.id) != null) notifyListeners();
      _dirtyProgress.add(book.id);
    }
  }

  /// Checks one book's synced position, e.g. right as it's opened.
  Future<void> checkProgress(Book book) async {
    final drive = sync.drive;
    if (drive == null) return;
    try {
      await _reconcile(book, await drive.getProgress(book.id));
    } catch (_) {
      // Offline: the periodic sync will catch up.
    }
  }

  /// Moves the book to the other device's position.
  Future<ProgressRecord?> acceptJump(String bookId) async {
    final remote = _pendingJumps.remove(bookId);
    if (remote == null) return null;
    await store.applyRemoteProgress(
      bookId,
      page: remote.page,
      pageOffset: remote.pageOffset,
      updatedAt: remote.updated,
    );
    notifyListeners();
    return remote;
  }

  /// Keeps this device's position and makes it the newest, so the other
  /// device gets the prompt instead.
  Future<void> declineJump(String bookId) async {
    if (_pendingJumps.remove(bookId) == null) return;
    await store.touchProgress(bookId);
    notifyListeners();
    progressChanged(bookId);
  }

  /// Called by the reader after saving a new position; uploads it shortly.
  void progressChanged(String bookId) {
    if (_pendingJumps.containsKey(bookId)) return;
    _dirtyProgress.add(bookId);
    _pushTimer?.cancel();
    _pushTimer = Timer(_pushDelay, _pushDirtyProgress);
  }

  /// Uploads pending positions now, e.g. when the app goes to the background.
  Future<void> flushProgress() {
    _pushTimer?.cancel();
    return _pushDirtyProgress();
  }

  Future<void> _pushDirtyProgress() async {
    final drive = sync.drive;
    if (drive == null || sync.status != SyncStatus.connected) return;
    for (final bookId in _dirtyProgress.toList()) {
      final book = store.byId(bookId);
      if (book == null || book.progressUpdatedAt == null) {
        _dirtyProgress.remove(bookId);
        continue;
      }
      try {
        // Re-check first: the other device may have moved on since we last looked.
        final stored = await drive.getProgress(bookId);
        if (stored != null && !book.progressUpdatedAt!.isAfter(stored.record.updated)) {
          await _reconcile(book, stored);
          _dirtyProgress.remove(bookId);
          continue;
        }
        final record = ProgressRecord.fromBook(book, device: store.deviceName, deviceId: store.deviceId);
        _progressFileIds[bookId] =
            await drive.putProgress(record, existingFileId: stored?.fileId ?? _progressFileIds[bookId]);
        _dirtyProgress.remove(bookId);
      } catch (_) {
        // Stays dirty; retried on the next sync.
      }
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

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:shelfsync/models/shelf.dart';
import 'package:shelfsync/services/library_store.dart';
import 'package:shelfsync/sync/drive_service.dart';
import 'package:shelfsync/sync/google_auth.dart';
import 'package:shelfsync/sync/library_sync.dart';
import 'package:shelfsync/sync/progress_record.dart';
import 'package:shelfsync/sync/sync_controller.dart';

class CloudFile {
  CloudFile(this.id, this.bookId, this.title, this.bytes, this.created);

  final String id;
  final String bookId;
  String title;
  final Uint8List bytes;
  final DateTime created;
  bool trashed = false;
}

/// One Google Drive shared by several simulated devices.
class FakeCloud {
  final files = <CloudFile>[];

  /// appDataFolder progress files: file id -> record.
  final progress = <String, ProgressRecord>{};
  ShelvesDocument? shelves;
  var email = 'reader@example.com';
  var _nextId = 0;
  var _clock = DateTime(2026, 1, 1);

  List<CloudFile> get live => files.where((f) => !f.trashed).toList();

  CloudFile add(String bookId, String title, List<int> bytes) {
    _clock = _clock.add(const Duration(minutes: 1));
    final file = CloudFile('file-${_nextId++}', bookId, title, Uint8List.fromList(bytes), _clock);
    files.add(file);
    return file;
  }
}

class FakeDriveService implements DriveService {
  FakeDriveService(this.cloud);

  final FakeCloud cloud;
  bool corruptDownloads = false;

  @override
  http.Client get client => http.Client();

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError('$invocation');

  @override
  Future<DriveAccount> account() async => DriveAccount(email: cloud.email, displayName: 'Reader');

  @override
  Future<String> ensureLibraryFolder() async => 'folder';

  @override
  Future<void> renameBook(String fileId, String title) async =>
      cloud.files.firstWhere((f) => f.id == fileId).title = title;

  @override
  Future<List<RemoteBook>> listBooks(String folderId) async => [
        for (final f in cloud.live)
          RemoteBook(
            fileId: f.id,
            bookId: f.bookId,
            title: f.title,
            createdTime: f.created,
            sizeBytes: f.bytes.length,
          ),
      ];

  @override
  Future<String> uploadBook({
    required String folderId,
    required File file,
    required String bookId,
    required String title,
    ProgressCallback? onProgress,
  }) async {
    final uploaded = cloud.add(bookId, title, await file.readAsBytes());
    onProgress?.call(1);
    return uploaded.id;
  }

  @override
  Future<void> downloadBook({
    required String fileId,
    required File target,
    int? expectedBytes,
    ProgressCallback? onProgress,
  }) async {
    final f = cloud.files.firstWhere((f) => f.id == fileId);
    await target.writeAsBytes(corruptDownloads ? [0, 1, 2] : f.bytes);
    onProgress?.call(1);
  }

  @override
  Future<bool> isGone(String fileId) async => cloud.files.firstWhere((f) => f.id == fileId).trashed;

  @override
  Future<void> trash(String fileId) async => cloud.files.firstWhere((f) => f.id == fileId).trashed = true;

  @override
  Future<Uint8List?> thumbnail(String link) async => null;

  @override
  Future<Map<String, StoredProgress>> listProgress() async => {
        for (final e in cloud.progress.entries) e.value.bookId: StoredProgress(e.key, e.value),
      };

  @override
  Future<StoredShelves?> getShelves() async {
    final doc = cloud.shelves;
    // Round-trip through JSON like the real file, so devices don't share objects.
    return doc == null ? null : StoredShelves('shelves', ShelvesDocument.fromJson(doc.toJson()));
  }

  @override
  Future<String> putShelves(ShelvesDocument doc, {String? existingFileId}) async {
    cloud.shelves = ShelvesDocument.fromJson(doc.toJson());
    return 'shelves';
  }

  @override
  Future<StoredProgress?> getProgress(String bookId) async => (await listProgress())[bookId];

  @override
  Future<String> putProgress(ProgressRecord record, {String? existingFileId}) async {
    final id = existingFileId ?? 'progress-${cloud.progress.length}';
    cloud.progress[id] = record;
    return id;
  }
}

class _SignedInAuth implements GoogleAuth {
  @override
  bool get isConfigured => true;

  @override
  Future<http.Client?> restore() async => http.Client();

  @override
  Future<http.Client> signIn() async => http.Client();

  @override
  Future<void> signOut() async {}
}

class Device {
  Device._(this.store, this.sync, this.library, this.drive);

  final LibraryStore store;
  final SyncController sync;
  final LibrarySync library;
  final FakeDriveService drive;

  static Future<Device> create(Directory root, FakeCloud cloud) async {
    final store = LibraryStore(root);
    await store.load();
    final drive = FakeDriveService(cloud);
    final sync = SyncController(_SignedInAuth(), driveFactory: (_) => drive);
    await sync.start();
    return Device._(store, sync, LibrarySync(store: store, sync: sync), drive);
  }
}

void main() {
  late Directory tmp;
  late FakeCloud cloud;
  late Device pc, tablet;
  late File pdf;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('shelfsync_sync_test');
    cloud = FakeCloud();
    pc = await Device.create(Directory(p.join(tmp.path, 'pc')), cloud);
    tablet = await Device.create(Directory(p.join(tmp.path, 'tablet')), cloud);
    pdf = File(p.join(tmp.path, 'Signals and Systems.pdf'));
    await pdf.writeAsBytes(List.generate(10000, (i) => (i * 7) % 256));
  });

  tearDown(() => tmp.delete(recursive: true));

  test('a book added on one device appears on the other and downloads intact', () async {
    await pc.store.importFile(pdf.path);
    await pc.library.syncNow();
    expect(cloud.live, hasLength(1));
    expect(cloud.live.single.title, 'Signals and Systems');
    final id = pc.store.books.single.id;
    expect(pc.store.byId(id)!.driveFileId, cloud.live.single.id);

    await tablet.library.syncNow();
    final remote = tablet.store.byId(id)!;
    expect(remote.isLocal, isFalse);
    expect(remote.title, 'Signals and Systems');
    expect(remote.sizeBytes, 10000);

    await tablet.library.download(remote);
    expect(remote.isLocal, isTrue);
    expect(await tablet.store.fileFor(remote).readAsBytes(), await pdf.readAsBytes());

    // Survives a restart as a local book.
    final reloaded = LibraryStore(tablet.store.rootDir);
    await reloaded.load();
    expect(reloaded.byId(id)!.isLocal, isTrue);
  });

  test('a corrupted download is rejected and not kept', () async {
    await pc.store.importFile(pdf.path);
    await pc.library.syncNow();
    await tablet.library.syncNow();
    final remote = tablet.store.books.single;

    tablet.drive.corruptDownloads = true;
    await expectLater(tablet.library.download(remote), throwsStateError);
    expect(remote.isLocal, isFalse);
    expect(await tablet.store.fileFor(remote).exists(), isFalse);
    expect(await tablet.store.downloadTempFor(remote).exists(), isFalse);
  });

  test('delete everywhere trashes in Drive and removes it from the other device', () async {
    await pc.store.importFile(pdf.path);
    await pc.library.syncNow();
    await tablet.library.syncNow();
    await tablet.library.download(tablet.store.books.single);

    await tablet.library.deleteEverywhere(tablet.store.books.single);
    expect(tablet.store.books, isEmpty);
    expect(cloud.live, isEmpty);

    await pc.library.syncNow();
    expect(pc.store.books, isEmpty);
  });

  test('remove download keeps the book as a cloud entry with its progress', () async {
    await pc.store.importFile(pdf.path);
    await pc.library.syncNow();
    final book = pc.store.books.single;
    await pc.store.updateProgress(book.id, page: 12, pageCount: 40);

    await pc.store.removeLocalCopy(book.id);
    expect(book.isLocal, isFalse);
    expect(book.lastPage, 12);

    await pc.library.syncNow();
    expect(pc.store.books, hasLength(1));
    expect(cloud.live, hasLength(1), reason: 'must not re-upload or delete');
  });

  test('the same book imported on both devices is stored once', () async {
    await pc.store.importFile(pdf.path);
    await tablet.store.importFile(pdf.path);
    await pc.library.syncNow();
    await tablet.library.syncNow();
    expect(cloud.live, hasLength(1));
    expect(tablet.store.books.single.driveFileId, cloud.live.single.id);
  });

  test('duplicate uploads from a race are trashed, oldest kept', () async {
    await pc.store.importFile(pdf.path);
    final id = pc.store.books.single.id;
    final first = cloud.add(id, 'Signals and Systems', await pdf.readAsBytes());
    cloud.add(id, 'Signals and Systems', await pdf.readAsBytes());

    await pc.library.syncNow();
    expect(cloud.live.map((f) => f.id), [first.id]);
    expect(pc.store.byId(id)!.driveFileId, first.id);
  });

  group('reading position', () {
    late String id;

    /// Both devices have the book downloaded.
    setUp(() async {
      await pc.store.importFile(pdf.path);
      id = pc.store.books.single.id;
      await pc.library.syncNow();
      await tablet.library.syncNow();
      await tablet.library.download(tablet.store.byId(id)!);
    });

    Future<void> read(Device d, int page, {Offset offset = const Offset(0, 0.3)}) async {
      await Future<void>.delayed(const Duration(milliseconds: 5));
      await d.store.updateProgress(id, page: page, pageCount: 300, pageOffset: offset);
      d.library.progressChanged(id);
      await d.library.flushProgress();
    }

    test('is uploaded with the device name and adopted silently where unread', () async {
      await read(pc, 50, offset: const Offset(0, 0.42));
      final record = cloud.progress.values.single;
      expect(record.page, 50);
      expect(record.device, pc.store.deviceName);
      expect(record.pageOffset!.dy, closeTo(0.42, 1e-9));

      await tablet.library.syncNow();
      final book = tablet.store.byId(id)!;
      expect(book.lastPage, 50);
      expect(book.pageOffsetY, closeTo(0.42, 1e-9));
      expect(tablet.library.pendingJumpFor(id), isNull);
    });

    test('a different page on an already-read book prompts instead of moving', () async {
      await read(pc, 50);
      await tablet.library.syncNow();
      await read(tablet, 120);

      await pc.library.syncNow();
      final pending = pc.library.pendingJumpFor(id);
      expect(pending, isNotNull);
      expect(pending!.page, 120);
      expect(pending.device, tablet.store.deviceName);
      expect(pc.store.byId(id)!.lastPage, 50, reason: 'not moved silently');

      await pc.library.acceptJump(id);
      expect(pc.store.byId(id)!.lastPage, 120);
      expect(pc.library.pendingJumpFor(id), isNull);

      // Accepting must not re-upload the position as if read on the PC.
      await pc.library.syncNow();
      expect(cloud.progress.values.single.device, tablet.store.deviceName);
    });

    test('declining keeps this position and makes the other device ask', () async {
      await read(pc, 50);
      await tablet.library.syncNow();
      await read(tablet, 120);
      await pc.library.syncNow();

      await Future<void>.delayed(const Duration(milliseconds: 5));
      await pc.library.declineJump(id);
      await pc.library.flushProgress();
      expect(pc.store.byId(id)!.lastPage, 50);
      expect(cloud.progress.values.single.page, 50);

      await tablet.library.syncNow();
      expect(tablet.library.pendingJumpFor(id)?.page, 50);
    });

    test('reading on instead of answering withdraws the prompt', () async {
      await read(pc, 50);
      await tablet.library.syncNow();
      await read(tablet, 120);
      await pc.library.syncNow();
      expect(pc.library.pendingJumpFor(id), isNotNull);

      await Future<void>.delayed(const Duration(milliseconds: 5));
      await pc.store.updateProgress(id, page: 60, pageCount: 300, pageOffset: const Offset(0, 0.1));
      await pc.library.syncNow();
      expect(pc.library.pendingJumpFor(id), isNull);
      expect(cloud.progress.values.single.page, 60);
    });

    test('the book open in the reader is never moved silently', () async {
      await read(pc, 50);
      tablet.library.openBookId = id; // unread on the tablet, but open
      await tablet.library.checkProgress(tablet.store.byId(id)!);
      expect(tablet.library.pendingJumpFor(id)?.page, 50);
      expect(tablet.store.byId(id)!.lastPage, 1);
    });

    test('remembers which device the position came from', () async {
      await read(pc, 50);
      await tablet.library.syncNow();
      expect(tablet.store.byId(id)!.progressDevice, pc.store.deviceName);

      await read(tablet, 60);
      expect(tablet.store.byId(id)!.progressDevice, isNull, reason: 'read here now');
    });

    test('with auto-jump on, closed books move without asking', () async {
      await read(pc, 50);
      await tablet.library.syncNow();
      await read(tablet, 120);
      await pc.store.setAutoJump(true);

      await pc.library.syncNow();
      expect(pc.library.pendingJumpFor(id), isNull);
      expect(pc.store.byId(id)!.lastPage, 120);
    });

    test('with auto-jump on, the open book still goes through the reader', () async {
      await read(pc, 50);
      await tablet.library.syncNow();
      await read(tablet, 120);
      await pc.store.setAutoJump(true);
      pc.library.openBookId = id;

      await pc.library.syncNow();
      expect(pc.library.pendingJumpFor(id)?.page, 120);
      expect(pc.store.byId(id)!.lastPage, 50);
    });

    test('re-deriving the same spot on open does not count as reading', () async {
      await read(pc, 50, offset: const Offset(0, 0.42));
      final before = pc.store.byId(id)!.progressUpdatedAt;
      await Future<void>.delayed(const Duration(milliseconds: 5));
      await pc.store.updateProgress(id, page: 50, pageOffset: const Offset(0.0001, 0.4203), zoom: 1.2);
      expect(pc.store.byId(id)!.progressUpdatedAt, before);
    });
  });

  test('a rename reaches Drive and the other device', () async {
    await pc.store.importFile(pdf.path);
    final id = pc.store.books.single.id;
    await pc.library.syncNow();
    await tablet.library.syncNow();

    await pc.library.rename(pc.store.byId(id)!, 'C Programming: A Modern Approach');
    expect(cloud.live.single.title, 'C Programming: A Modern Approach');
    expect(pc.store.byId(id)!.titleDirty, isFalse);

    await tablet.library.syncNow();
    expect(tablet.store.byId(id)!.title, 'C Programming: A Modern Approach');
  });

  group('shelves', () {
    test('a shelf and its books reach the other device', () async {
      await pc.store.importFile(pdf.path);
      final id = pc.store.books.single.id;
      final shelf = await pc.store.createShelf('Semester 8');
      await pc.store.setOnShelf(shelf.id, id, true);
      await pc.library.syncNow();
      expect(pc.store.shelvesDirty, isFalse);

      await tablet.library.syncNow();
      final synced = tablet.store.shelves.single;
      expect(synced.name, 'Semester 8');
      expect(synced.bookIds, {id});
    });

    test('the newest edit wins', () async {
      await pc.store.createShelf('Novels');
      await pc.library.syncNow();
      await tablet.library.syncNow();

      await Future<void>.delayed(const Duration(milliseconds: 5));
      await tablet.store.renameShelf(tablet.store.shelves.single.id, 'Fiction');
      await tablet.library.syncNow();
      await pc.library.syncNow();
      expect(pc.store.shelves.single.name, 'Fiction');

      await Future<void>.delayed(const Duration(milliseconds: 5));
      await pc.store.deleteShelf(pc.store.shelves.single.id);
      await pc.library.syncNow();
      await tablet.library.syncNow();
      expect(tablet.store.shelves, isEmpty);
    });
  });

  test('switching Google accounts unlinks books instead of deleting them', () async {
    await pc.store.importFile(pdf.path);
    await pc.library.syncNow();
    await tablet.library.syncNow();
    expect(tablet.store.books.single.isLocal, isFalse);

    // Same devices, now signed in to an empty Drive of another account.
    final other = FakeCloud()..email = 'someone-else@example.com';
    final pc2 = await Device.create(pc.store.rootDir, other);
    final tablet2 = await Device.create(tablet.store.rootDir, other);

    await pc2.library.syncNow();
    expect(pc2.store.books, hasLength(1), reason: 'local book kept');
    expect(await pc2.store.fileFor(pc2.store.books.single).exists(), isTrue);
    expect(other.live, hasLength(1), reason: 're-uploaded to the new account');

    await tablet2.store.load();
    // The tablet's old cloud-only entry is replaced by the new account's copy.
    await tablet2.library.syncNow();
    expect(tablet2.store.books.single.driveFileId, other.live.single.id);
  });
}

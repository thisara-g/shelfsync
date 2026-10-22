import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:shelfsync/services/library_store.dart';
import 'package:shelfsync/sync/drive_service.dart';
import 'package:shelfsync/sync/google_auth.dart';
import 'package:shelfsync/sync/library_sync.dart';
import 'package:shelfsync/sync/sync_controller.dart';

class CloudFile {
  CloudFile(this.id, this.bookId, this.title, this.bytes, this.created);

  final String id;
  final String bookId;
  final String title;
  final Uint8List bytes;
  final DateTime created;
  bool trashed = false;
}

/// One Google Drive shared by several simulated devices.
class FakeCloud {
  final files = <CloudFile>[];
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

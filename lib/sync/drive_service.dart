import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:googleapis/drive/v3.dart' as drive;
import 'package:http/http.dart' as http;

import 'progress_record.dart';

class DriveAccount {
  const DriveAccount({required this.email, required this.displayName});

  final String email;
  final String displayName;
}

/// A book PDF stored in the ShelfSync Drive folder.
class RemoteBook {
  const RemoteBook({
    required this.fileId,
    required this.bookId,
    required this.title,
    required this.createdTime,
    this.sizeBytes,
    this.thumbnailLink,
  });

  final String fileId;

  /// SHA-256 of the content, from the file's appProperties.
  final String bookId;
  final String title;
  final DateTime createdTime;
  final int? sizeBytes;
  final String? thumbnailLink;
}

typedef ProgressCallback = void Function(double fraction);

/// Thin wrapper over the Drive v3 API for ShelfSync's needs.
///
/// With the `drive.file` scope, queries only ever see files this app created,
/// so the folder lookup can't pick up an unrelated "ShelfSync" folder.
class DriveService {
  DriveService(this.client) : api = drive.DriveApi(client);

  final http.Client client;
  final drive.DriveApi api;

  static const folderName = 'ShelfSync';
  static const _folderMime = 'application/vnd.google-apps.folder';

  Future<DriveAccount> account() async {
    final about = await api.about.get($fields: 'user(displayName,emailAddress)');
    final user = about.user;
    return DriveAccount(
      email: user?.emailAddress ?? '',
      displayName: user?.displayName ?? '',
    );
  }

  /// Returns the id of the visible `ShelfSync` folder, creating it on first use.
  ///
  /// If two devices raced and created two folders, the oldest one wins so
  /// every device converges on the same folder.
  Future<String> ensureLibraryFolder() async {
    final existing = await api.files.list(
      q: "mimeType = '$_folderMime' and name = '$folderName' and 'root' in parents and trashed = false",
      orderBy: 'createdTime',
      pageSize: 10,
      spaces: 'drive',
      $fields: 'files(id)',
    );
    final found = existing.files;
    if (found != null && found.isNotEmpty) return found.first.id!;

    final created = await api.files.create(
      drive.File(name: folderName, mimeType: _folderMime, parents: ['root']),
      $fields: 'id',
    );
    return created.id!;
  }

  /// All ShelfSync books in [folderId], oldest first.
  Future<List<RemoteBook>> listBooks(String folderId) async {
    final books = <RemoteBook>[];
    String? pageToken;
    do {
      final page = await api.files.list(
        q: "'$folderId' in parents and trashed = false and appProperties has { key='shelfsync' and value='book' }",
        orderBy: 'createdTime',
        pageSize: 1000,
        pageToken: pageToken,
        spaces: 'drive',
        $fields: 'nextPageToken, files(id, name, size, createdTime, appProperties, thumbnailLink)',
      );
      for (final f in page.files ?? const <drive.File>[]) {
        final bookId = f.appProperties?['shelfsync_id'];
        if (f.id == null || bookId == null) continue;
        final name = f.name ?? 'Untitled.pdf';
        books.add(RemoteBook(
          fileId: f.id!,
          bookId: bookId,
          title: name.toLowerCase().endsWith('.pdf') ? name.substring(0, name.length - 4) : name,
          createdTime: f.createdTime ?? DateTime.now(),
          sizeBytes: int.tryParse(f.size ?? ''),
          thumbnailLink: f.thumbnailLink,
        ));
      }
      pageToken = page.nextPageToken;
    } while (pageToken != null);
    return books;
  }

  /// Uploads [file] into [folderId] (resumable, so large PDFs survive hiccups).
  /// Returns the new Drive file id.
  Future<String> uploadBook({
    required String folderId,
    required File file,
    required String bookId,
    required String title,
    ProgressCallback? onProgress,
  }) async {
    final length = await file.length();
    var sent = 0;
    final stream = file.openRead().map((chunk) {
      sent += chunk.length;
      onProgress?.call(length == 0 ? 1 : sent / length);
      return chunk;
    });
    final created = await api.files.create(
      drive.File(
        name: '$title.pdf',
        parents: [folderId],
        mimeType: 'application/pdf',
        appProperties: {'shelfsync': 'book', 'shelfsync_id': bookId},
      ),
      uploadMedia: drive.Media(stream, length, contentType: 'application/pdf'),
      uploadOptions: drive.UploadOptions.resumable,
      $fields: 'id',
    );
    return created.id!;
  }

  /// Streams the file's content into [target].
  Future<void> downloadBook({
    required String fileId,
    required File target,
    int? expectedBytes,
    ProgressCallback? onProgress,
  }) async {
    final media = await api.files.get(fileId, downloadOptions: drive.DownloadOptions.fullMedia) as drive.Media;
    final total = media.length ?? expectedBytes;
    var received = 0;
    final sink = target.openWrite();
    try {
      await for (final chunk in media.stream) {
        sink.add(chunk);
        received += chunk.length;
        if (total != null && total > 0) onProgress?.call(received / total);
      }
    } finally {
      await sink.close();
    }
  }

  /// True if the file was deleted or trashed (as opposed to merely missing
  /// from a possibly stale listing).
  Future<bool> isGone(String fileId) async {
    try {
      final f = await api.files.get(fileId, $fields: 'trashed') as drive.File;
      return f.trashed ?? false;
    } on drive.DetailedApiRequestError catch (e) {
      if (e.status == 404) return true;
      rethrow;
    }
  }

  /// Moves the file to the Drive trash (recoverable for 30 days).
  Future<void> renameBook(String fileId, String title) => api.files.update(drive.File(name: '$title.pdf'), fileId);

  Future<void> trash(String fileId) => api.files.update(drive.File(trashed: true), fileId);

  /// Drive's own first-page thumbnail for a PDF, if it has generated one.
  Future<Uint8List?> thumbnail(String link) async {
    try {
      // Ask for a larger rendition than the default 220px.
      final sized = link.replaceFirst(RegExp(r'=s\d+$'), '=s400');
      final response = await client.get(Uri.parse(sized));
      final type = response.headers['content-type'] ?? '';
      return response.statusCode == 200 && type.startsWith('image/') ? response.bodyBytes : null;
    } catch (_) {
      return null;
    }
  }

  static const _progressQuery = "appProperties has { key='shelfsync' and value='progress' }";
  static const _progressFields = 'nextPageToken, files(id, appProperties)';

  /// Every reading-position record in the hidden appDataFolder, by book id.
  Future<Map<String, StoredProgress>> listProgress() async {
    final records = <String, StoredProgress>{};
    String? pageToken;
    do {
      final page = await api.files.list(
        spaces: 'appDataFolder',
        q: _progressQuery,
        pageSize: 1000,
        pageToken: pageToken,
        $fields: _progressFields,
      );
      for (final f in page.files ?? const <drive.File>[]) {
        final record = ProgressRecord.fromAppProperties(f.appProperties);
        if (f.id == null || record == null) continue;
        // Should be one file per book; if two devices raced, keep the newest.
        final existing = records[record.bookId];
        if (existing == null || record.updated.isAfter(existing.record.updated)) {
          records[record.bookId] = StoredProgress(f.id!, record);
        }
      }
      pageToken = page.nextPageToken;
    } while (pageToken != null);
    return records;
  }

  /// The record for one book, for a quick check when it's opened.
  Future<StoredProgress?> getProgress(String bookId) async {
    final result = await api.files.list(
      spaces: 'appDataFolder',
      q: "name = '${ProgressRecord.fileNameFor(bookId)}' and $_progressQuery",
      $fields: _progressFields,
    );
    StoredProgress? newest;
    for (final f in result.files ?? const <drive.File>[]) {
      final record = ProgressRecord.fromAppProperties(f.appProperties);
      if (f.id == null || record == null) continue;
      if (newest == null || record.updated.isAfter(newest.record.updated)) newest = StoredProgress(f.id!, record);
    }
    return newest;
  }

  /// Creates or overwrites a book's record. Returns the Drive file id.
  Future<String> putProgress(ProgressRecord record, {String? existingFileId}) async {
    final bytes = utf8.encode(const JsonEncoder.withIndent('  ').convert(record.toJson()));
    final media = drive.Media(Stream.value(bytes), bytes.length, contentType: 'application/json');
    final metadata = drive.File(appProperties: record.toAppProperties());
    if (existingFileId != null) {
      final updated = await api.files.update(metadata, existingFileId, uploadMedia: media, $fields: 'id');
      return updated.id!;
    }
    metadata
      ..name = ProgressRecord.fileNameFor(record.bookId)
      ..parents = ['appDataFolder']
      ..mimeType = 'application/json';
    final created = await api.files.create(metadata, uploadMedia: media, $fields: 'id');
    return created.id!;
  }

  static Uri folderUrl(String folderId) => Uri.parse('https://drive.google.com/drive/folders/$folderId');
}

import 'dart:ui' show Offset;

import '../models/book.dart';

/// A book's reading position as synced through Drive's hidden appDataFolder,
/// one `progress-<book id>.json` file per book.
class ProgressRecord {
  const ProgressRecord({
    required this.bookId,
    required this.page,
    required this.percent,
    required this.device,
    required this.deviceId,
    required this.updated,
    this.pageOffset,
  });

  final String bookId;

  /// 1-based page.
  final int page;
  final double percent;

  /// Viewport top-left relative to [page], as fractions of the page size.
  final Offset? pageOffset;

  /// Name of the device that recorded it, for "Jump to page X (from …)?".
  final String device;
  final String deviceId;
  final DateTime updated;

  static String fileNameFor(String bookId) => 'progress-$bookId.json';

  factory ProgressRecord.fromBook(Book book, {required String device, required String deviceId}) {
    final x = book.pageOffsetX, y = book.pageOffsetY;
    return ProgressRecord(
      bookId: book.id,
      page: book.lastPage,
      percent: book.progress,
      pageOffset: x == null || y == null ? null : Offset(x, y),
      device: device,
      deviceId: deviceId,
      updated: book.progressUpdatedAt ?? DateTime.now(),
    );
  }

  /// The file's content, matching the format described in CLAUDE.md.
  Map<String, Object?> toJson() => {
        'book_id': bookId,
        'page': page,
        'percent': double.parse(percent.toStringAsFixed(4)),
        'offset_x': pageOffset?.dx,
        'offset_y': pageOffset?.dy,
        'device': device,
        'device_id': deviceId,
        'updated': updated.millisecondsSinceEpoch ~/ 1000,
        'updated_ms': updated.millisecondsSinceEpoch,
      };

  /// The same fields as Drive appProperties (string values, each key+value
  /// under 124 bytes), so one listing call returns every record. Null values
  /// delete a key when updating an existing file.
  Map<String, String?> toAppProperties() => {
        'shelfsync': 'progress',
        'book_id': bookId,
        'page': '$page',
        'percent': percent.toStringAsFixed(4),
        'ox': pageOffset?.dx.toStringAsFixed(5),
        'oy': pageOffset?.dy.toStringAsFixed(5),
        'device': device.length > 60 ? device.substring(0, 60) : device,
        'device_id': deviceId,
        'updated_ms': '${updated.millisecondsSinceEpoch}',
      };

  static ProgressRecord? fromAppProperties(Map<String, String?>? props) {
    if (props == null || props['shelfsync'] != 'progress') return null;
    final bookId = props['book_id'];
    final page = int.tryParse(props['page'] ?? '');
    final updated = int.tryParse(props['updated_ms'] ?? '');
    if (bookId == null || page == null || updated == null) return null;
    final ox = double.tryParse(props['ox'] ?? ''), oy = double.tryParse(props['oy'] ?? '');
    return ProgressRecord(
      bookId: bookId,
      page: page,
      percent: double.tryParse(props['percent'] ?? '') ?? 0,
      pageOffset: ox == null || oy == null ? null : Offset(ox, oy),
      device: props['device'] ?? 'another device',
      deviceId: props['device_id'] ?? '',
      updated: DateTime.fromMillisecondsSinceEpoch(updated),
    );
  }
}

/// A [ProgressRecord] together with the Drive file holding it.
class StoredProgress {
  const StoredProgress(this.fileId, this.record);

  final String fileId;
  final ProgressRecord record;
}

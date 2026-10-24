/// A book in the local library.
///
/// [id] is the SHA-256 of the file contents, so the same file gets the same id
/// on every device regardless of its filename.
class Book {
  Book({
    required this.id,
    required this.title,
    required this.fileName,
    required this.addedAt,
    this.pageCount,
    this.lastPage = 1,
    this.pageOffsetX,
    this.pageOffsetY,
    this.zoom,
    this.lastOpenedAt,
    this.driveFileId,
    this.sizeBytes,
    this.isLocal = true,
    this.progressUpdatedAt,
    this.progressDevice,
    this.chapter,
    this.titleDirty = false,
  });

  final String id;
  String title;
  final String fileName;
  final DateTime addedAt;
  int? pageCount;

  /// 1-based page number the reader was last on.
  int lastPage;

  /// Top-left of the viewport relative to page [lastPage], as fractions of that
  /// page's width/height (so it is independent of screen size). Values outside
  /// 0..1 mean the viewport starts beyond that page's edge.
  double? pageOffsetX;
  double? pageOffsetY;

  /// Viewer zoom. Screen-dependent, so only meaningful on this device.
  double? zoom;
  DateTime? lastOpenedAt;

  /// Id of the PDF in the user's ShelfSync Drive folder, once uploaded.
  String? driveFileId;
  int? sizeBytes;

  /// When the reading position last changed (here, or as adopted from another
  /// device). Compared across devices: the latest position wins.
  DateTime? progressUpdatedAt;

  /// Name of the device the current position came from, or null when it was
  /// read on this device.
  String? progressDevice;

  /// Top-level outline entry (e.g. "9 Functions") at [lastPage], as last seen
  /// by this device's reader. Cleared when a position from elsewhere arrives.
  String? chapter;

  /// Renamed here but not yet renamed in Drive.
  bool titleDirty;

  /// Whether the PDF is downloaded on this device. Not persisted: derived from
  /// the file's presence when the library loads.
  bool isLocal;

  bool get isFinished {
    final count = pageCount;
    return count != null && lastPage >= count;
  }

  /// Opened or read somewhere (possibly another device) and not finished.
  bool get isStarted => (lastOpenedAt != null || progressUpdatedAt != null) && !isFinished;

  /// When this book was last read on any device.
  DateTime? get lastReadAt {
    final a = lastOpenedAt, b = progressUpdatedAt;
    if (a == null) return b;
    if (b == null) return a;
    return a.isAfter(b) ? a : b;
  }

  double get progress {
    final count = pageCount;
    if (count == null || count <= 1) return 0;
    return ((lastPage - 1) / (count - 1)).clamp(0.0, 1.0);
  }

  factory Book.fromJson(Map<String, dynamic> json) => Book(
        id: json['id'] as String,
        title: json['title'] as String,
        fileName: json['fileName'] as String,
        addedAt: DateTime.fromMillisecondsSinceEpoch(json['addedAt'] as int),
        pageCount: json['pageCount'] as int?,
        lastPage: json['lastPage'] as int? ?? 1,
        pageOffsetX: (json['pageOffsetX'] as num?)?.toDouble(),
        pageOffsetY: (json['pageOffsetY'] as num?)?.toDouble(),
        zoom: (json['zoom'] as num?)?.toDouble(),
        driveFileId: json['driveFileId'] as String?,
        sizeBytes: json['sizeBytes'] as int?,
        progressUpdatedAt: json['progressUpdatedAt'] == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch(json['progressUpdatedAt'] as int),
        progressDevice: json['progressDevice'] as String?,
        chapter: json['chapter'] as String?,
        titleDirty: json['titleDirty'] as bool? ?? false,
        lastOpenedAt: json['lastOpenedAt'] == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch(json['lastOpenedAt'] as int),
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'fileName': fileName,
        'addedAt': addedAt.millisecondsSinceEpoch,
        'pageCount': pageCount,
        'lastPage': lastPage,
        'pageOffsetX': pageOffsetX,
        'pageOffsetY': pageOffsetY,
        'zoom': zoom,
        'driveFileId': driveFileId,
        'sizeBytes': sizeBytes,
        'progressUpdatedAt': progressUpdatedAt?.millisecondsSinceEpoch,
        'progressDevice': progressDevice,
        'chapter': chapter,
        'titleDirty': titleDirty,
        'lastOpenedAt': lastOpenedAt?.millisecondsSinceEpoch,
      };
}

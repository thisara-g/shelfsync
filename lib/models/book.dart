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
        'lastOpenedAt': lastOpenedAt?.millisecondsSinceEpoch,
      };
}

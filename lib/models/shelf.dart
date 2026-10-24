/// A user-made collection of books, e.g. "Semester 8".
class Shelf {
  Shelf({required this.id, required this.name, required this.color, Set<String>? bookIds})
      : bookIds = bookIds ?? {};

  final String id;
  String name;

  /// Index into [shelfColors].
  int color;

  /// Ids (content hashes) of the books on this shelf.
  final Set<String> bookIds;

  factory Shelf.fromJson(Map<String, dynamic> json) => Shelf(
        id: json['id'] as String,
        name: json['name'] as String,
        color: json['color'] as int? ?? 0,
        bookIds: {for (final id in json['books'] as List<dynamic>? ?? const []) id as String},
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'color': color,
        'books': bookIds.toList()..sort(),
      };
}

/// Shelf colours as ARGB values, in the order new shelves pick them.
const shelfColors = [
  0xFF42A5F5, // blue
  0xFF66BB6A, // green
  0xFFEF5350, // red
  0xFFFFCA28, // amber
  0xFFAB47BC, // purple
  0xFFFFA726, // orange
  0xFF26A69A, // teal
  0xFFEC407A, // pink
];

/// Shelves and bookmarks as one synced document; the newest edit wins.
class ShelvesDocument {
  const ShelvesDocument({required this.shelves, required this.updated, this.bookmarks = const {}});

  final List<Shelf> shelves;

  /// Bookmarked pages by book id.
  final Map<String, Set<int>> bookmarks;
  final DateTime updated;

  static const fileName = 'shelves.json';

  factory ShelvesDocument.fromJson(Map<String, dynamic> json) => ShelvesDocument(
        shelves: [for (final s in json['shelves'] as List<dynamic>? ?? const []) Shelf.fromJson(s as Map<String, dynamic>)],
        bookmarks: {
          for (final e in (json['bookmarks'] as Map<String, dynamic>? ?? const {}).entries)
            e.key: {for (final p in e.value as List<dynamic>) p as int},
        },
        updated: DateTime.fromMillisecondsSinceEpoch(json['updated_ms'] as int? ?? 0),
      );

  Map<String, dynamic> toJson() => {
        'updated_ms': updated.millisecondsSinceEpoch,
        'shelves': [for (final s in shelves) s.toJson()],
        'bookmarks': {
          for (final e in bookmarks.entries)
            if (e.value.isNotEmpty) e.key: e.value.toList()..sort(),
        },
      };
}

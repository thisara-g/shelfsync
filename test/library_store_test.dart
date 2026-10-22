import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shelfsync/services/library_store.dart';

void main() {
  late Directory tmp;
  late File source;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('shelfsync_test');
    source = File(p.join(tmp.path, 'My Book.pdf'));
    await source.writeAsBytes(List.generate(4096, (i) => i % 256));
  });

  tearDown(() => tmp.delete(recursive: true));

  test('imports a file, keyed by content hash, titled from filename', () async {
    final store = LibraryStore(Directory(p.join(tmp.path, 'lib')));
    await store.load();

    expect(await store.importFile(source.path), ImportResult.added);
    final book = store.books.single;
    expect(book.title, 'My Book');
    expect(book.id, await LibraryStore.hashFile(source.path));
    expect(await store.fileFor(book).exists(), isTrue);
  });

  test('same content under a different name is a duplicate', () async {
    final store = LibraryStore(Directory(p.join(tmp.path, 'lib')));
    await store.load();
    await store.importFile(source.path);

    final renamed = await source.copy(p.join(tmp.path, 'copy.pdf'));
    expect(await store.importFile(renamed.path), ImportResult.duplicate);
    expect(store.books, hasLength(1));
  });

  test('progress persists across reload', () async {
    final root = Directory(p.join(tmp.path, 'lib'));
    final store = LibraryStore(root);
    await store.load();
    await store.importFile(source.path);
    final id = store.books.single.id;
    await store.updateProgress(id, page: 42, pageCount: 100, pageOffset: const Offset(0.1, 0.62), zoom: 1.5);

    final reloaded = LibraryStore(root);
    await reloaded.load();
    final book = reloaded.byId(id)!;
    expect(book.lastPage, 42);
    expect(book.pageCount, 100);
    expect(book.pageOffsetX, 0.1);
    expect(book.pageOffsetY, 0.62);
    expect(book.zoom, 1.5);
  });

  test('remove deletes the stored file', () async {
    final store = LibraryStore(Directory(p.join(tmp.path, 'lib')));
    await store.load();
    await store.importFile(source.path);
    final book = store.books.single;

    await store.remove(book.id);
    expect(store.books, isEmpty);
    expect(await store.fileFor(book).exists(), isFalse);
  });
}

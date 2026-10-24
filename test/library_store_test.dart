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

  test('tidies file-name titles', () {
    expect(LibraryStore.titleFromFileName('c-programming_2nd-ed.pdf'), 'C programming 2nd ed');
    expect(LibraryStore.titleFromFileName('Real-Time Systems.pdf'), 'Real-Time Systems');
    expect(LibraryStore.titleFromFileName('notes.pdf'), 'Notes');
  });

  test('reader settings persist; a fresh install shows the welcome', () async {
    final dir = Directory(p.join(tmp.path, 'lib'));
    final store = LibraryStore(dir);
    await store.load();
    expect(store.welcomeDone, isFalse);
    expect(store.readerTheme, ReaderTheme.light);

    await store.setWelcomeDone();
    await store.setReaderTheme(ReaderTheme.sepia);
    await store.setAutoJump(true);
    await store.setTwoPageSpread(true);

    final reloaded = LibraryStore(dir);
    await reloaded.load();
    expect(reloaded.welcomeDone, isTrue);
    expect(reloaded.readerTheme, ReaderTheme.sepia);
    expect(reloaded.autoJump, isTrue);
    expect(reloaded.twoPageSpread, isTrue);
  });

  test('a 0.1 library keeps dark pages and skips the welcome', () async {
    final dir = Directory(p.join(tmp.path, 'lib'));
    await dir.create(recursive: true);
    await File(p.join(dir.path, 'library.json')).writeAsString(
      '{"version":1,"settings":{"darkReader":true,"deviceId":"ab","deviceName":"pc"},"books":[]}',
    );
    final store = LibraryStore(dir);
    await store.load();
    expect(store.readerTheme, ReaderTheme.dark);
    expect(store.welcomeDone, isTrue);
  });

  test('finished and started books', () async {
    final store = LibraryStore(Directory(p.join(tmp.path, 'lib')));
    await store.load();
    await store.importFile(source.path);
    final book = store.books.single;
    expect(book.isStarted, isFalse);

    await store.markOpened(book.id);
    await store.updateProgress(book.id, page: 10, pageCount: 20, chapter: '2 Basics');
    expect(book.isStarted, isTrue);
    expect(book.chapter, '2 Basics');

    await store.updateProgress(book.id, page: 20, pageCount: 20);
    expect(book.isFinished, isTrue);
    expect(book.isStarted, isFalse);
  });
}

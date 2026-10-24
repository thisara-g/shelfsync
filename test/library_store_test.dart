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

  test('suggests proper titles for a rename', () {
    expect(
      LibraryStore.renameSuggestions(
        'c-programming-a-modern-approach-second-edition.pdf',
        'c-programming-a-modern-approach-second-edition',
      ),
      ['C Programming a Modern Approach (2nd edition)', 'C Programming A Modern Approach Second Edition'],
    );
    expect(LibraryStore.renameSuggestions('communication_systems_4th_ed.pdf', 'x'), [
      'Communication Systems (4th edition)',
      'Communication Systems 4th Ed',
    ]);
    // ISBNs, ids and site tags are dropped.
    expect(
      LibraryStore.renameSuggestions(
        'c-programming-a-modern-approach-second-edition-2nbsped-9780393979503-2007049425_compress.pdf',
        'x',
      ),
      ['C Programming a Modern Approach (2nd edition)', 'C Programming A Modern Approach Second Edition'],
    );
    // Own capitals survive; the current title is not offered again.
    expect(LibraryStore.renameSuggestions('5G NR in Bullets.pdf', '5G NR in Bullets'), ['5G NR In Bullets']);
  });

  test('a shelf can change name and colour', () async {
    final store = LibraryStore(Directory(p.join(tmp.path, 'lib')));
    await store.load();
    final shelf = await store.createShelf('Novels');
    await store.editShelf(shelf.id, name: ' Fiction ', color: 7);
    expect((shelf.name, shelf.color), ('Fiction', 7));
    await store.editShelf(shelf.id, name: '  ');
    expect(shelf.name, 'Fiction');
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
    await store.setReaderLayout(ReaderLayout.single);

    final reloaded = LibraryStore(dir);
    await reloaded.load();
    expect(reloaded.welcomeDone, isTrue);
    expect(reloaded.readerTheme, ReaderTheme.sepia);
    expect(reloaded.autoJump, isTrue);
    expect(reloaded.readerLayout, ReaderLayout.single);
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

  test('shelves keep their colour and take several books at once', () async {
    final root = Directory(p.join(tmp.path, 'lib'));
    final store = LibraryStore(root);
    await store.load();
    final shelf = await store.createShelf('Research papers', color: 4);
    expect(await store.addToShelf(shelf.id, ['a', 'b']), 2);
    expect(await store.addToShelf(shelf.id, ['b', 'c']), 1);

    final reloaded = LibraryStore(root);
    await reloaded.load();
    final again = reloaded.shelfById(shelf.id)!;
    expect(again.color, 4);
    expect(again.bookIds, {'a', 'b', 'c'});
  });

  test('saves started together all land, the last one winning', () async {
    final root = Directory(p.join(tmp.path, 'lib'));
    final store = LibraryStore(root);
    await store.load();
    final shelf = await store.createShelf('Novels');
    await Future.wait([
      for (var i = 0; i < 10; i++) store.setOnShelf(shelf.id, 'book$i', true),
    ]);

    final reloaded = LibraryStore(root);
    await reloaded.load();
    expect(reloaded.shelfById(shelf.id)!.bookIds, hasLength(10));
  });
}

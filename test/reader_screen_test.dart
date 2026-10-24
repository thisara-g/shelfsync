import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:pdfrx/pdfrx.dart';
import 'package:shelfsync/screens/common.dart';
import 'package:shelfsync/screens/reader_screen.dart';
import 'package:shelfsync/services/library_store.dart';
import 'package:shelfsync/sync/google_auth.dart';
import 'package:shelfsync/sync/library_sync.dart';
import 'package:shelfsync/sync/sync_controller.dart';

class _NoAuth implements GoogleAuth {
  @override
  bool get isConfigured => false;

  @override
  Future<http.Client?> restore() async => null;

  @override
  Future<http.Client> signIn() => throw UnimplementedError();

  @override
  Future<void> signOut() async {}
}

/// Opens the real reader on a small PDF and checks it builds without errors,
/// in the desktop and touch layouts and in every page layout.
void main() {
  late Directory tmp;
  late LibraryStore store;
  late LibrarySync librarySync;

  // `flutter test` has no bundled native assets; use the PDFium that
  // `flutter build linux` (or `flutter test` itself) puts in build/.
  setUpAll(() {
    final pdfium = File('build/native_assets/linux/libpdfium.so');
    if (pdfium.existsSync()) Pdfrx.pdfiumModulePath = pdfium.absolute.path;
  });

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('shelfsync_reader');
    // pdfrx asks path_provider for a cache directory.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => tmp.path,
    );
    store = LibraryStore(Directory(p.join(tmp.path, 'lib')));
    await store.load();
    await store.importFile('test/fixtures/sample.pdf');
    final sync = SyncController(_NoAuth());
    await sync.start();
    librarySync = LibrarySync(store: store, sync: sync);
  });

  tearDown(() => tmp.delete(recursive: true));

  Future<void> openReader(WidgetTester tester, Size size) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      theme: shelfSyncTheme(),
      home: ReaderScreen(store: store, librarySync: librarySync, book: store.books.single),
    ));
    // Let the PDF load (real PDFium, off the fake clock) and the viewer's
    // zoom animations run (on the fake clock).
    for (var i = 0; i < 20; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  for (final layout in ReaderLayout.values) {
    testWidgets('desktop reader opens in ${layout.name} layout', (tester) async {
      await tester.runAsync(() => store.setReaderLayout(layout));
      await openReader(tester, const Size(1400, 900));
      expect(tester.takeException(), isNull);
      expect(find.text('Two pages'), findsOneWidget);
      expect(find.text('Scroll'), findsNothing);
      expect(find.text('of 3'), findsOneWidget);

      // The sample page fits the window, so ↓ continues to the next page(s).
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      for (var i = 0; i < 5; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
        await tester.pump(const Duration(milliseconds: 300));
      }
      expect(find.widgetWithText(TextField, '1'), findsNothing, reason: 'moved past page 1');

      // Panel, search and bookmark all work once the document is loaded.
      await tester.tap(find.byTooltip('Show contents (Ctrl+B)'));
      await tester.pump();
      expect(find.text('Contents'), findsOneWidget);
      await tester.tap(find.byTooltip('Search in book (Ctrl+F)'));
      await tester.pump();
      await tester.enterText(find.byType(TextField).last, 'pointer');
      for (var i = 0; i < 10; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
        await tester.pump();
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox()); // dispose the reader
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pump(const Duration(seconds: 10)); // let pdfrx's timers finish
    });
  }

  testWidgets('touch reader opens', (tester) async {
    await openReader(tester, const Size(700, 1000));
    expect(tester.takeException(), isNull);
    expect(find.byTooltip('Contents, pages and bookmarks'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pump(const Duration(seconds: 10));
  });
}

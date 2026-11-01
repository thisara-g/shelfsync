import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:pdfrx/pdfrx.dart';
import 'package:shelfsync/screens/common.dart';
import 'package:shelfsync/screens/reader_screen.dart';
import 'package:shelfsync/screens/tablet_ui.dart';
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

void main() {
  testWidgets('tablet reader: the bars hide 5s after the book opens, then 3s after each tap', (tester) async {
    debugTouchLayout = true;
    addTearDown(() => debugTouchLayout = false);
    Pdfrx.pdfiumModulePath = File('build/native_assets/linux/libpdfium.so').absolute.path;
    final tmp = await tester.runAsync(() => Directory.systemTemp.createTemp('bars'));
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => tmp!.path,
    );
    final store = LibraryStore(Directory(p.join(tmp!.path, 'lib')));
    await tester.runAsync(() async {
      await store.load();
      await store.importFile('test/fixtures/six_pages.pdf');
    });
    final sync = SyncController(_NoAuth());
    await tester.runAsync(sync.start);
    tester.view.physicalSize = const Size(800, 1280);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: tabletTheme(),
        home: ReaderScreen(
          store: store,
          librarySync: LibrarySync(store: store, sync: sync),
          book: store.books.single,
        ),
      ),
    );
    for (var i = 0; i < 10; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pump(const Duration(milliseconds: 100));
    }

    bool barsShowing() => tester.getTopLeft(find.byTooltip('Back to library')).dy > 0;

    expect(barsShowing(), isTrue);
    await tester.pump(const Duration(seconds: 4));
    await tester.pump(const Duration(milliseconds: 300));
    expect(barsShowing(), isTrue, reason: 'not yet 5s since the book appeared');
    await tester.pump(const Duration(seconds: 2));
    await tester.pump(const Duration(milliseconds: 300));
    expect(barsShowing(), isFalse, reason: 'hidden 5s after the book appeared');

    // A tap brings them back; from now on they go after 3s.
    await tester.tapAt(const Offset(400, 640));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(const Duration(milliseconds: 300));
    expect(barsShowing(), isTrue);
    await tester.pump(const Duration(seconds: 1));
    expect(barsShowing(), isTrue, reason: 'not yet 3s since the tap');
    await tester.pump(const Duration(seconds: 2));
    await tester.pump(const Duration(milliseconds: 300));
    expect(barsShowing(), isFalse, reason: 'hidden 3s after the tap');

    // Search keeps them; closing search starts the 5s again.
    await tester.tapAt(const Offset(400, 640));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.byTooltip('Search in book'));
    await tester.pump(const Duration(seconds: 8));
    expect(barsShowing(), isTrue, reason: 'search keeps the bars');
    await tester.tap(find.byTooltip('Search in book'));
    await tester.pump(const Duration(seconds: 4));
    await tester.pump(const Duration(milliseconds: 300));
    expect(barsShowing(), isFalse, reason: 'hidden 3s after search closed');

    // Let the reader save and its timers finish.
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 6));
  });
}

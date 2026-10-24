import 'dart:io';

import 'package:flutter/gestures.dart';
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

void main() {
  testWidgets('pinching with the pointer still on the toolbar zooms the page', (tester) async {
    Pdfrx.pdfiumModulePath = File('build/native_assets/linux/libpdfium.so').absolute.path;
    final tmp = await tester.runAsync(() => Directory.systemTemp.createTemp('z'));
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
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    await tester.pumpWidget(
      MaterialApp(
        theme: shelfSyncTheme(),
        home: ReaderScreen(
          store: store,
          librarySync: LibrarySync(store: store, sync: sync),
          book: store.books.single,
        ),
      ),
    );
    Future<void> settle() async {
      for (var i = 0; i < 12; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 60)));
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    Future<void> pinch(double scale, Offset at) async {
      tester.binding.handlePointerEvent(PointerPanZoomStartEvent(pointer: 9, position: at));
      for (var i = 1; i <= 5; i++) {
        tester.binding.handlePointerEvent(
          PointerPanZoomUpdateEvent(pointer: 9, position: at, scale: 1 + (scale - 1) * i / 5),
        );
        await tester.pump(const Duration(milliseconds: 16));
      }
      tester.binding.handlePointerEvent(PointerPanZoomEndEvent(pointer: 9, position: at));
      await settle();
    }

    await settle();
    final c = tester.widget<PdfViewer>(find.byType(PdfViewer)).controller!;
    final colour = find.byWidgetPredicate((w) => w is Tooltip && (w.message ?? '').startsWith('Page colour'));
    final onButton = tester.getCenter(colour);
    await tester.tap(colour);
    await settle();
    expect(store.readerTheme, ReaderTheme.dark);

    // The pointer is still on the colour button, over the toolbar.
    final before = c.currentZoom;
    await pinch(1.8, onButton);
    expect(c.currentZoom, greaterThan(before * 1.5), reason: 'pinch over the toolbar zooms the page');
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 10));
    await tester.runAsync(() => tmp.delete(recursive: true));
  });
}

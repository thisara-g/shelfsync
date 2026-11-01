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

void main() {
  testWidgets('selecting text copies it; Ctrl+C copies too and keeps the selection', (tester) async {
    Pdfrx.pdfiumModulePath = File('build/native_assets/linux/libpdfium.so').absolute.path;
    final tmp = await tester.runAsync(() => Directory.systemTemp.createTemp('copy'));
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => tmp!.path,
    );
    final copied = <String>[];
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') copied.add((call.arguments as Map)['text'] as String);
      return null;
    });
    final store = LibraryStore(Directory(p.join(tmp!.path, 'lib')));
    await tester.runAsync(() async {
      await store.load();
      await store.importFile('test/fixtures/sample.pdf');
    });
    final sync = SyncController(_NoAuth());
    await tester.runAsync(sync.start);
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
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
      for (var i = 0; i < 10; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    await settle();
    final controller = tester.widget<PdfViewer>(find.byType(PdfViewer)).controller!;

    // Ctrl+A selects the text, which is copied once the selection settles.
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await settle();
    expect(controller.textSelectionDelegate.hasSelectedText, isTrue);
    expect(copied, isNotEmpty);
    expect(copied.last, contains('Chapter 1: pointer page 1'));

    // A small "Copied" shows in the top-left of the page, below the toolbar.
    double opacity() => tester
        .widget<AnimatedOpacity>(find.ancestor(of: find.text('Copied'), matching: find.byType(AnimatedOpacity)))
        .opacity;
    expect(opacity(), 1);
    final pill = tester.getRect(find.ancestor(of: find.text('Copied'), matching: find.byType(Container)).last);
    final viewer = tester.getRect(find.byType(PdfViewer));
    expect(pill.left, viewer.left + 32);
    expect(pill.height, 40);
    expect(pill.top, greaterThan(40)); // below the toolbar, not on it
    for (var i = 0; i < 20; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(opacity(), 0);

    // Ctrl+C copies again and leaves the selection in place.
    copied.clear();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await settle();
    expect(copied.single, contains('Chapter 1: pointer page 1'));
    expect(controller.textSelectionDelegate.hasSelectedText, isTrue);

    // Esc clears it.
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await settle();
    expect(controller.textSelectionDelegate.hasSelectedText, isFalse);
  });
}

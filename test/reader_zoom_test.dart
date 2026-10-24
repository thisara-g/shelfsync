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
  testWidgets('a chosen zoom survives page turns by arrow down; left/right fit again', (tester) async {
    Pdfrx.pdfiumModulePath = File('build/native_assets/linux/libpdfium.so').absolute.path;
    final tmp = await tester.runAsync(() => Directory.systemTemp.createTemp('z'));
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => tmp!.path,
    );
    final store = LibraryStore(Directory(p.join(tmp!.path, 'lib')));
    await tester.runAsync(() async {
      await store.load();
      await store.importFile('test/fixtures/sample.pdf');
    });
    final sync = SyncController(_NoAuth());
    await tester.runAsync(sync.start);
    final ls = LibrarySync(store: store, sync: sync);
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    await tester.pumpWidget(
      MaterialApp(
        theme: shelfSyncTheme(),
        home: ReaderScreen(store: store, librarySync: ls, book: store.books.single),
      ),
    );
    Future<void> settle() async {
      for (var i = 0; i < 15; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    await settle();
    final viewer = tester.widget<PdfViewer>(find.byType(PdfViewer));
    final c = viewer.controller!;
    final fit = c.currentZoom;
    await tester.tap(find.byTooltip('Zoom in (Ctrl+=)'));
    await settle();
    final zoomed = c.currentZoom;
    expect(zoomed, greaterThan(fit * 1.5));

    // ↓ scrolls down the zoomed page and runs on to page 2, keeping the zoom.
    for (var i = 0; i < 40 && c.pageNumber == 1; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await settle();
    }
    expect(c.pageNumber, 2);
    expect(c.currentZoom, closeTo(zoomed, 0.01));

    // → turns the page and fits it on screen again.
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await settle();
    expect(c.pageNumber, 3);
    expect(c.currentZoom, closeTo(fit, 0.01));

    // Full screen zooms in (half-width bars); ← fits the page again.
    await tester.sendKeyEvent(LogicalKeyboardKey.f11);
    await settle();
    expect(c.currentZoom, greaterThan(fit * 1.05));
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await settle();
    expect(c.pageNumber, 2);
    expect(c.currentZoom, closeTo(fit, 0.01));
    await tester.sendKeyEvent(LogicalKeyboardKey.f11);
    await settle();
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 10));
    await tester.runAsync(() => tmp.delete(recursive: true));
  });

  testWidgets('desktop toolbar hides after a pause and returns at the top edge', (tester) async {
    Pdfrx.pdfiumModulePath = File('build/native_assets/linux/libpdfium.so').absolute.path;
    final tmp = await tester.runAsync(() => Directory.systemTemp.createTemp('z'));
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => tmp!.path,
    );
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
    for (var i = 0; i < 15; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pump(const Duration(milliseconds: 100));
    }
    final zoomIn = find.byTooltip('Zoom in (Ctrl+=)');
    expect(tester.getTopLeft(zoomIn).dy, greaterThanOrEqualTo(0), reason: 'shown at first');

    await tester.pump(const Duration(seconds: 6));
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.getTopLeft(zoomIn).dy, lessThan(0), reason: 'hidden after a pause');

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: const Offset(700, 450));
    await mouse.moveTo(const Offset(700, 10));
    await tester.pump(); // starts the slide-in
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.getTopLeft(zoomIn).dy, greaterThanOrEqualTo(0), reason: 'back at the top edge');

    // Even with the pointer resting on the toolbar, it hides once idle.
    await tester.pump(const Duration(seconds: 6));
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.getTopLeft(zoomIn).dy, lessThan(0), reason: 'hidden when the pointer is idle');
    await mouse.removePointer();

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 10));
    await tester.runAsync(() => tmp.delete(recursive: true));
  });

  testWidgets('scrolling while the book opens still hides the bars and saves the position', (tester) async {
    Pdfrx.pdfiumModulePath = File('build/native_assets/linux/libpdfium.so').absolute.path;
    final tmp = await tester.runAsync(() => Directory.systemTemp.createTemp('z'));
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => tmp!.path,
    );
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
    // Keep wheel-scrolling from the start, so some scrolls land while the
    // opening "fit the page" animation runs and cancel it.
    for (var i = 0; i < 30; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
      tester.binding.handlePointerEvent(
        const PointerScrollEvent(
          position: Offset(700, 450),
          scrollDelta: Offset(0, 120),
          kind: PointerDeviceKind.mouse,
        ),
      );
      await tester.pump(const Duration(milliseconds: 30));
    }
    await tester.pump(const Duration(seconds: 6));
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.getTopLeft(find.byTooltip('Zoom in (Ctrl+=)')).dy, lessThan(0), reason: 'bars hidden');
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
    expect(store.books.single.lastPage, greaterThan(1), reason: 'scrolled position saved');

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 10));
    await tester.runAsync(() => tmp.delete(recursive: true));
  });
}

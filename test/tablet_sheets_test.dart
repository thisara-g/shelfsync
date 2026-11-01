import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:pdfrx/pdfrx.dart';
import 'package:shelfsync/screens/common.dart';
import 'package:shelfsync/screens/library_screen.dart';
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

/// The tablet library at tablet size, with two books.
Future<LibraryStore> _pumpTablet(WidgetTester tester) async {
  debugTouchLayout = true;
  addTearDown(() => debugTouchLayout = false);
  Pdfrx.pdfiumModulePath = File('build/native_assets/linux/libpdfium.so').absolute.path;
  final tmp = await tester.runAsync(() => Directory.systemTemp.createTemp('sheets'));
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
    const MethodChannel('plugins.flutter.io/path_provider'),
    (call) async => tmp!.path,
  );
  final store = LibraryStore(Directory(p.join(tmp!.path, 'lib')));
  await tester.runAsync(() async {
    await store.load();
    await store.importFile('test/fixtures/sample.pdf');
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
      home: LibraryScreen(store: store, sync: sync, librarySync: LibrarySync(store: store, sync: sync)),
    ),
  );
  await _settle(tester);
  return store;
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Finder _button(String label) => find.widgetWithText(TealButton, label);

void main() {
  testWidgets('create, edit, delete (with undo) a shelf from its sheets', (tester) async {
    final store = await _pumpTablet(tester);

    // Create shelf: the dashed card opens the sheet with a live preview.
    await tester.tap(find.text('Create shelf').first);
    await _settle(tester);
    expect(find.text('Preview'.toUpperCase()), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'Exam prep');
    await _settle(tester);
    expect(find.text('Exam prep'), findsWidgets); // the preview card follows the name
    await tester.tap(_button('Create shelf'));
    await _settle(tester);
    expect(store.shelves.single.name, 'Exam prep');
    await tester.tap(find.byTooltip('Back to library'));
    await _settle(tester);

    // Long-press the shelf: Edit shelf, name pre-filled.
    await tester.longPress(find.text('Exam prep'));
    await _settle(tester);
    expect(find.text('Edit shelf'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'Revision');
    await tester.tap(_button('Save'));
    await _settle(tester);
    expect(store.shelves.single.name, 'Revision');

    // Delete from the edit sheet, then Undo brings it back.
    await tester.longPress(find.text('Revision'));
    await _settle(tester);
    await tester.tap(find.text('Delete shelf…'));
    await _settle(tester);
    expect(find.text('Delete the “Revision” shelf?'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Delete shelf'));
    await _settle(tester);
    expect(store.shelves, isEmpty);
    await tester.tap(find.text('Undo'));
    await _settle(tester);
    expect(store.shelves.single.name, 'Revision');
  });

  testWidgets('rename a book from its sheet', (tester) async {
    final store = await _pumpTablet(tester);
    final book = store.books.first;
    final tile = find.byWidgetPredicate(
      (w) => w.runtimeType.toString() == '_GridTile' && (w as dynamic).book.id == book.id,
    );
    await tester.longPress(tile);
    await _settle(tester);
    await tester.tap(find.text('Rename'));
    await _settle(tester);
    expect(find.text('Rename book'), findsOneWidget);
    expect(find.text('File: ${book.fileName}'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'My renamed book');
    await tester.tap(_button('Rename'));
    await _settle(tester);
    expect(store.byId(book.id)!.title, 'My renamed book');
  });
}

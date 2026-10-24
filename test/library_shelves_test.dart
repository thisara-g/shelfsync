import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:pdfrx/pdfrx.dart';
import 'package:shelfsync/models/shelf.dart';
import 'package:shelfsync/screens/common.dart';
import 'package:shelfsync/screens/library_screen.dart';
import 'package:shelfsync/services/library_store.dart';
import 'package:shelfsync/sync/drive_service.dart';
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

class _SignedInAuth implements GoogleAuth {
  @override
  bool get isConfigured => true;
  @override
  Future<http.Client?> restore() async => http.Client();
  @override
  Future<http.Client> signIn() async => http.Client();
  @override
  Future<void> signOut() async {}
}

/// Just enough of Drive to be signed in as "Reader".
class _FakeDrive implements DriveService {
  @override
  http.Client get client => http.Client();
  @override
  Future<DriveAccount> account() async => const DriveAccount(email: 'reader@example.com', displayName: 'Reader');
  @override
  Future<String> ensureLibraryFolder() async => 'folder-1';
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError('$invocation');
}

/// The desktop library with two books, on a Linux-sized window.
Future<LibraryStore> _pumpLibrary(WidgetTester tester, {bool signedIn = false}) async {
  Pdfrx.pdfiumModulePath = File('build/native_assets/linux/libpdfium.so').absolute.path;
  final tmp = await tester.runAsync(() => Directory.systemTemp.createTemp('shelves'));
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
  final sync = signedIn
      ? SyncController(_SignedInAuth(), driveFactory: (_) => _FakeDrive())
      : SyncController(_NoAuth());
  await tester.runAsync(sync.start);
  tester.view.physicalSize = const Size(1400, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: shelfSyncTheme(),
      home: LibraryScreen(
        store: store,
        sync: sync,
        librarySync: LibrarySync(store: store, sync: sync),
      ),
    ),
  );
  await _settle(tester);
  return store;
}

/// Lets real file writes finish between frames.
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Finder _tile(String title) =>
    find.byWidgetPredicate((w) => w.runtimeType.toString() == '_DesktopTile' && (w as dynamic).book.title == title);

void main() {
  testWidgets('+ Create shelf opens an inline form in the sidebar', (tester) async {
    final store = await _pumpLibrary(tester);
    await tester.tap(find.text('+ Create shelf'));
    await _settle(tester);
    expect(find.text('Enter to create · Esc to cancel'), findsOneWidget);
    expect(find.text('+ Create shelf'), findsNothing);

    // Esc cancels.
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await _settle(tester);
    expect(find.text('+ Create shelf'), findsOneWidget);

    // Name, pick purple, Enter.
    await tester.tap(find.text('+ Create shelf'));
    await _settle(tester);
    await tester.enterText(
      find.ancestor(of: find.text('Shelf name'), matching: find.byType(TextField)),
      'Research papers',
    );
    await tester.tap(find.bySemanticsLabel('Purple'));
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await _settle(tester);
    final shelf = store.shelves.single;
    expect(shelf.name, 'Research papers');
    expect(shelfColors[shelf.color], 0xFFAB47BC);

    // The new shelf opens, with its own header.
    expect(find.text('0 books'), findsOneWidget);
    expect(find.text('Rename shelf'), findsOneWidget);
    expect(find.text('Add books'), findsOneWidget);
  });

  testWidgets('right-click → Add to shelf toggles the book on a shelf', (tester) async {
    final store = await _pumpLibrary(tester);
    final shelf = await tester.runAsync(() => store.createShelf('Textbooks'));
    await _settle(tester);
    final title = store.books.first.title;

    await tester.tap(_tile(title), buttons: kSecondaryButton);
    await _settle(tester);
    expect(find.text('Open'), findsOneWidget);
    expect(find.text('Rename'), findsOneWidget);
    await tester.tap(find.text('Add to shelf'));
    await _settle(tester);
    expect(find.text('+ Create shelf…'), findsOneWidget);

    await tester.tap(find.text('Textbooks').last);
    await _settle(tester);
    expect(shelf!.bookIds, {store.books.first.id});
    // The submenu stays open and now shows the tick.
    expect(find.text('✓'), findsOneWidget);
  });

  testWidgets('a shelf page adds books from the "Add books" picker', (tester) async {
    final store = await _pumpLibrary(tester);
    final [first, second] = store.books;
    final shelf = await tester.runAsync(() async {
      final s = await store.createShelf('Textbooks');
      await store.setOnShelf(s.id, first.id, true);
      return s;
    });
    await _settle(tester);
    await tester.tap(find.text('Textbooks'));
    await _settle(tester);
    expect(find.text('1 book'), findsOneWidget);

    await tester.tap(find.text('Add books'));
    await _settle(tester);
    expect(find.text('Add books to Textbooks'), findsOneWidget);
    expect(find.text('Already on this shelf'), findsOneWidget);
    expect(find.text('0 selected'), findsOneWidget);

    await tester.tap(find.descendant(of: find.byType(Dialog), matching: find.text(second.title)));
    await _settle(tester);
    expect(find.text('1 selected'), findsOneWidget);
    await tester.tap(find.text('Add 1 book'));
    await _settle(tester);
    expect(shelf!.bookIds, {first.id, second.id});
    expect(find.text('2 books'), findsOneWidget);
  });

  testWidgets('Ctrl-click picks several books; dragging one moves all onto a shelf', (tester) async {
    final store = await _pumpLibrary(tester);
    final shelf = await tester.runAsync(() => store.createShelf('Novels'));
    await _settle(tester);
    final [a, b] = store.books;

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.tap(_tile(a.title));
    await tester.tap(_tile(b.title));
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await _settle(tester);
    expect(find.text('2 selected · drag either cover to move both'), findsOneWidget);

    final gesture = await tester.startGesture(tester.getCenter(_tile(a.title)), kind: PointerDeviceKind.mouse);
    await tester.pump(const Duration(milliseconds: 50));
    await gesture.moveBy(const Offset(-30, 10));
    await tester.pump();
    await gesture.moveTo(tester.getCenter(find.text('Novels')));
    await tester.pump();
    expect(find.text('Drop to add'), findsOneWidget);
    await gesture.up();
    await _settle(tester);
    expect(shelf!.bookIds, {a.id, b.id});
    expect(find.textContaining('selected ·'), findsNothing);
  });

  testWidgets('Esc clears a selection', (tester) async {
    final store = await _pumpLibrary(tester);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.tap(_tile(store.books.first.title));
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await _settle(tester);
    expect(find.text('1 selected · drag it onto a shelf'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await _settle(tester);
    expect(find.textContaining('selected ·'), findsNothing);
  });

  testWidgets('Esc closes the Create shelf form after a dialog; switching shelves closes it', (tester) async {
    final store = await _pumpLibrary(tester);
    await tester.runAsync(() => store.createShelf('Textbooks'));
    await _settle(tester);
    await tester.tap(find.text('+ Create shelf'));
    await _settle(tester);

    // Open another shelf's "Add books" dialog meanwhile... (opening the shelf
    // closes the form, so reopen it there), cancel it, then press Esc.
    await tester.tap(find.text('Textbooks'));
    await _settle(tester);
    expect(find.text('+ Create shelf'), findsOneWidget);
    await tester.tap(find.text('+ Create shelf'));
    await _settle(tester);
    await tester.tap(find.text('Add books'));
    await _settle(tester);
    await tester.tap(find.text('Cancel'));
    await _settle(tester);
    expect(find.text('Enter to create · Esc to cancel'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await _settle(tester);
    expect(find.text('+ Create shelf'), findsOneWidget);
    expect(store.shelves, hasLength(1));
  });

  testWidgets('Rename book: a suggestion fills the title, Rename saves it', (tester) async {
    final store = await _pumpLibrary(tester);
    final book = store.books.firstWhere((b) => b.fileName == 'six_pages.pdf');

    await tester.tap(_tile(book.title), buttons: kSecondaryButton);
    await _settle(tester);
    await tester.tap(find.text('Rename'));
    await _settle(tester);
    expect(find.text('Rename book'), findsOneWidget);
    expect(find.text('F2 renames the selected book'), findsOneWidget);
    // "Six pages" from the file name; every-word capitals is the suggestion.
    await tester.tap(find.text('Six Pages'));
    await _settle(tester);
    await tester.tap(find.widgetWithText(FilledButton, 'Rename'));
    await _settle(tester);
    expect(book.title, 'Six Pages');
  });

  testWidgets('F2 on a focused book opens Rename book', (tester) async {
    final store = await _pumpLibrary(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await _settle(tester);
    // Tab lands on the first focusable thing; walk until a book has focus.
    for (var i = 0; i < 30 && find.text('Rename book').evaluate().isEmpty; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.f2);
      await _settle(tester);
      if (find.text('Rename book').evaluate().isEmpty) {
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await _settle(tester);
      }
    }
    expect(find.text('Rename book'), findsOneWidget);
    expect(store.books, hasLength(2));
  });

  testWidgets('double-clicking a shelf edits its name and colour in place', (tester) async {
    final store = await _pumpLibrary(tester);
    final shelf = (await tester.runAsync(() => store.createShelf('Novels', color: 1)))!;
    await _settle(tester);

    await tester.tap(find.text('Novels'));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(find.text('Novels').first);
    await _settle(tester);
    expect(find.text('Enter to save · Esc to cancel'), findsOneWidget);
    expect(find.text('Delete shelf…'), findsOneWidget);

    await tester.enterText(find.ancestor(of: find.text('Novels'), matching: find.byType(TextField)), 'Fiction');
    await tester.tap(find.bySemanticsLabel('Pink'));
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await _settle(tester);
    expect((shelf.name, shelf.color), ('Fiction', 7));
    expect(find.text('Enter to save · Esc to cancel'), findsNothing);
  });

  testWidgets('Rename shelf (or F2) on a shelf page opens the same form; Esc cancels', (tester) async {
    final store = await _pumpLibrary(tester);
    final shelf = (await tester.runAsync(() => store.createShelf('Novels')))!;
    await _settle(tester);
    await tester.tap(find.text('Novels'));
    await _settle(tester);

    await tester.tap(find.text('Rename shelf'));
    await _settle(tester);
    expect(find.text('Enter to save · Esc to cancel'), findsOneWidget);
    // The button stays lit (teal on mint) while the form is open.
    final button = tester.widget<OutlinedButton>(find.widgetWithText(OutlinedButton, 'Rename shelf'));
    expect(button.style!.backgroundColor!.resolve({}), const Color(0xFFE0F2F1));
    expect(button.style!.side!.resolve({}), const BorderSide(color: Color(0xFF00897B), width: 2));
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await _settle(tester);
    expect(find.text('Enter to save · Esc to cancel'), findsNothing);
    expect(shelf.name, 'Novels');

    await tester.sendKeyEvent(LogicalKeyboardKey.f2);
    await _settle(tester);
    expect(find.text('Enter to save · Esc to cancel'), findsOneWidget);
  });

  testWidgets('Sort menu: current order ticked, each explained, lined up under the button', (tester) async {
    await _pumpLibrary(tester);
    final button = find.text('Sort: Recently read').last;
    expect(button, findsOneWidget);

    await tester.tap(button);
    await _settle(tester);
    expect(find.text('Sort: Recently read').last, findsOneWidget);
    expect(find.text('SORT BY'), findsOneWidget);
    expect(find.text('Last opened on any of your devices'), findsOneWidget);
    expect(find.text('A to Z'), findsOneWidget);
    expect(find.text('Newest first'), findsOneWidget);
    expect(find.text('✓'), findsOneWidget);

    // Right edges line up; the menu starts 8px below the button.
    final buttonBox = tester.getRect(
      find.ancestor(of: find.text('Sort: Recently read').last, matching: find.byType(InkWell)).first,
    );
    final menuBox = tester.getRect(find.ancestor(of: find.text('SORT BY'), matching: find.byType(Material)).first);
    // The arrow flips up and sits at the button's right edge.
    final arrow = tester.getRect(find.byIcon(Icons.keyboard_arrow_up_rounded));
    expect(arrow.right, closeTo(buttonBox.right - 11, 1));
    expect(arrow.center.dy, closeTo(buttonBox.center.dy, 0.5));
    expect(menuBox.width, 280);
    expect(menuBox.right, closeTo(buttonBox.right, 1));
    expect(menuBox.top, greaterThan(buttonBox.bottom));

    await tester.tap(find.text('Title'));
    await _settle(tester);
    expect(find.text('Sort: Title').last, findsOneWidget);
    expect(find.byIcon(Icons.keyboard_arrow_down_rounded), findsOneWidget);
    // The button keeps one width, that of the longest order.
    final titleBox = tester.getRect(
      find.ancestor(of: find.text('Sort: Title').last, matching: find.byType(InkWell)).first,
    );
    expect(titleBox.width, closeTo(buttonBox.width, 2.5));
    expect(find.text('SORT BY'), findsNothing);
  });

  testWidgets('account panel opens above the sidebar card with account, Drive use and devices', (tester) async {
    final store = await _pumpLibrary(tester, signedIn: true);
    final book = store.books.first;
    await tester.runAsync(() async {
      await store.setDriveFileId(book.id, 'file-1');
      await store.applyRemoteProgress(
        book.id,
        page: 2,
        pageOffset: null,
        updatedAt: DateTime.now().subtract(const Duration(hours: 2)),
        device: 'Galaxy Tab',
      );
    });
    await _settle(tester);

    final card = tester.getRect(find.ancestor(of: find.text('Reader'), matching: find.byType(InkWell)).first);
    await tester.tap(find.text('Reader'));
    await _settle(tester);

    expect(find.text('reader@example.com'), findsOneWidget);
    expect(find.textContaining('Synced'), findsWidgets);
    expect(find.textContaining('1 book · '), findsOneWidget);
    expect(find.textContaining('in your Google Drive'), findsOneWidget);
    expect(find.text('Sync now'), findsOneWidget);
    expect(find.text('Open in Drive'), findsOneWidget);
    expect(find.byIcon(Icons.north_east_rounded), findsOneWidget);
    expect(find.text('YOUR DEVICES'), findsOneWidget);
    expect(find.text('This PC'), findsOneWidget);
    expect(find.text('Galaxy Tab'), findsOneWidget);
    expect(find.text('Read ${book.title} · ${timeAgo(book.progressUpdatedAt!)}'), findsOneWidget);
    expect(find.text('Signing out keeps your books on this PC and in Drive.'), findsOneWidget);

    // Same left edge as the card, 16px above it, 360 wide.
    final panel = tester.getRect(
      find.ancestor(of: find.text('reader@example.com'), matching: find.byType(Material)).first,
    );
    expect(panel.left, card.left);
    expect(panel.bottom, closeTo(card.top - 16, 0.5));
    expect(panel.width, 360);

    // A click outside closes it.
    await tester.tapAt(const Offset(900, 450));
    await _settle(tester);
    expect(find.text('YOUR DEVICES'), findsNothing);

    // Sign out closes the panel and signs out.
    await tester.tap(find.text('Reader'));
    await _settle(tester);
    await tester.tap(find.text('Sign out'));
    await _settle(tester);
    expect(find.text('YOUR DEVICES'), findsNothing);
    expect(find.text('Sign in to sync'), findsOneWidget);
  });

  testWidgets('without a Google client the account panel says sync is not set up', (tester) async {
    await _pumpLibrary(tester);
    await tester.tap(find.text('Sync not set up'));
    await _settle(tester);
    expect(find.text('Google Drive sync is not set up'), findsOneWidget);
    expect(find.text('Sign out'), findsNothing);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await _settle(tester);
    expect(find.text('Google Drive sync is not set up'), findsNothing);
  });
}

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import 'screens/library_screen.dart';
import 'services/library_store.dart';
import 'sync/google_auth.dart';
import 'sync/library_sync.dart';
import 'sync/oauth_config.dart';
import 'sync/sync_controller.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final supportDir = Directory((await getApplicationSupportDirectory()).path);
  final store = LibraryStore(supportDir);
  await store.load();

  final auth = GoogleAuth.create(dataDir: supportDir, config: await OAuthConfig.load());
  final sync = SyncController(auth);
  final librarySync = LibrarySync(store: store, sync: sync)..start();
  sync.start();

  runApp(ShelfSyncApp(store: store, sync: sync, librarySync: librarySync));
}

class ShelfSyncApp extends StatelessWidget {
  const ShelfSyncApp({super.key, required this.store, required this.sync, required this.librarySync});

  final LibraryStore store;
  final SyncController sync;
  final LibrarySync librarySync;

  @override
  Widget build(BuildContext context) {
    const seed = Colors.teal;
    return MaterialApp(
      title: 'ShelfSync',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorSchemeSeed: seed),
      darkTheme: ThemeData(colorSchemeSeed: seed, brightness: Brightness.dark),
      home: _SyncOnResume(
        librarySync: librarySync,
        child: LibraryScreen(store: store, sync: sync, librarySync: librarySync),
      ),
    );
  }
}

/// Syncs whenever the app comes back to the foreground, so a book added on the
/// other device shows up without a manual refresh.
class _SyncOnResume extends StatefulWidget {
  const _SyncOnResume({required this.librarySync, required this.child});

  final LibrarySync librarySync;
  final Widget child;

  @override
  State<_SyncOnResume> createState() => _SyncOnResumeState();
}

class _SyncOnResumeState extends State<_SyncOnResume> {
  late final AppLifecycleListener _listener;

  @override
  void initState() {
    super.initState();
    _listener = AppLifecycleListener(onResume: widget.librarySync.syncNow);
  }

  @override
  void dispose() {
    _listener.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

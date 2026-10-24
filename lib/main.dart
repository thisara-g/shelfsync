import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import 'screens/common.dart';
import 'screens/library_screen.dart';
import 'screens/welcome_screen.dart';
import 'services/library_store.dart';
import 'sync/google_auth.dart';
import 'sync/library_sync.dart';
import 'sync/oauth_config.dart';
import 'sync/sync_controller.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  LicenseRegistry.addLicense(() async* {
    for (final font in ['Figtree', 'Literata']) {
      yield LicenseEntryWithLineBreaks([font], await rootBundle.loadString('assets/fonts/$font-OFL.txt'));
    }
  });
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
    return MaterialApp(
      title: 'ShelfSync',
      debugShowCheckedModeBanner: false,
      theme: shelfSyncTheme(),
      home: _SyncOnResume(
        librarySync: librarySync,
        child: ListenableBuilder(
          listenable: store,
          builder: (context, _) => store.welcomeDone
              ? LibraryScreen(store: store, sync: sync, librarySync: librarySync)
              : WelcomeScreen(store: store, sync: sync),
        ),
      ),
    );
  }
}

/// Syncs whenever the app comes back to the foreground, so a book or reading
/// position from the other device shows up without a manual refresh.
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
    _listener = AppLifecycleListener(
      onResume: widget.librarySync.syncNow,
      // Push the latest reading position before the OS may suspend or kill us.
      onHide: widget.librarySync.flushProgress,
    );
  }

  @override
  void dispose() {
    _listener.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

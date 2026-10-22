import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import 'screens/library_screen.dart';
import 'services/library_store.dart';
import 'sync/google_auth.dart';
import 'sync/oauth_config.dart';
import 'sync/sync_controller.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final supportDir = Directory((await getApplicationSupportDirectory()).path);
  final store = LibraryStore(supportDir);
  await store.load();

  final auth = GoogleAuth.create(dataDir: supportDir, config: await OAuthConfig.load());
  final sync = SyncController(auth)..start();

  runApp(ShelfSyncApp(store: store, sync: sync));
}

class ShelfSyncApp extends StatelessWidget {
  const ShelfSyncApp({super.key, required this.store, required this.sync});

  final LibraryStore store;
  final SyncController sync;

  @override
  Widget build(BuildContext context) {
    const seed = Colors.teal;
    return MaterialApp(
      title: 'ShelfSync',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorSchemeSeed: seed),
      darkTheme: ThemeData(colorSchemeSeed: seed, brightness: Brightness.dark),
      home: LibraryScreen(store: store, sync: sync),
    );
  }
}

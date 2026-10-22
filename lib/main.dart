import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import 'screens/library_screen.dart';
import 'services/library_store.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final supportDir = await getApplicationSupportDirectory();
  final store = LibraryStore(Directory(supportDir.path));
  await store.load();
  runApp(ShelfSyncApp(store: store));
}

class ShelfSyncApp extends StatelessWidget {
  const ShelfSyncApp({super.key, required this.store});

  final LibraryStore store;

  @override
  Widget build(BuildContext context) {
    const seed = Colors.teal;
    return MaterialApp(
      title: 'ShelfSync',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorSchemeSeed: seed),
      darkTheme: ThemeData(colorSchemeSeed: seed, brightness: Brightness.dark),
      home: LibraryScreen(store: store),
    );
  }
}

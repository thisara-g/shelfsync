import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/library_store.dart';
import '../sync/sync_controller.dart';
import 'common.dart';

final _privacyUrl = Uri.parse('https://thisara-g.github.io/shelfsync/privacy.html');

/// First-run screen: what ShelfSync does, and Google sign-in or skip.
class WelcomeScreen extends StatelessWidget {
  const WelcomeScreen({super.key, required this.store, required this.sync});

  final LibraryStore store;
  final SyncController sync;

  static const _background = Color(0xFF182024);
  static const _card = Color(0xFF202A2E);
  static const _muted = Color(0xFFA9B8B4);
  static const _accent = Color(0xFF00897B);

  Future<void> _signIn() async {
    await store.setWelcomeDone();
    await sync.signIn();
  }

  @override
  Widget build(BuildContext context) {
    final canSync = sync.status != SyncStatus.notConfigured;
    return Theme(
      data: ThemeData(colorSchemeSeed: _accent, brightness: Brightness.dark),
      child: Scaffold(
        backgroundColor: _background,
        body: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 48),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 560),
                child: Column(
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(28),
                      child: Image.asset('assets/icons/shelfsync.png', width: 112, height: 112),
                    ),
                    const SizedBox(height: 28),
                    const Text(
                      'Your books, on every screen',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontFamily: serifFamily,
                        fontSize: 40,
                        fontWeight: FontWeight.w600,
                        height: 1.15,
                        color: Color(0xFFECF1EF),
                      ),
                    ),
                    const SizedBox(height: 16),
                    const Text(
                      'Start a chapter on your PC, finish it on your tablet. '
                      'ShelfSync remembers exactly where you stopped.',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 18, height: 1.5, color: _muted),
                    ),
                    const SizedBox(height: 40),
                    const _Feature(
                      icon: Icons.add,
                      title: 'Add a PDF once',
                      text: 'It appears on all your devices automatically.',
                    ),
                    const _Feature(
                      icon: Icons.bookmark_outline,
                      title: 'Pick up mid-page',
                      text: 'Page, scroll position and zoom follow you.',
                    ),
                    const _Feature(
                      icon: Icons.lock_outline,
                      title: 'Stays in your Google Drive',
                      text: 'No ShelfSync servers. It can only see its own files.',
                    ),
                    const SizedBox(height: 40),
                    if (canSync)
                      SizedBox(
                        width: double.infinity,
                        height: 58,
                        child: FilledButton.icon(
                          style: FilledButton.styleFrom(
                            backgroundColor: _accent,
                            foregroundColor: Colors.white,
                            textStyle: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
                          ),
                          onPressed: _signIn,
                          icon: const Icon(Icons.login),
                          label: const Text('Continue with Google'),
                        ),
                      ),
                    const SizedBox(height: 12),
                    TextButton(
                      style: TextButton.styleFrom(foregroundColor: _muted, textStyle: const TextStyle(fontSize: 16)),
                      onPressed: store.setWelcomeDone,
                      child: Text(canSync ? 'Just read on this device for now' : 'Get started'),
                    ),
                    if (canSync) ...[
                      const SizedBox(height: 8),
                      TextButton(
                        style: TextButton.styleFrom(foregroundColor: const Color(0xFF80CBC4)),
                        onPressed: () => launchUrl(_privacyUrl, mode: LaunchMode.externalApplication),
                        child: const Text('Privacy policy'),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Feature extends StatelessWidget {
  const _Feature({required this.icon, required this.title, required this.text});

  final IconData icon;
  final String title;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
      decoration: BoxDecoration(color: WelcomeScreen._card, borderRadius: BorderRadius.circular(16)),
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(color: const Color(0xFF1F3B38), borderRadius: BorderRadius.circular(12)),
            child: Icon(icon, color: const Color(0xFF4DB6AC)),
          ),
          const SizedBox(width: 18),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600, color: Color(0xFFECF1EF))),
                const SizedBox(height: 2),
                Text(text, style: const TextStyle(fontSize: 15, color: WelcomeScreen._muted)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

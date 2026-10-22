import 'dart:convert';

import 'package:flutter/services.dart';

/// Per-user Google OAuth client settings, read from the bundled asset
/// `config/google_oauth.json` (written by `./setup`, never committed).
///
/// Android needs no client id in code: Google matches the app's package name
/// and signing-key SHA-1 to the Android OAuth client in the same project.
class OAuthConfig {
  const OAuthConfig({required this.desktopClientId, required this.desktopClientSecret});

  final String desktopClientId;
  final String desktopClientSecret;

  static const assetPath = 'config/google_oauth.json';

  /// Null when the file is missing or still has placeholder values.
  static Future<OAuthConfig?> load() async {
    try {
      final json = jsonDecode(await rootBundle.loadString(assetPath)) as Map<String, dynamic>;
      final desktop = json['desktop'] as Map<String, dynamic>;
      final id = desktop['client_id'] as String;
      final secret = desktop['client_secret'] as String;
      if (!id.endsWith('.apps.googleusercontent.com') || id.startsWith('YOUR_')) return null;
      return OAuthConfig(desktopClientId: id, desktopClientSecret: secret);
    } catch (_) {
      return null;
    }
  }
}

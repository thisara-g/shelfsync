import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:google_sign_in/google_sign_in.dart';
import 'package:googleapis/drive/v3.dart' show DriveApi;
import 'package:googleapis_auth/auth_io.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:url_launcher/url_launcher.dart';

import 'oauth_config.dart';

/// Non-sensitive scopes: files this app created, plus the hidden app-data folder.
const driveScopes = [DriveApi.driveFileScope, DriveApi.driveAppdataScope];

/// Platform-specific Google sign-in that yields an authenticated HTTP client.
abstract class GoogleAuth {
  /// Linux uses the OAuth loopback flow; Android uses Google Play services.
  static GoogleAuth create({required Directory dataDir, required OAuthConfig? config}) {
    if (Platform.isAndroid) return AndroidGoogleAuth();
    return DesktopGoogleAuth(dataDir: dataDir, config: config);
  }

  /// False if this build has no OAuth client configured (run `./setup`).
  bool get isConfigured;

  /// Returns a client using a previous sign-in without any UI, or null.
  Future<http.Client?> restore();

  /// Interactive sign-in: account picker on Android, the browser on Linux.
  Future<http.Client> signIn();

  /// Revokes access so the next sign-in asks for consent again.
  Future<void> signOut();
}

Future<void> _revoke(String token) async {
  try {
    await http.post(Uri.parse('https://oauth2.googleapis.com/revoke'), body: {'token': token});
  } catch (_) {
    // Offline: forgetting the local credentials is still a sign-out.
  }
}

/// Linux/desktop: authorization-code flow with PKCE and a loopback redirect,
/// with the refresh token stored in the app's data directory.
class DesktopGoogleAuth implements GoogleAuth {
  DesktopGoogleAuth({required Directory dataDir, required this.config})
      : _credentialsFile = File(p.join(dataDir.path, 'google_credentials.json'));

  final OAuthConfig? config;
  final File _credentialsFile;
  AutoRefreshingAuthClient? _client;
  StreamSubscription<AccessCredentials>? _updates;

  @override
  bool get isConfigured => config != null;

  ClientId get _clientId => ClientId(config!.desktopClientId, config!.desktopClientSecret);

  @override
  Future<http.Client?> restore() async {
    if (!isConfigured || !await _credentialsFile.exists()) return null;
    try {
      final json = jsonDecode(await _credentialsFile.readAsString()) as Map<String, dynamic>;
      final credentials = AccessCredentials.fromJson(json);
      if (credentials.refreshToken == null) return null;
      return _adopt(autoRefreshingClient(_clientId, credentials, http.Client()));
    } catch (_) {
      return null;
    }
  }

  @override
  Future<http.Client> signIn() async {
    if (!isConfigured) throw StateError('Google OAuth is not configured. Run ./setup first.');
    final client = await clientViaUserConsent(_clientId, driveScopes, (url) {
      launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
    });
    if (client.credentials.refreshToken == null) {
      // Google only issues a refresh token on first consent; revoke the stale
      // grant so the next attempt gets a fresh one.
      await _revoke(client.credentials.accessToken.data);
      client.close();
      throw StateError('Google did not return a refresh token. Please sign in again.');
    }
    await _save(client.credentials);
    return _adopt(client);
  }

  @override
  Future<void> signOut() async {
    final credentials = _client?.credentials;
    await _updates?.cancel();
    _client?.close();
    _client = null;
    if (credentials != null) await _revoke(credentials.refreshToken ?? credentials.accessToken.data);
    if (await _credentialsFile.exists()) await _credentialsFile.delete();
  }

  http.Client _adopt(AutoRefreshingAuthClient client) {
    _updates?.cancel();
    _client = client;
    _updates = client.credentialUpdates.listen(_save);
    return client;
  }

  Future<void> _save(AccessCredentials credentials) async {
    await _credentialsFile.parent.create(recursive: true);
    final tmp = File('${_credentialsFile.path}.tmp');
    await tmp.writeAsString(jsonEncode(credentials.toJson()), flush: true);
    if (!Platform.isWindows) await Process.run('chmod', ['600', tmp.path]);
    await tmp.rename(_credentialsFile.path);
  }
}

/// Android: authorization through Google Play services. Play services keeps
/// the grant, so nothing is stored by the app.
class AndroidGoogleAuth implements GoogleAuth {
  final _signIn = GoogleSignIn.instance;
  Future<void>? _initialized;

  @override
  bool get isConfigured => true;

  Future<void> _init() => _initialized ??= _signIn.initialize();

  Future<String?> _token({required bool interactive}) async {
    await _init();
    final client = _signIn.authorizationClient;
    final authz = interactive
        ? await client.authorizeScopes(driveScopes)
        : await client.authorizationForScopes(driveScopes);
    return authz?.accessToken;
  }

  @override
  Future<http.Client?> restore() async {
    try {
      final token = await _token(interactive: false);
      return token == null ? null : _PlayServicesClient(this, token);
    } catch (_) {
      return null;
    }
  }

  @override
  Future<http.Client> signIn() async {
    final token = await _token(interactive: true);
    if (token == null) throw StateError('Google sign-in was cancelled.');
    return _PlayServicesClient(this, token);
  }

  @override
  Future<void> signOut() async {
    await _init();
    final token = await _token(interactive: false).catchError((_) => null);
    if (token != null) {
      await _revoke(token);
      await _signIn.authorizationClient.clearAuthorizationToken(accessToken: token);
    }
    await _signIn.signOut();
  }
}

/// Adds the bearer token, refreshing it from Play services before it expires
/// (tokens last an hour) or after the server rejects it.
class _PlayServicesClient extends http.BaseClient {
  _PlayServicesClient(this._auth, this._token) : _issued = DateTime.now();

  final AndroidGoogleAuth _auth;
  final http.Client _inner = http.Client();
  String _token;
  DateTime _issued;
  bool _stale = false;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (_stale || DateTime.now().difference(_issued) > const Duration(minutes: 45)) {
      if (_stale) {
        await _auth._signIn.authorizationClient.clearAuthorizationToken(accessToken: _token);
      }
      final fresh = await _auth._token(interactive: false);
      if (fresh == null) throw StateError('Google access was revoked. Please sign in again.');
      _token = fresh;
      _issued = DateTime.now();
      _stale = false;
    }
    request.headers['Authorization'] = 'Bearer $_token';
    final response = await _inner.send(request);
    if (response.statusCode == 401) _stale = true;
    return response;
  }

  @override
  void close() => _inner.close();
}

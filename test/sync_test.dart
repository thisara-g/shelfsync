import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shelfsync/sync/drive_service.dart';
import 'package:shelfsync/sync/google_auth.dart';
import 'package:shelfsync/sync/sync_controller.dart';

/// Minimal fake of the Drive v3 endpoints used in stage 2.
class FakeDrive {
  final folders = <Map<String, Object>>[];
  var creates = 0;

  http.Client client() => MockClient((request) async {
        final path = request.url.path;
        if (path.endsWith('/about')) {
          return _json({'user': {'displayName': 'Test User', 'emailAddress': 'test@example.com'}});
        }
        if (path.endsWith('/files') && request.method == 'GET') {
          expect(request.url.queryParameters['q'], contains("name = 'ShelfSync'"));
          return _json({'files': folders});
        }
        if (path.endsWith('/files') && request.method == 'POST') {
          creates++;
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          expect(body['name'], 'ShelfSync');
          expect(body['mimeType'], 'application/vnd.google-apps.folder');
          final folder = {'id': 'folder-${folders.length + 1}'};
          folders.add(folder);
          return _json(folder);
        }
        return http.Response('unexpected ${request.method} $path', 500);
      });

  static http.Response _json(Object body) =>
      http.Response(jsonEncode(body), 200, headers: {'content-type': 'application/json'});
}

class FakeAuth implements GoogleAuth {
  FakeAuth(this.drive, {this.previouslySignedIn = false});

  final FakeDrive drive;
  bool previouslySignedIn;
  var signOuts = 0;

  @override
  bool get isConfigured => true;

  @override
  Future<http.Client?> restore() async => previouslySignedIn ? drive.client() : null;

  @override
  Future<http.Client> signIn() async {
    previouslySignedIn = true;
    return drive.client();
  }

  @override
  Future<void> signOut() async {
    previouslySignedIn = false;
    signOuts++;
  }
}

void main() {
  test('creates the ShelfSync folder on first sign-in', () async {
    final drive = FakeDrive();
    final id = await DriveService(drive.client()).ensureLibraryFolder();
    expect(id, 'folder-1');
    expect(drive.creates, 1);
  });

  test('reuses the existing folder (oldest first) instead of creating another', () async {
    final drive = FakeDrive()
      ..folders.addAll([
        {'id': 'oldest'},
        {'id': 'newer'},
      ]);
    expect(await DriveService(drive.client()).ensureLibraryFolder(), 'oldest');
    expect(drive.creates, 0);
  });

  test('sign in connects, loads the account and ensures the folder', () async {
    final drive = FakeDrive();
    final sync = SyncController(FakeAuth(drive));
    await sync.start();
    expect(sync.status, SyncStatus.signedOut);

    await sync.signIn();
    expect(sync.status, SyncStatus.connected);
    expect(sync.account?.email, 'test@example.com');
    expect(sync.folderId, 'folder-1');
  });

  test('start() reconnects silently after a previous sign-in', () async {
    final drive = FakeDrive()..folders.add({'id': 'existing'});
    final sync = SyncController(FakeAuth(drive, previouslySignedIn: true));
    await sync.start();
    expect(sync.status, SyncStatus.connected);
    expect(sync.folderId, 'existing');
  });

  test('sign out clears state and revokes', () async {
    final auth = FakeAuth(FakeDrive(), previouslySignedIn: true);
    final sync = SyncController(auth);
    await sync.start();
    await sync.signOut();
    expect(sync.status, SyncStatus.signedOut);
    expect(sync.account, isNull);
    expect(auth.signOuts, 1);
  });

  test('sign out finishes even when the Drive client was already closed', () async {
    // Like googleapis_auth: closing the same client twice throws.
    final client = _CloseOnceClient(FakeDrive().client());
    final auth = _ClosingAuth(client);
    final sync = SyncController(auth);
    await sync.start();
    expect(sync.status, SyncStatus.connected);

    final signingOut = sync.signOut();
    // Signed out at once, before revoking finishes.
    expect(sync.status, SyncStatus.signedOut);
    expect(sync.account, isNull);
    await signingOut;
    expect(auth.signedOut, isTrue);
  });
}

class _CloseOnceClient extends http.BaseClient {
  _CloseOnceClient(this.inner);

  final http.Client inner;
  var _closed = false;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) => inner.send(request);

  @override
  void close() {
    if (_closed) throw StateError('Cannot close a HTTP client more than once.');
    _closed = true;
    inner.close();
  }
}

/// Like the desktop auth: its sign-out closes the client it handed out.
class _ClosingAuth implements GoogleAuth {
  _ClosingAuth(this.client);

  final http.Client client;
  var signedOut = false;

  @override
  bool get isConfigured => true;
  @override
  Future<http.Client?> restore() async => client;
  @override
  Future<http.Client> signIn() async => client;
  @override
  Future<void> signOut() async {
    try {
      client.close();
    } on StateError {
      // Already closed.
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
    signedOut = true;
  }
}

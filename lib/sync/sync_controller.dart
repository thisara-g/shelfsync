import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'drive_service.dart';
import 'google_auth.dart';

enum SyncStatus { notConfigured, signedOut, connecting, connected, error }

/// Owns the Google sign-in state and the Drive connection.
class SyncController extends ChangeNotifier {
  SyncController(this.auth, {this.driveFactory = DriveService.new})
      : _status = auth.isConfigured ? SyncStatus.signedOut : SyncStatus.notConfigured;

  final GoogleAuth auth;

  /// How a Drive client is built from an authenticated HTTP client (tests
  /// substitute a fake).
  final DriveService Function(http.Client client) driveFactory;

  SyncStatus _status;
  SyncStatus get status => _status;

  DriveService? _drive;
  DriveService? get drive => _drive;

  DriveAccount? _account;
  DriveAccount? get account => _account;

  String? _folderId;

  /// Id of the visible `ShelfSync` folder in the user's Drive.
  String? get folderId => _folderId;

  String? _error;
  String? get error => _error;

  /// Reconnects silently using a previous sign-in, if any.
  Future<void> start() async {
    if (_status == SyncStatus.notConfigured) return;
    _set(SyncStatus.connecting);
    final client = await auth.restore();
    if (client == null) {
      _set(SyncStatus.signedOut);
      return;
    }
    await _connect(client);
  }

  Future<void> signIn() async {
    if (_status == SyncStatus.notConfigured || _status == SyncStatus.connecting) return;
    _set(SyncStatus.connecting);
    try {
      await _connect(await auth.signIn());
    } catch (e) {
      _fail(e);
    }
  }

  /// Shows as signed out at once, then lets [auth] forget and revoke the
  /// sign-in, which may take a network round trip.
  Future<void> signOut() async {
    final drive = _drive;
    _drive = null;
    _account = null;
    _folderId = null;
    _error = null;
    _set(SyncStatus.signedOut);
    try {
      drive?.client.close();
    } on StateError {
      // Already closed: googleapis_auth clients throw on a second close.
    }
    await auth.signOut();
  }

  Future<void> _connect(http.Client client) async {
    try {
      final drive = driveFactory(client);
      _account = await drive.account();
      _folderId = await drive.ensureLibraryFolder();
      _drive = drive;
      _error = null;
      _set(SyncStatus.connected);
    } catch (e) {
      client.close();
      _fail(e);
    }
  }

  void _fail(Object e) {
    _error = e is StateError ? e.message : e.toString();
    _set(SyncStatus.error);
  }

  void _set(SyncStatus status) {
    _status = status;
    notifyListeners();
  }
}

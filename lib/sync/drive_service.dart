import 'package:googleapis/drive/v3.dart' as drive;
import 'package:http/http.dart' as http;

class DriveAccount {
  const DriveAccount({required this.email, required this.displayName});

  final String email;
  final String displayName;
}

/// Thin wrapper over the Drive v3 API for ShelfSync's needs.
///
/// With the `drive.file` scope, queries only ever see files this app created,
/// so the folder lookup can't pick up an unrelated "ShelfSync" folder.
class DriveService {
  DriveService(this.client) : api = drive.DriveApi(client);

  final http.Client client;
  final drive.DriveApi api;

  static const folderName = 'ShelfSync';
  static const _folderMime = 'application/vnd.google-apps.folder';

  Future<DriveAccount> account() async {
    final about = await api.about.get($fields: 'user(displayName,emailAddress)');
    final user = about.user;
    return DriveAccount(
      email: user?.emailAddress ?? '',
      displayName: user?.displayName ?? '',
    );
  }

  /// Returns the id of the visible `ShelfSync` folder, creating it on first use.
  ///
  /// If two devices raced and created two folders, the oldest one wins so
  /// every device converges on the same folder.
  Future<String> ensureLibraryFolder() async {
    final existing = await api.files.list(
      q: "mimeType = '$_folderMime' and name = '$folderName' and 'root' in parents and trashed = false",
      orderBy: 'createdTime',
      pageSize: 10,
      spaces: 'drive',
      $fields: 'files(id)',
    );
    final found = existing.files;
    if (found != null && found.isNotEmpty) return found.first.id!;

    final created = await api.files.create(
      drive.File(name: folderName, mimeType: _folderMime, parents: ['root']),
      $fields: 'id',
    );
    return created.id!;
  }

  static Uri folderUrl(String folderId) => Uri.parse('https://drive.google.com/drive/folders/$folderId');
}

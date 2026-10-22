import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../sync/drive_service.dart';
import '../sync/library_sync.dart';
import '../sync/sync_controller.dart';

/// App-bar button showing the Google Drive connection state.
class SyncButton extends StatelessWidget {
  const SyncButton({super.key, required this.sync, required this.librarySync});

  final SyncController sync;
  final LibrarySync librarySync;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([sync, librarySync]),
      builder: (context, _) {
        final syncProblem = sync.status == SyncStatus.connected && librarySync.lastError != null;
        final (icon, tooltip) = switch (sync.status) {
          SyncStatus.notConfigured => (Icons.cloud_off_outlined, 'Sync not set up'),
          SyncStatus.signedOut => (Icons.cloud_outlined, 'Sign in to sync'),
          SyncStatus.connecting => (Icons.cloud_sync_outlined, 'Connecting…'),
          SyncStatus.connected when librarySync.isSyncing => (Icons.cloud_sync_outlined, 'Syncing…'),
          SyncStatus.connected when syncProblem => (Icons.sync_problem_outlined, 'Last sync failed'),
          SyncStatus.connected => (Icons.cloud_done_outlined, 'Synced with Google Drive'),
          SyncStatus.error => (Icons.cloud_off_outlined, 'Sync problem'),
        };
        if (sync.status == SyncStatus.signedOut) {
          return Padding(
            padding: const EdgeInsets.only(right: 8),
            child: FilledButton.tonalIcon(
              onPressed: sync.signIn,
              icon: Icon(icon),
              label: const Text('Sign in'),
            ),
          );
        }
        return IconButton(
          tooltip: tooltip,
          icon: sync.status == SyncStatus.connecting
              ? const SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2))
              : Icon(
                  icon,
                  color: sync.status == SyncStatus.error || syncProblem ? Theme.of(context).colorScheme.error : null,
                ),
          onPressed: () => showModalBottomSheet<void>(
            context: context,
            showDragHandle: true,
            builder: (_) => _AccountSheet(sync: sync, librarySync: librarySync),
          ),
        );
      },
    );
  }
}

class _AccountSheet extends StatelessWidget {
  const _AccountSheet({required this.sync, required this.librarySync});

  final SyncController sync;
  final LibrarySync librarySync;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListenableBuilder(
      listenable: Listenable.merge([sync, librarySync]),
      builder: (context, _) {
        final children = switch (sync.status) {
          SyncStatus.notConfigured => [
              const ListTile(
                leading: Icon(Icons.cloud_off_outlined),
                title: Text('Google Drive sync is not set up'),
                subtitle: Text('This build has no Google OAuth client. Run ./setup in the project folder, '
                    'then rebuild the app.'),
              ),
            ],
          SyncStatus.connected => [
              ListTile(
                leading: const Icon(Icons.account_circle_outlined),
                title: Text(sync.account?.displayName.isNotEmpty == true ? sync.account!.displayName : 'Signed in'),
                subtitle: Text(sync.account?.email ?? ''),
              ),
              ListTile(
                leading: const Icon(Icons.folder_outlined),
                title: const Text('ShelfSync folder'),
                subtitle: const Text('Books are stored in this folder in your Google Drive'),
                trailing: const Icon(Icons.open_in_new),
                onTap: () => launchUrl(DriveService.folderUrl(sync.folderId!), mode: LaunchMode.externalApplication),
              ),
              ListTile(
                leading: librarySync.isSyncing
                    ? const SizedBox.square(dimension: 24, child: CircularProgressIndicator(strokeWidth: 2))
                    : Icon(
                        librarySync.lastError == null ? Icons.sync : Icons.sync_problem_outlined,
                        color: librarySync.lastError == null ? null : theme.colorScheme.error,
                      ),
                title: Text(librarySync.isSyncing ? 'Syncing…' : 'Sync now'),
                subtitle: librarySync.lastError == null ? null : Text('Last sync failed: ${librarySync.lastError}'),
                onTap: librarySync.isSyncing ? null : librarySync.syncNow,
              ),
              ListTile(
                leading: const Icon(Icons.logout),
                title: const Text('Sign out'),
                onTap: () {
                  Navigator.pop(context);
                  sync.signOut();
                },
              ),
            ],
          SyncStatus.error => [
              ListTile(
                leading: Icon(Icons.error_outline, color: theme.colorScheme.error),
                title: const Text("Couldn't connect to Google Drive"),
                subtitle: Text(sync.error ?? 'Unknown error'),
              ),
              ListTile(leading: const Icon(Icons.refresh), title: const Text('Try again'), onTap: sync.signIn),
              ListTile(
                leading: const Icon(Icons.logout),
                title: const Text('Sign out'),
                onTap: () {
                  Navigator.pop(context);
                  sync.signOut();
                },
              ),
            ],
          SyncStatus.connecting => [
              const ListTile(
                leading: SizedBox.square(dimension: 24, child: CircularProgressIndicator(strokeWidth: 2)),
                title: Text('Connecting to Google Drive…'),
                subtitle: Text('Finish signing in in your browser if it opened.'),
              ),
            ],
          SyncStatus.signedOut => [
              ListTile(leading: const Icon(Icons.login), title: const Text('Sign in with Google'), onTap: sync.signIn),
            ],
        };
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Column(mainAxisSize: MainAxisSize.min, children: children),
          ),
        );
      },
    );
  }
}

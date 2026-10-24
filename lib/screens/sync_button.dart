import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../sync/drive_service.dart';
import '../sync/library_sync.dart';
import '../sync/sync_controller.dart';
import 'common.dart';

void showAccountSheet(BuildContext context, SyncController sync, LibrarySync librarySync) {
  showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    constraints: const BoxConstraints(maxWidth: 560),
    builder: (_) => _AccountSheet(sync: sync, librarySync: librarySync),
  );
}

/// Short sync state for the chip and the sidebar: (icon, label, isProblem).
(IconData, String, bool) _syncState(SyncController sync, LibrarySync librarySync) {
  final failed = sync.status == SyncStatus.connected && librarySync.lastError != null;
  return switch (sync.status) {
    SyncStatus.notConfigured => (Icons.cloud_off_outlined, 'Sync not set up', false),
    SyncStatus.signedOut => (Icons.cloud_outlined, 'Not signed in', false),
    SyncStatus.connecting => (Icons.cloud_sync_outlined, 'Connecting…', false),
    SyncStatus.connected when librarySync.isSyncing => (Icons.cloud_sync_outlined, 'Syncing…', false),
    SyncStatus.connected when failed => (Icons.sync_problem_outlined, 'Sync failed', true),
    SyncStatus.connected => (Icons.check, 'Synced', false),
    SyncStatus.error => (Icons.cloud_off_outlined, 'Sync problem', true),
  };
}

/// Pill in the library header: "Synced", "Syncing…", or a Sign in button.
class SyncButton extends StatelessWidget {
  const SyncButton({super.key, required this.sync, required this.librarySync});

  final SyncController sync;
  final LibrarySync librarySync;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([sync, librarySync]),
      builder: (context, _) {
        if (sync.status == SyncStatus.signedOut) {
          return FilledButton.tonalIcon(
            onPressed: sync.signIn,
            icon: const Icon(Icons.login),
            label: const Text('Sign in'),
          );
        }
        final scheme = Theme.of(context).colorScheme;
        final (icon, label, problem) = _syncState(sync, librarySync);
        final busy = sync.status == SyncStatus.connecting || librarySync.isSyncing;
        final background = problem ? scheme.errorContainer : scheme.primaryContainer;
        final foreground = problem ? scheme.onErrorContainer : scheme.onPrimaryContainer;
        return Material(
          color: background,
          shape: const StadiumBorder(),
          child: InkWell(
            customBorder: const StadiumBorder(),
            onTap: () => showAccountSheet(context, sync, librarySync),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  busy
                      ? SizedBox.square(
                          dimension: 16,
                          child: CircularProgressIndicator(strokeWidth: 2, color: foreground),
                        )
                      : Icon(icon, size: 18, color: foreground),
                  const SizedBox(width: 8),
                  Text(label, style: TextStyle(color: foreground, fontWeight: FontWeight.w600)),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Account row at the bottom of the desktop sidebar.
class SidebarAccount extends StatelessWidget {
  const SidebarAccount({super.key, required this.sync, required this.librarySync});

  final SyncController sync;
  final LibrarySync librarySync;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([sync, librarySync]),
      builder: (context, _) {
        final theme = Theme.of(context);
        if (sync.status == SyncStatus.signedOut) {
          return FilledButton.icon(
            onPressed: sync.signIn,
            icon: const Icon(Icons.login),
            label: const Text('Sign in to sync'),
          );
        }
        final (icon, label, problem) = _syncState(sync, librarySync);
        final account = sync.account;
        final name = account == null
            ? 'ShelfSync'
            : (account.displayName.isNotEmpty ? account.displayName : account.email);
        final syncedAt = librarySync.lastSyncedAt;
        final status = label == 'Synced' && syncedAt != null ? 'Synced · ${timeAgo(syncedAt)}' : label;
        return Material(
          color: theme.colorScheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(12),
          child: InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: () => showAccountSheet(context, sync, librarySync),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  CircleAvatar(
                    radius: 18,
                    child: account == null ? Icon(icon, size: 18) : Text(name.characters.first.toUpperCase()),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(name, maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.titleSmall),
                        Text(
                          status,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: problem ? theme.colorScheme.error : theme.colorScheme.primary,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
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

import 'dart:io';
import 'dart:math' show min;

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/book.dart';
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

/// Round account button with the user's initial (tablet library header).
class AccountAvatar extends StatelessWidget {
  const AccountAvatar({super.key, required this.sync, required this.librarySync});

  final SyncController sync;
  final LibrarySync librarySync;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: sync,
      builder: (context, _) {
        final account = sync.account;
        if (account == null) return const SizedBox();
        final name = account.displayName.isNotEmpty ? account.displayName : account.email;
        return Tooltip(
          message: account.email,
          child: Material(
            color: const Color(0xFF455A64),
            shape: const CircleBorder(),
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: () => showAccountSheet(context, sync, librarySync),
              child: SizedBox.square(
                dimension: 48,
                child: Center(
                  child: Text(
                    name.characters.first.toUpperCase(),
                    style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w600),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Account row at the bottom of the desktop sidebar. Clicking it opens the
/// account panel just above it; the row stays outlined while it is open.
class SidebarAccount extends StatefulWidget {
  const SidebarAccount({super.key, required this.sync, required this.librarySync});

  final SyncController sync;
  final LibrarySync librarySync;

  @override
  State<SidebarAccount> createState() => _SidebarAccountState();
}

class _SidebarAccountState extends State<SidebarAccount> {
  var _open = false;

  SyncController get sync => widget.sync;
  LibrarySync get librarySync => widget.librarySync;

  Future<void> _openPanel() async {
    final box = context.findRenderObject() as RenderBox?;
    if (box == null) return;
    final anchor = box.localToGlobal(Offset.zero) & box.size;
    setState(() => _open = true);
    await showAccountPanel(context, anchor: anchor, sync: sync, librarySync: librarySync);
    if (mounted) setState(() => _open = false);
  }

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
          color: _open ? const Color(0xFF263238) : const Color(0xFF202A2E),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: _open ? const BorderSide(color: Color(0xFF4DB6AC)) : BorderSide.none,
          ),
          child: InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: _openPanel,
            child: Padding(
              // One pixel less while outlined, so nothing moves.
              padding: EdgeInsets.all(_open ? 11 : 12),
              child: Row(
                children: [
                  CircleAvatar(
                    radius: 18,
                    backgroundColor: const Color(0xFF455A64),
                    foregroundColor: Colors.white,
                    child: account == null
                        ? Icon(icon, size: 18)
                        : Text(
                            name.characters.first.toUpperCase(),
                            style: const TextStyle(fontWeight: FontWeight.w600),
                          ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(color: Color(0xFFECF1EF), fontSize: 14, fontWeight: FontWeight.w600),
                        ),
                        Text(
                          status,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 13,
                            color: problem ? theme.colorScheme.error : const Color(0xFF80CBC4),
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

/// Desktop account panel, opened 16px above [anchor] (the sidebar's account
/// row) with the same left edge. Click outside or press Esc to close.
Future<void> showAccountPanel(
  BuildContext context, {
  required Rect anchor,
  required SyncController sync,
  required LibrarySync librarySync,
}) {
  // showGeneralDialog, unlike showDialog, doesn't take on the dark theme of
  // the sidebar it is opened from.
  return showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'Close account panel',
    barrierColor: Colors.transparent,
    transitionDuration: const Duration(milliseconds: 140),
    transitionBuilder: (context, animation, _, child) {
      final curve = CurvedAnimation(parent: animation, curve: Curves.easeOutCubic);
      return FadeTransition(
        opacity: curve,
        child: SlideTransition(
          position: Tween(begin: const Offset(0, 0.03), end: Offset.zero).animate(curve),
          child: child,
        ),
      );
    },
    pageBuilder: (context, _, _) {
      final screen = MediaQuery.sizeOf(context);
      return Stack(
        children: [
          Positioned(
            left: anchor.left,
            bottom: screen.height - anchor.top + 16,
            width: min(360, screen.width - anchor.left - 16),
            child: _AccountPanel(sync: sync, librarySync: librarySync),
          ),
        ],
      );
    },
  );
}

/// What the panel's mint (or red) box says about sync.
({IconData? icon, bool busy, String title, String? detail, bool problem}) _panelStatus(
  SyncController sync,
  LibrarySync librarySync,
) {
  final syncedAt = librarySync.lastSyncedAt;
  return switch (sync.status) {
    SyncStatus.notConfigured => (
      icon: Icons.cloud_off_outlined,
      busy: false,
      title: 'Google Drive sync is not set up',
      detail: 'This build has no Google OAuth client. Run ./setup in the project folder, then rebuild.',
      problem: false,
    ),
    SyncStatus.signedOut => (
      icon: Icons.cloud_outlined,
      busy: false,
      title: 'Not signed in',
      detail: null,
      problem: false,
    ),
    SyncStatus.connecting => (
      icon: null,
      busy: true,
      title: 'Connecting to Google Drive…',
      detail: 'Finish signing in in your browser if it opened.',
      problem: false,
    ),
    SyncStatus.error => (
      icon: Icons.cloud_off_outlined,
      busy: false,
      title: "Couldn't connect to Google Drive",
      detail: sync.error ?? 'Unknown error',
      problem: true,
    ),
    SyncStatus.connected when librarySync.isSyncing => (
      icon: null,
      busy: true,
      title: 'Syncing…',
      detail: null,
      problem: false,
    ),
    SyncStatus.connected when librarySync.lastError != null => (
      icon: Icons.sync_problem_outlined,
      busy: false,
      title: 'Last sync failed',
      detail: '${librarySync.lastError}',
      problem: true,
    ),
    SyncStatus.connected => (
      icon: Icons.check_rounded,
      busy: false,
      title: syncedAt == null ? 'Synced' : 'Synced · ${timeAgo(syncedAt)}',
      detail: null,
      problem: false,
    ),
  };
}

class _AccountPanel extends StatelessWidget {
  const _AccountPanel({required this.sync, required this.librarySync});

  final SyncController sync;
  final LibrarySync librarySync;

  static const _ink = Color(0xFF1D2321);
  static const _muted = Color(0xFF5B6764);
  static const _faint = Color(0xFF8A9A96);
  static const _line = Color(0xFFDDE2E0);

  @override
  Widget build(BuildContext context) {
    final store = librarySync.store;
    return ListenableBuilder(
      listenable: Listenable.merge([sync, librarySync, store]),
      builder: (context, _) {
        final account = sync.account;
        final connected = sync.status == SyncStatus.connected;
        final status = _panelStatus(sync, librarySync);
        final inDrive = store.books.where((b) => b.driveFileId != null).toList();
        final bytes = inDrive.fold<int>(0, (sum, b) => sum + (b.sizeBytes ?? 0));
        final driveLine = [
          '${inDrive.length} book${inDrive.length == 1 ? '' : 's'}',
          if (bytes > 0) formatSize(bytes),
        ].join(' · ');

        // Other devices: the newest book each one moved the position of.
        final others = <String, Book>{};
        for (final book in store.books) {
          final device = book.progressDevice;
          if (device == null || device == store.deviceName || book.progressUpdatedAt == null) continue;
          final seen = others[device];
          if (seen == null || book.progressUpdatedAt!.isAfter(seen.progressUpdatedAt!)) others[device] = book;
        }

        final name = account == null
            ? 'ShelfSync'
            : (account.displayName.isNotEmpty ? account.displayName : account.email);
        final outlined = OutlinedButton.styleFrom(
          minimumSize: const Size(0, 42),
          // Two buttons share 328px: Material's 24px sides would wrap the labels.
          padding: const EdgeInsets.symmetric(horizontal: 8),
          foregroundColor: _ink,
          backgroundColor: Colors.white,
          side: const BorderSide(color: _line),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.normal),
        );
        final boxBg = status.problem ? const Color(0xFFFDECEC) : const Color(0xFFE0F2F1);
        final boxFg = status.problem ? const Color(0xFFC62828) : const Color(0xFF00695C);

        return Material(
          color: Colors.white,
          elevation: 16,
          shadowColor: Colors.black54,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: const BorderSide(color: Color(0x0F000000)),
          ),
          clipBehavior: Clip.antiAlias,
          child: DefaultTextStyle.merge(
            style: const TextStyle(color: _ink, fontFamily: uiFamily),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 20, 20, 16),
                  child: Row(
                    children: [
                      CircleAvatar(
                        radius: 22,
                        backgroundColor: const Color(0xFF455A64),
                        foregroundColor: Colors.white,
                        child: Text(
                          name.characters.first.toUpperCase(),
                          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
                        ),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                            ),
                            if (account != null && account.email.isNotEmpty && account.email != name) ...[
                              const SizedBox(height: 2),
                              Text(
                                account.email,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontSize: 14, color: _muted),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                Container(
                  margin: const EdgeInsets.symmetric(horizontal: 16),
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                  decoration: BoxDecoration(color: boxBg, borderRadius: BorderRadius.circular(12)),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          if (status.busy)
                            SizedBox.square(
                              dimension: 16,
                              child: CircularProgressIndicator(strokeWidth: 2, color: boxFg),
                            )
                          else
                            Icon(status.icon, size: 18, color: boxFg),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              status.title,
                              style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: boxFg),
                            ),
                          ),
                        ],
                      ),
                      if (status.detail != null || connected) ...[
                        const SizedBox(height: 6),
                        Text(
                          status.detail ?? '$driveLine in your Google Drive',
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 14,
                            color: status.problem ? const Color(0xFF8E2424) : const Color(0xFF2E5E58),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                if (sync.status != SyncStatus.notConfigured) ...[
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                    child: Row(
                      children: [
                        Expanded(
                          child: sync.status == SyncStatus.error
                              ? OutlinedButton.icon(
                                  style: outlined,
                                  onPressed: sync.signIn,
                                  icon: const Icon(Icons.refresh_rounded, size: 17),
                                  label: const Text('Try again', maxLines: 1, overflow: TextOverflow.ellipsis),
                                )
                              : OutlinedButton.icon(
                                  style: outlined,
                                  onPressed: connected && !librarySync.isSyncing ? librarySync.syncNow : null,
                                  icon: const Icon(Icons.sync_rounded, size: 17),
                                  label: Text(
                                    librarySync.isSyncing ? 'Syncing…' : 'Sync now',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: OutlinedButton.icon(
                            style: outlined,
                            onPressed: sync.folderId == null
                                ? null
                                : () => launchUrl(
                                    DriveService.folderUrl(sync.folderId!),
                                    mode: LaunchMode.externalApplication,
                                  ),
                            icon: const Icon(Icons.folder_outlined, size: 17),
                            // An icon for ↗: the character falls back to a colour emoji.
                            label: const Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Flexible(
                                  child: Text('Open in Drive', maxLines: 1, overflow: TextOverflow.ellipsis),
                                ),
                                SizedBox(width: 4),
                                Icon(Icons.north_east_rounded, size: 14),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 8, 20, 4),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const Padding(
                          padding: EdgeInsets.symmetric(vertical: 6),
                          child: Text(
                            'YOUR DEVICES',
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              letterSpacing: 1,
                              color: _faint,
                            ),
                          ),
                        ),
                        _DeviceRow(
                          icon: Platform.isAndroid ? Icons.tablet_android_outlined : Icons.computer_outlined,
                          name: store.deviceName,
                          note: Platform.isAndroid ? 'This tablet' : 'This PC',
                        ),
                        for (final MapEntry(key: device, value: book) in others.entries)
                          _DeviceRow(
                            // ShelfSync pairs a PC with a tablet: from Linux the
                            // other device is the tablet, from Android the PC.
                            icon: Platform.isAndroid ? Icons.computer_outlined : Icons.tablet_android_outlined,
                            name: device,
                            note: 'Read ${book.title} · ${timeAgo(book.progressUpdatedAt!)}',
                          ),
                      ],
                    ),
                  ),
                  Container(
                    margin: const EdgeInsets.only(top: 8),
                    padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
                    decoration: const BoxDecoration(
                      border: Border(top: BorderSide(color: Color(0xFFE6EAE8))),
                    ),
                    child: Row(
                      children: [
                        const Expanded(
                          child: Text(
                            'Signing out keeps your books on this PC and in Drive.',
                            style: TextStyle(fontSize: 13, color: _faint),
                          ),
                        ),
                        const SizedBox(width: 12),
                        OutlinedButton(
                          style: OutlinedButton.styleFrom(
                            minimumSize: const Size(0, 36),
                            padding: const EdgeInsets.symmetric(horizontal: 14),
                            foregroundColor: const Color(0xFFC62828),
                            backgroundColor: Colors.white,
                            side: const BorderSide(color: Color(0xFFF3C7C7)),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                            textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
                          ),
                          onPressed: () {
                            Navigator.pop(context);
                            sync.signOut();
                          },
                          child: const Text('Sign out'),
                        ),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }
}

class _DeviceRow extends StatelessWidget {
  const _DeviceRow({required this.icon, required this.name, required this.note});

  final IconData icon;
  final String name;
  final String note;

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 44),
      child: Row(
        children: [
          Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(color: const Color(0xFFF1F4F3), borderRadius: BorderRadius.circular(8)),
            child: Icon(icon, size: 18, color: const Color(0xFF455A64)),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 15)),
                Text(
                  note,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 13, color: _AccountPanel._muted),
                ),
              ],
            ),
          ),
        ],
      ),
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

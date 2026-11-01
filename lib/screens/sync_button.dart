import 'dart:io';
import 'dart:math' show min;

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/book.dart';
import '../sync/drive_service.dart';
import '../sync/library_sync.dart';
import '../sync/sync_controller.dart';
import 'common.dart';
import 'tablet_ui.dart';

/// Tablet: the account and sync sheet.
void showAccountSheet(BuildContext context, SyncController sync, LibrarySync librarySync) {
  showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    constraints: const BoxConstraints(maxWidth: 840),
    backgroundColor: TabletColors.sheet,
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(34))),
    builder: (_) => Theme(
      data: tabletTheme(),
      child: _TabletAccountSheet(sync: sync, librarySync: librarySync),
    ),
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


/// Tablet library header: "Synced · just now" with a status dot, or Sign in.
class TabletSyncPill extends StatelessWidget {
  const TabletSyncPill({super.key, required this.sync, required this.librarySync});

  final SyncController sync;
  final LibrarySync librarySync;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([sync, librarySync]),
      builder: (context, _) {
        if (sync.status == SyncStatus.signedOut) {
          return GlassPillButton(label: 'Sign in', icon: Icons.login_rounded, height: 40, fontSize: 14, onPressed: sync.signIn);
        }
        final (_, label, problem) = _syncState(sync, librarySync);
        final busy = sync.status == SyncStatus.connecting || librarySync.isSyncing;
        final syncedAt = librarySync.lastSyncedAt;
        final arriving = librarySync.isSyncing ? librarySync.incoming + librarySync.arrivedThisSync : 0;
        final text = arriving > 0
            ? 'Syncing · $arriving new book${arriving == 1 ? '' : 's'}'
            : (label == 'Synced' && syncedAt != null ? 'Synced · ${timeAgo(syncedAt)}' : label);
        final dot = problem ? const Color(0xFFF87171) : (busy ? const Color(0xFFFBBF24) : TabletColors.green);
        return Material(
          color: TabletColors.glass,
          shape: const StadiumBorder(side: BorderSide(color: TabletColors.glassBorder)),
          child: InkWell(
            customBorder: const StadiumBorder(),
            onTap: () => showAccountSheet(context, sync, librarySync),
            child: Container(
              height: 40,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  busy
                      ? SizedBox.square(dimension: 12, child: CircularProgressIndicator(strokeWidth: 2, color: dot))
                      : Container(
                          width: 8,
                          height: 8,
                          decoration: BoxDecoration(
                            color: dot,
                            shape: BoxShape.circle,
                            boxShadow: [BoxShadow(color: dot.withValues(alpha: 0.18), spreadRadius: 4)],
                          ),
                        ),
                  const SizedBox(width: 10),
                  Text(text, style: const TextStyle(fontSize: 14, color: TabletColors.soft)),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _TabletAccountSheet extends StatelessWidget {
  const _TabletAccountSheet({required this.sync, required this.librarySync});

  final SyncController sync;
  final LibrarySync librarySync;

  @override
  Widget build(BuildContext context) {
    final store = librarySync.store;
    return ListenableBuilder(
      listenable: Listenable.merge([sync, librarySync, store]),
      builder: (context, _) {
        final account = sync.account;
        final connected = sync.status == SyncStatus.connected;
        final signedIn = connected || sync.status == SyncStatus.error || sync.status == SyncStatus.connecting;
        final name = account == null
            ? (signedIn ? 'Google account' : 'Not signed in')
            : (account.displayName.isNotEmpty ? account.displayName : account.email);
        final inDrive = store.books.where((b) => b.driveFileId != null).toList();
        final bytes = inDrive.fold<int>(0, (sum, b) => sum + (b.sizeBytes ?? 0));
        final local = store.books.where((b) => b.isLocal).length;

        // This device: the book last read here. Others: the newest book each
        // one moved the position of.
        final readHere = store.books.where((b) => b.progressDevice == null && b.lastOpenedAt != null).toList()
          ..sort((a, b) => b.lastOpenedAt!.compareTo(a.lastOpenedAt!));
        final others = <String, Book>{};
        for (final book in store.books) {
          final device = book.progressDevice;
          if (device == null || device == store.deviceName || book.progressUpdatedAt == null) continue;
          final seen = others[device];
          if (seen == null || book.progressUpdatedAt!.isAfter(seen.progressUpdatedAt!)) others[device] = book;
        }
        final here = readHere.isEmpty ? null : readHere.first;

        return SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(40, 14, 40, 36),
            child: DefaultTextStyle.merge(
              style: const TextStyle(color: TabletColors.text, fontFamily: uiFamily),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const SheetHandle(),
                  const SizedBox(height: 28),
                  Row(
                    children: [
                      AccountRing(
                        initial: account == null ? null : name.characters.first.toUpperCase(),
                        size: 72,
                        border: TabletColors.sheet,
                      ),
                      const SizedBox(width: 18),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w700),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              signedIn ? 'Signed in with Google' : 'Sign in to sync with your other devices',
                              style: const TextStyle(fontSize: 15, color: TabletColors.dim),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 22),
                  _statusCard(),
                  if (connected) ...[
                    const SizedBox(height: 22),
                    Row(
                      children: [
                        _Stat(value: '${inDrive.length}', label: inDrive.length == 1 ? 'book in Drive' : 'books in Drive'),
                        const SizedBox(width: 12),
                        _Stat(value: bytes == 0 ? '—' : formatSize(bytes), label: 'in your ShelfSync folder'),
                        const SizedBox(width: 12),
                        _Stat(value: '$local', label: 'downloaded here'),
                      ],
                    ),
                    const SizedBox(height: 22),
                    const TabletLabel('Your devices'),
                    const SizedBox(height: 4),
                    _TabletDevice(
                      icon: Platform.isAndroid ? Icons.tablet_android_outlined : Icons.laptop_outlined,
                      name: Platform.isAndroid ? 'This tablet' : 'This device',
                      note: here == null
                          ? store.deviceName
                          : 'Reading ${here.title} · p. ${here.lastPage} · ${timeAgo(here.lastOpenedAt!)}',
                      here: true,
                    ),
                    for (final MapEntry(key: device, value: book) in others.entries)
                      _TabletDevice(
                        icon: Platform.isAndroid ? Icons.laptop_outlined : Icons.tablet_android_outlined,
                        name: device,
                        note: 'Read ${book.title} · ${timeAgo(book.progressUpdatedAt!)}',
                      ),
                  ],
                  const SizedBox(height: 28),
                  if (connected && sync.folderId != null)
                    Material(
                      color: const Color(0x0DFFFFFF),
                      borderRadius: BorderRadius.circular(18),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(18),
                        onTap: () => launchUrl(DriveService.folderUrl(sync.folderId!), mode: LaunchMode.externalApplication),
                        child: const SizedBox(
                          height: 60,
                          child: Padding(
                            padding: EdgeInsets.symmetric(horizontal: 20),
                            child: Row(
                              children: [
                                Icon(Icons.folder_outlined, color: TabletColors.accent, size: 22),
                                SizedBox(width: 14),
                                Expanded(
                                  child: Text(
                                    'Open the ShelfSync folder in Drive',
                                    style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
                                  ),
                                ),
                                Icon(Icons.north_east_rounded, color: TabletColors.dim, size: 18),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      const Icon(Icons.lock_outline_rounded, size: 16, color: TabletColors.faint),
                      const SizedBox(width: 10),
                      const Expanded(
                        child: Text(
                          'ShelfSync only sees the files it creates.',
                          style: TextStyle(fontSize: 14, color: TabletColors.faint),
                        ),
                      ),
                      if (signedIn)
                        TextButton(
                          style: TextButton.styleFrom(
                            foregroundColor: TabletColors.danger,
                            minimumSize: const Size(0, 48),
                            padding: const EdgeInsets.symmetric(horizontal: 20),
                            textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700, fontFamily: uiFamily),
                          ),
                          onPressed: () {
                            Navigator.pop(context);
                            sync.signOut();
                          },
                          child: const Text('Sign out'),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  /// The big box: green when synced, red when something failed.
  Widget _statusCard() {
    final status = _panelStatus(sync, librarySync);
    final connected = sync.status == SyncStatus.connected;
    final ok = !status.problem && !status.busy && connected;
    final base = status.problem ? const Color(0xFFF87171) : (ok ? TabletColors.green : const Color(0xFF93C5FD));
    final title = ok ? 'Everything is synced' : status.title;
    final syncedAt = librarySync.lastSyncedAt;
    final detail = ok
        ? 'Books, pages, shelves and bookmarks · checked ${syncedAt == null ? 'just now' : timeAgo(syncedAt)}'
        : status.detail;
    final (String, VoidCallback?)? action = switch (sync.status) {
      SyncStatus.connected when librarySync.isSyncing => null,
      SyncStatus.connected => (status.problem ? 'Try again' : 'Sync now', librarySync.syncNow),
      SyncStatus.error => ('Try again', sync.signIn),
      SyncStatus.signedOut => ('Sign in', sync.signIn),
      _ => null,
    };
    return Container(
      padding: const EdgeInsets.all(22),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(24),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [base.withValues(alpha: 0.2), base.withValues(alpha: 0.04)],
        ),
        border: Border.all(color: base.withValues(alpha: 0.3)),
      ),
      child: Row(
        children: [
          Container(
            width: 52,
            height: 52,
            decoration: BoxDecoration(
              color: base,
              shape: BoxShape.circle,
              boxShadow: [BoxShadow(color: base.withValues(alpha: 0.15), spreadRadius: 8)],
            ),
            child: status.busy
                ? const Padding(
                    padding: EdgeInsets.all(15),
                    child: CircularProgressIndicator(strokeWidth: 3, color: Color(0xFF0B1B33)),
                  )
                : Icon(
                    ok ? Icons.check_rounded : status.icon,
                    size: 28,
                    color: status.problem ? const Color(0xFF3B0A0A) : const Color(0xFF052E1F),
                  ),
          ),
          const SizedBox(width: 18),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
                if (detail != null) ...[
                  const SizedBox(height: 4),
                  Text(
                    detail,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 15, color: Color.lerp(base, Colors.white, 0.55)),
                  ),
                ],
              ],
            ),
          ),
          if (action != null) ...[
            const SizedBox(width: 12),
            GlassPillButton(
              label: action.$1,
              icon: action.$1 == 'Sign in' ? Icons.login_rounded : Icons.sync_rounded,
              height: 48,
              fontSize: 15,
              onPressed: action.$2,
            ),
          ],
        ],
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({required this.value, required this.label});

  final String value;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
        decoration: BoxDecoration(color: const Color(0x0DFFFFFF), borderRadius: BorderRadius.circular(18)),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(value, style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w700)),
            const SizedBox(height: 4),
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 14, color: TabletColors.dim),
            ),
          ],
        ),
      ),
    );
  }
}

class _TabletDevice extends StatelessWidget {
  const _TabletDevice({required this.icon, required this.name, required this.note, this.here = false});

  final IconData icon;
  final String name;
  final String note;
  final bool here;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 4),
      child: Row(
        children: [
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(color: const Color(0x0FFFFFFF), borderRadius: BorderRadius.circular(14)),
            child: Icon(icon, color: TabletColors.muted),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(name, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
                const SizedBox(height: 3),
                Text(
                  note,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 14, color: TabletColors.dim),
                ),
              ],
            ),
          ),
          if (here)
            Container(
              height: 26,
              padding: const EdgeInsets.symmetric(horizontal: 10),
              alignment: Alignment.center,
              decoration: BoxDecoration(color: const Color(0x295EEAD4), borderRadius: BorderRadius.circular(13)),
              child: const Text(
                'THIS ONE',
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: TabletColors.accent),
              ),
            ),
        ],
      ),
    );
  }
}

import 'dart:async';
import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;

import '../app_state.dart';
import '../core/crypto.dart';
import '../core/models.dart';
import '../platform/gallery.dart';
import 'widgets.dart';

class FilesPage extends StatelessWidget {
  const FilesPage({super.key, required this.state, this.onGoToDevices});
  final AppState state;
  final VoidCallback? onGoToDevices;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: state,
    builder: (context, _) => DeviceGate(
      state: state,
      feature: 'the file browser',
      icon: Icons.folder_open_outlined,
      onGoToDevices: onGoToDevices,
      // Keyed by device so switching devices starts a fresh browser.
      builder: (context, device) => _Browser(key: ValueKey(device.id), state: state, device: device),
    ),
  );
}

class _Browser extends StatefulWidget {
  const _Browser({super.key, required this.state, required this.device});
  final AppState state;
  final PairedDevice device;

  @override
  State<_Browser> createState() => _BrowserState();
}

class _BrowserState extends State<_Browser> {
  /// Folders we've opened, root first. Empty means the start screen.
  final List<String> _stack = [];
  List<RemoteEntry> _entries = [];
  bool _loading = true;
  String? _error;
  bool _dragging = false;
  bool _showHidden = false;

  String? get _current => _stack.isEmpty ? null : _stack.last;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final client = widget.state.clientFor(widget.device);
      final entries = _current == null ? await client.roots() : await client.list(_current!);
      if (!mounted) return;
      setState(() {
        _entries = entries;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  void _open(String path) {
    _stack.add(path);
    _load();
  }

  void _up() {
    if (_stack.isEmpty) return;
    _stack.removeLast();
    _load();
  }

  void _jumpTo(int index) {
    _stack.removeRange(index + 1, _stack.length);
    _load();
  }

  Future<void> _send(List<File> files) async {
    if (files.isEmpty) return;
    await widget.state.sendFiles(widget.device, files, remoteDir: _current);
    if (mounted) unawaited(_load());
  }

  Future<void> _pickAndUpload() async {
    await _send(await pickFilesToSend(context, title: 'Upload to ${widget.device.name}'));
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final visible = _showHidden ? _entries : _entries.where((e) => !e.name.startsWith('.')).toList();
    return PageFrame(
      title: 'Files',
      subtitle: 'On ${widget.device.name}. Drop files here to send them.',
      scroll: false,
      actions: [
        DevicePicker(state: widget.state),
        const SizedBox(width: 8),
        IconButton(
          tooltip: _showHidden ? 'Hide hidden files' : 'Show hidden files',
          onPressed: () => setState(() => _showHidden = !_showHidden),
          icon: Icon(_showHidden ? Icons.visibility_outlined : Icons.visibility_off_outlined),
        ),
        IconButton(tooltip: 'Refresh', onPressed: _load, icon: const Icon(Icons.refresh_rounded)),
        if (_current != null) ...[
          const SizedBox(width: 4),
          FilledButton.icon(
            onPressed: _pickAndUpload,
            icon: const Icon(Icons.upload_rounded),
            label: const Text('Upload here'),
          ),
        ],
      ],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          OfflineBanner(state: widget.state, device: widget.device),
          _Breadcrumbs(
            device: widget.device,
            stack: _stack,
            onRoot: () {
              _stack.clear();
              _load();
            },
            onJump: _jumpTo,
            onUp: _stack.isEmpty ? null : _up,
          ),
          const SizedBox(height: 12),
          Expanded(
            child: MaybeDropTarget(
              enable: _current != null,
              onHover: (hovering) => setState(() => _dragging = hovering),
              onFiles: _send,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                decoration: BoxDecoration(
                  color: _dragging ? scheme.secondaryContainer : scheme.surfaceContainerLow,
                  borderRadius: BorderRadius.circular(24),
                  border: Border.all(color: _dragging ? scheme.primary : Colors.transparent, width: 2),
                ),
                clipBehavior: Clip.antiAlias,
                // Transparent Material so list rows can show hover/ink effects.
                child: Material(type: MaterialType.transparency, child: _buildList(visible)),
              ),
            ),
          ),
          _Transfers(state: widget.state),
        ],
      ),
    );
  }

  Widget _buildList(List<RemoteEntry> entries) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return EmptyState(
        icon: Icons.error_outline,
        title: "Couldn't open this folder",
        message: _error!,
        action: FilledButton.tonal(onPressed: _load, child: const Text('Try again')),
      );
    }
    if (entries.isEmpty) {
      return const EmptyState(
        icon: Icons.folder_off_outlined,
        title: 'This folder is empty',
        message: 'Drag files here to upload them.',
      );
    }
    final scheme = Theme.of(context).colorScheme;
    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: entries.length,
      itemBuilder: (context, i) {
        final e = entries[i];
        final row = ListTile(
          contentPadding: const EdgeInsets.symmetric(horizontal: 16),
          leading: Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: e.isDir ? scheme.secondaryContainer : scheme.tertiaryContainer,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(
              _iconFor(e),
              color: e.isDir ? scheme.onSecondaryContainer : scheme.onTertiaryContainer,
              size: 22,
            ),
          ),
          title: Text(e.name, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: e.isDir
              ? null
              : Text([formatBytes(e.size), if (e.modified != null) _date(e.modified!)].join(' · ')),
          trailing: e.isDir
              ? const Icon(Icons.chevron_right_rounded)
              : IconButton(
                  tooltip: 'Download',
                  icon: const Icon(Icons.download_rounded),
                  onPressed: () => widget.state.download(widget.device, e),
                ),
          onTap: e.isDir ? () => _open(e.path) : () => widget.state.download(widget.device, e),
        );
        // The first screenful cascades in; rows further down just scroll.
        return i < 14 ? Entrance(key: ValueKey(e.path), index: i, child: row) : row;
      },
    );
  }

  static String _date(DateTime d) {
    final l = d.toLocal();
    return '${l.year}-${l.month.toString().padLeft(2, '0')}-${l.day.toString().padLeft(2, '0')}';
  }

  static IconData _iconFor(RemoteEntry e) {
    if (e.isDir) {
      return switch (e.name.toLowerCase()) {
        'desktop' => Icons.desktop_windows_outlined,
        'documents' => Icons.description_outlined,
        'downloads' => Icons.download_outlined,
        'pictures' || 'dcim' || 'camera' => Icons.photo_library_outlined,
        'music' => Icons.library_music_outlined,
        'videos' || 'movies' => Icons.video_library_outlined,
        'home' => Icons.home_outlined,
        _ when RegExp(r'^[A-Za-z]:$').hasMatch(e.name) || e.name == '/' => Icons.storage_outlined,
        _ => Icons.folder_outlined,
      };
    }
    return switch (p.extension(e.name).toLowerCase()) {
      '.jpg' || '.jpeg' || '.png' || '.gif' || '.webp' || '.heic' || '.bmp' => Icons.image_outlined,
      '.mp4' || '.mkv' || '.mov' || '.avi' || '.webm' => Icons.movie_outlined,
      '.mp3' || '.flac' || '.wav' || '.m4a' || '.ogg' => Icons.audio_file_outlined,
      '.pdf' => Icons.picture_as_pdf_outlined,
      '.zip' || '.rar' || '.7z' || '.tar' || '.gz' => Icons.folder_zip_outlined,
      '.exe' || '.msi' || '.apk' => Icons.install_desktop_outlined,
      '.txt' || '.md' || '.doc' || '.docx' => Icons.article_outlined,
      _ => Icons.insert_drive_file_outlined,
    };
  }
}

class _Breadcrumbs extends StatelessWidget {
  const _Breadcrumbs({
    required this.device,
    required this.stack,
    required this.onRoot,
    required this.onJump,
    required this.onUp,
  });

  final PairedDevice device;
  final List<String> stack;
  final VoidCallback onRoot;
  final void Function(int index) onJump;
  final VoidCallback? onUp;

  @override
  Widget build(BuildContext context) {
    // Show the first opened folder in full, then just names below it.
    final crumbs = <(String, int)>[
      for (var i = 0; i < stack.length; i++) (i == 0 ? _rootLabel(stack[0]) : p.basename(stack[i]), i),
    ];
    return Row(
      children: [
        IconButton(tooltip: 'Up', onPressed: onUp, icon: const Icon(Icons.arrow_upward)),
        Expanded(
          // Reversed so long paths show their end; min width keeps short
          // paths left-aligned.
          child: LayoutBuilder(
            builder: (context, constraints) => SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              reverse: true,
              child: ConstrainedBox(
                constraints: BoxConstraints(minWidth: constraints.maxWidth),
                child: Row(
                  children: [
                    ActionChip(
                      avatar: Icon(platformIcon(device.platform), size: 18),
                      label: Text(device.name),
                      onPressed: onRoot,
                    ),
                    for (final (label, i) in crumbs) ...[
                      const Icon(Icons.chevron_right, size: 20),
                      if (i == stack.length - 1)
                        Chip(label: Text(label))
                      else
                        ActionChip(label: Text(label), onPressed: () => onJump(i)),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  static String _rootLabel(String path) {
    final name = p.basename(path);
    return name.isEmpty ? path : name;
  }
}

class _Transfers extends StatelessWidget {
  const _Transfers({required this.state});
  final AppState state;

  @override
  Widget build(BuildContext context) {
    final transfers = state.transfers.take(4).toList();
    if (transfers.isEmpty) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Card.filled(
        color: scheme.surfaceContainerHigh,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
          child: Column(
            children: [
              Row(
                children: [
                  Text('Transfers', style: Theme.of(context).textTheme.titleSmall),
                  const Spacer(),
                  TextButton(onPressed: state.clearFinishedTransfers, child: const Text('Clear finished')),
                ],
              ),
              for (final t in transfers)
                InkWell(
                  borderRadius: BorderRadius.circular(12),
                  onTap: t.security == null ? null : () => showTransferSecurity(context, state, t),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Row(
                      children: [
                        Icon(
                          switch (t.state) {
                            TransferState.running => t.upload ? Icons.upload : Icons.download,
                            TransferState.done => Icons.check_circle,
                            TransferState.failed => Icons.error,
                          },
                          size: 20,
                          color: switch (t.state) {
                            TransferState.failed => scheme.error,
                            TransferState.done => scheme.primary,
                            TransferState.running => scheme.onSurfaceVariant,
                          },
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(t.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                              if (t.state == TransferState.running)
                                Padding(
                                  padding: const EdgeInsets.only(top: 6),
                                  child: LinearProgressIndicator(value: t.fraction),
                                )
                              else
                                Text(
                                  t.state == TransferState.failed
                                      ? t.error ?? 'Failed'
                                      : '${t.upload
                                            ? 'Sent to'
                                            : t.received
                                            ? 'Received from'
                                            : 'Saved from'} ${t.deviceName} · ${formatBytes(t.total)}${t.inGallery ? ' · in ${Gallery.name}' : ''}',
                                  style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
                                ),
                              if (t.security case final security?)
                                Padding(
                                  padding: const EdgeInsets.only(top: 2),
                                  child: Row(
                                    children: [
                                      Icon(Icons.lock, size: 13, color: scheme.primary),
                                      const SizedBox(width: 4),
                                      Text(security.label, style: TextStyle(fontSize: 12, color: scheme.primary)),
                                    ],
                                  ),
                                ),
                            ],
                          ),
                        ),
                        // The "open" button: where the file is (the folder, or
                        // Photos / the gallery for photos and videos on a phone).
                        if (t.inGallery)
                          IconButton(
                            tooltip: 'Open in ${Gallery.name}',
                            icon: const Icon(Icons.photo_library_outlined, size: 20),
                            onPressed: () => Gallery.open(t.galleryUri),
                          )
                        else if (t.localPath != null && canRevealFiles)
                          IconButton(
                            tooltip: revealLabel,
                            icon: const Icon(Icons.folder_open_outlined, size: 20),
                            onPressed: () => revealInFolder(t.localPath!),
                          ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Explains how one file was protected, from what the connection reported.
void showTransferSecurity(BuildContext context, AppState state, Transfer t) {
  final security = t.security!;
  final peer = t.peerFingerprint;
  final code = peer == null ? null : securityCode(state.identity.fingerprint, peer);
  final cert = security.certificate;
  String grouped(String hex) => [for (var i = 0; i < 32 && i < hex.length; i += 4) hex.substring(i, i + 4)].join(' ');
  showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      icon: const Icon(Icons.lock_outline),
      title: Text(security.bluetooth ? 'Encrypted over Bluetooth' : 'Encrypted over Wi-Fi'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            security.bluetooth
                ? '"${t.name}" was cut into pieces and every piece was encrypted with AES-256-GCM, using the key '
                      'only ${t.deviceName} and this device have (made when you paired them). Each piece is also '
                      'checked for tampering, and a copy recorded and replayed later is refused.'
                : '"${t.name}" traveled over TLS, the same encryption banks and HTTPS websites use. Before sending '
                      'anything, Sidekick checked that ${t.deviceName} presented the exact certificate it paired with.',
          ),
          if (cert != null) ...[
            const SizedBox(height: 12),
            Text('Certificate of ${t.deviceName}', style: Theme.of(context).textTheme.titleSmall),
            SelectableText('${grouped(cert)}…', style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
          ],
          if (code != null) ...[
            const SizedBox(height: 12),
            Text('Security code', style: Theme.of(context).textTheme.titleSmall),
            Text(code, style: Theme.of(context).textTheme.titleLarge?.copyWith(letterSpacing: 2)),
            const SizedBox(height: 4),
            Text(
              'Matches the code ${t.deviceName} shows for this device (Settings → Paired devices)? Then nobody '
              'could read this file on the way.',
              style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant),
            ),
          ],
        ],
      ),
      actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Done'))],
    ),
  );
}

import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import 'package:material_ui/material_ui.dart';

import '../app_state.dart';
import '../core/models.dart';

IconData platformIcon(DevicePlatform platform) => switch (platform) {
  DevicePlatform.windows => Icons.desktop_windows_outlined,
  DevicePlatform.macos => Icons.laptop_mac_outlined,
  DevicePlatform.linux => Icons.computer_outlined,
  DevicePlatform.android => Icons.phone_android_outlined,
  DevicePlatform.ios => Icons.phone_iphone_outlined,
  DevicePlatform.unknown => Icons.devices_other_outlined,
};

String formatBytes(int bytes) {
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  var value = bytes.toDouble();
  var unit = 0;
  while (value >= 1000 && unit < units.length - 1) {
    value /= 1000;
    unit++;
  }
  return unit == 0 ? '$bytes B' : '${value.toStringAsFixed(value < 10 ? 1 : 0)} ${units[unit]}';
}

String formatDuration(Duration d) {
  final h = d.inHours;
  final m = d.inMinutes.remainder(60);
  final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
  return h > 0 ? '$h:${m.toString().padLeft(2, '0')}:$s' : '$m:$s';
}

/// Lets the screenshot tool preview the phone UI on a desktop.
bool debugForceMobile = false;

/// Running on a phone or tablet (touch-first, soft keyboard).
bool get isMobile => debugForceMobile || Platform.isAndroid || Platform.isIOS;

/// Screens narrower than this get the compact phone layout.
const compactWidth = 600.0;

/// Page scaffold with a large title, used by every tab.
class PageFrame extends StatelessWidget {
  const PageFrame({super.key, required this.title, this.actions = const [], required this.child, this.scroll = true});

  final String title;
  final List<Widget> actions;
  final Widget child;
  final bool scroll;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final compact = MediaQuery.sizeOf(context).width < compactWidth;
    final side = compact ? 16.0 : 28.0;
    final titleText = Text(title, style: text.headlineMedium?.copyWith(fontWeight: FontWeight.w600));
    // On phones the actions go under the title so they never overflow.
    final header = Padding(
      padding: EdgeInsets.fromLTRB(side, compact ? 16 : 24, compact ? 16 : 20, 12),
      child: compact
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                titleText,
                if (actions.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Wrap(spacing: 4, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: actions),
                ],
              ],
            )
          : Row(
              children: [
                Expanded(child: titleText),
                ...actions,
              ],
            ),
    );
    final body = Padding(padding: EdgeInsets.fromLTRB(side, 4, side, side), child: child);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        header,
        Expanded(child: scroll ? SingleChildScrollView(child: body) : body),
      ],
    );
  }
}

class SectionLabel extends StatelessWidget {
  const SectionLabel(this.text, {super.key});
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 20, bottom: 10, left: 4),
    child: Text(
      text,
      style: Theme.of(context).textTheme.titleSmall?.copyWith(color: Theme.of(context).colorScheme.primary),
    ),
  );
}

class EmptyState extends StatelessWidget {
  const EmptyState({super.key, required this.icon, required this.title, required this.message, this.action});

  final IconData icon;
  final String title;
  final String message;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 380),
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 72,
                height: 72,
                decoration: BoxDecoration(color: scheme.secondaryContainer, borderRadius: BorderRadius.circular(24)),
                child: Icon(icon, size: 34, color: scheme.onSecondaryContainer),
              ),
              const SizedBox(height: 20),
              Text(title, style: Theme.of(context).textTheme.titleLarge, textAlign: TextAlign.center),
              const SizedBox(height: 8),
              Text(
                message,
                textAlign: TextAlign.center,
                style: TextStyle(color: scheme.onSurfaceVariant),
              ),
              if (action != null) ...[const SizedBox(height: 20), action!],
            ],
          ),
        ),
      ),
    );
  }
}

/// Chooses which paired device the Files, Remote and Media tabs act on.
/// Shows an empty state when nothing is paired yet.
class DeviceGate extends StatelessWidget {
  const DeviceGate({
    super.key,
    required this.state,
    required this.feature,
    required this.icon,
    required this.builder,
    this.onGoToDevices,
  });

  final AppState state;
  final String feature;
  final IconData icon;
  final Widget Function(BuildContext context, PairedDevice device) builder;
  final VoidCallback? onGoToDevices;

  @override
  Widget build(BuildContext context) {
    final device = state.selected;
    if (device == null) {
      return EmptyState(
        icon: icon,
        title: 'Pair a device first',
        message:
            'Install Sidekick on your phone or another computer, then pair with it on the Devices tab to use $feature.',
        action: onGoToDevices == null
            ? null
            : FilledButton.tonalIcon(
                onPressed: onGoToDevices,
                icon: const Icon(Icons.devices_outlined),
                label: const Text('Go to Devices'),
              ),
      );
    }
    return builder(context, device);
  }
}

/// Dropdown chip for switching the target device.
class DevicePicker extends StatelessWidget {
  const DevicePicker({super.key, required this.state});
  final AppState state;

  @override
  Widget build(BuildContext context) {
    final devices = state.paired;
    final current = state.selected;
    if (current == null) return const SizedBox.shrink();
    if (devices.length < 2) {
      // Nothing to switch to: show which device, without a dead button.
      return Chip(
        avatar: _OnlineIcon(state: state, device: current),
        label: Text(current.name),
      );
    }
    return MenuAnchor(
      builder: (context, controller, _) => FilledButton.tonalIcon(
        onPressed: () => controller.isOpen ? controller.close() : controller.open(),
        icon: _OnlineIcon(state: state, device: current),
        label: Row(mainAxisSize: MainAxisSize.min, children: [Text(current.name), const Icon(Icons.arrow_drop_down)]),
      ),
      menuChildren: [
        for (final d in devices)
          MenuItemButton(
            leadingIcon: _OnlineIcon(state: state, device: d),
            onPressed: () => state.select(d.id),
            child: Text(d.name),
          ),
      ],
    );
  }
}

class _OnlineIcon extends StatelessWidget {
  const _OnlineIcon({required this.state, required this.device});
  final AppState state;
  final PairedDevice device;

  @override
  Widget build(BuildContext context) => Badge(
    smallSize: 8,
    backgroundColor: state.isOnline(device.id) ? Colors.green : Theme.of(context).colorScheme.outline,
    child: Icon(platformIcon(device.platform), size: 20),
  );
}

/// A banner shown when [device] isn't reachable right now.
class OfflineBanner extends StatelessWidget {
  const OfflineBanner({super.key, required this.state, required this.device});
  final AppState state;
  final PairedDevice device;

  @override
  Widget build(BuildContext context) {
    if (state.isOnline(device.id)) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(color: scheme.errorContainer, borderRadius: BorderRadius.circular(16)),
      child: Row(
        children: [
          Icon(Icons.cloud_off_outlined, color: scheme.onErrorContainer),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              "${device.name} isn't reachable. Make sure Sidekick is open on it and both devices are on the same Wi-Fi.",
              style: TextStyle(color: scheme.onErrorContainer),
            ),
          ),
        ],
      ),
    );
  }
}

/// Drag-and-drop target, except on iOS where the plugin doesn't exist.
class MaybeDropTarget extends StatelessWidget {
  const MaybeDropTarget({super.key, required this.child, required this.onFiles, this.onHover, this.enable = true});

  final Widget child;
  final void Function(List<File> files) onFiles;

  /// Called with true when files are dragged over, false when they leave.
  final void Function(bool hovering)? onHover;
  final bool enable;

  @override
  Widget build(BuildContext context) {
    if (Platform.isIOS) return child;
    return DropTarget(
      enable: enable,
      onDragEntered: (_) => onHover?.call(true),
      onDragExited: (_) => onHover?.call(false),
      onDragDone: (details) {
        onHover?.call(false);
        onFiles([for (final f in details.files) File(f.path)]);
      },
      child: child,
    );
  }
}

/// Lets the user pick files to send. Phones get a choice between the photo
/// gallery and the file browser.
Future<List<File>> pickFilesToSend(BuildContext context, {required String title}) async {
  var type = FileType.any;
  if (isMobile) {
    final choice = await showModalBottomSheet<FileType>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('Photos & videos'),
              onTap: () => Navigator.pop(context, FileType.media),
            ),
            ListTile(
              leading: const Icon(Icons.folder_outlined),
              title: const Text('Files'),
              onTap: () => Navigator.pop(context, FileType.any),
            ),
          ],
        ),
      ),
    );
    if (choice == null) return const [];
    type = choice;
  }
  final picked = await FilePicker.pickFiles(dialogTitle: title, type: type);
  return [
    for (final f in picked)
      if (f.path != null) File(f.path!),
  ];
}

void showError(BuildContext context, Object error) {
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$error')));
}

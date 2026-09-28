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
    final header = Padding(
      padding: const EdgeInsets.fromLTRB(28, 24, 20, 12),
      child: Row(
        children: [
          Expanded(
            child: Text(title, style: text.headlineMedium?.copyWith(fontWeight: FontWeight.w600)),
          ),
          ...actions,
        ],
      ),
    );
    final body = Padding(padding: const EdgeInsets.fromLTRB(28, 4, 28, 28), child: child);
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

void showError(BuildContext context, Object error) {
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$error')));
}

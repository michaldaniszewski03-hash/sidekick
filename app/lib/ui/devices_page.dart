import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';

import '../app_state.dart';
import '../core/bluetooth.dart';
import '../core/models.dart';
import 'bluetooth_pairing.dart';
import 'widgets.dart';

class DevicesPage extends StatelessWidget {
  const DevicesPage({super.key, required this.state, required this.onOpen});

  final AppState state;

  /// Switches to a tab (1 Files, 2 Remote, 3 Media).
  final void Function(int tab) onOpen;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: state,
      builder: (context, _) {
        final paired = state.paired;
        final nearby = state.nearby;
        final online = paired.where((d) => state.isOnline(d.id)).length;
        return PageFrame(
          title: 'Devices',
          subtitle: paired.isEmpty
              ? 'Pair your phone or computer to get started'
              : '${paired.length} paired · $online connected'
                    '${nearby.isEmpty ? '' : ' · ${nearby.length} nearby'}',
          actions: [
            // One button; the ways to add a device are in its menu.
            MenuAnchor(
              alignmentOffset: const Offset(0, 6),
              builder: (context, controller, _) => FilledButton.tonalIcon(
                onPressed: () => controller.isOpen ? controller.close() : controller.open(),
                icon: const Icon(Icons.add_rounded),
                label: const Text('Add device'),
              ),
              menuChildren: [
                MenuItemButton(
                  leadingIcon: const Icon(Icons.wifi_find_rounded),
                  onPressed: state.scanning ? null : state.scanNetwork,
                  child: Text(state.scanning ? 'Searching Wi-Fi…' : 'Search Wi-Fi'),
                ),
                if (state.bluetooth != null)
                  MenuItemButton(
                    leadingIcon: const Icon(Icons.bluetooth_searching_rounded),
                    onPressed: () => showBluetoothPairing(context, state),
                    child: const Text('Pair over Bluetooth'),
                  ),
                MenuItemButton(
                  leadingIcon: const Icon(Icons.add_link_rounded),
                  onPressed: () => _addByIp(context),
                  child: const Text('Add by IP address'),
                ),
              ],
            ),
          ],
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Entrance(child: _ThisDeviceCard(state: state)),
              if (paired.isNotEmpty) ...[
                const SectionLabel('Paired', icon: Icons.link_rounded),
                LayoutBuilder(
                  // Fixed-width cards on desktop, full width on phones.
                  builder: (context, constraints) => Wrap(
                    spacing: 16,
                    runSpacing: 16,
                    children: [
                      for (final (i, d) in paired.indexed)
                        SizedBox(
                          width: constraints.maxWidth < 400 ? constraints.maxWidth : 360,
                          child: Entrance(
                            key: ValueKey(d.id),
                            index: i + 1,
                            child: _PairedCard(state: state, device: d, onOpen: onOpen),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
              const SectionLabel('Nearby', icon: Icons.near_me_outlined),
              if (nearby.isEmpty)
                Entrance(
                  index: paired.length + 1,
                  child: _Searching(state: state),
                )
              else
                Card.filled(
                  clipBehavior: Clip.antiAlias,
                  child: Column(
                    children: [
                      for (final d in nearby)
                        ListTile(
                          contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 6),
                          leading: IconTile(platformIcon(d.platform), size: 44),
                          title: Text(d.name),
                          subtitle: Row(
                            children: [
                              Icon(
                                d.address == null ? Icons.bluetooth_rounded : Icons.wifi_rounded,
                                size: 14,
                                color: Theme.of(context).colorScheme.onSurfaceVariant,
                              ),
                              const SizedBox(width: 4),
                              Flexible(child: Text(d.address ?? 'Nearby over Bluetooth', maxLines: 1)),
                            ],
                          ),
                          trailing: FilledButton.icon(
                            onPressed: () => pairWith(context, state, d),
                            icon: const Icon(Icons.link_rounded, size: 18),
                            label: const Text('Pair'),
                          ),
                        ),
                      // Always reachable, not only when nothing's nearby.
                      if (state.bluetooth != null)
                        ListTile(
                          contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 6),
                          leading: const IconTile(Icons.bluetooth_searching_rounded, tone: TileTone.tertiary, size: 44),
                          title: const Text('Pair over Bluetooth'),
                          subtitle: const Text('For a device that isn\'t on this Wi-Fi'),
                          trailing: const Icon(Icons.chevron_right),
                          onTap: () => showBluetoothPairing(context, state),
                        ),
                    ],
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _addByIp(BuildContext context) async {
    final controller = TextEditingController();
    final address = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Add a device by IP'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text("Use this if the device doesn't show up by itself. Its IP address is shown on its Devices tab."),
            const SizedBox(height: 16),
            TextField(
              controller: controller,
              autofocus: true,
              decoration: const InputDecoration(labelText: 'IP address', hintText: '192.168.1.23'),
              onSubmitted: (v) => Navigator.pop(context, v),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, controller.text), child: const Text('Connect')),
        ],
      ),
    );
    if (address == null || address.trim().isEmpty || !context.mounted) return;
    try {
      final info = await state.addByAddress(address);
      if (context.mounted) await pairWith(context, state, info);
    } catch (e) {
      if (context.mounted) showError(context, e);
    }
  }
}

/// Starts pairing with [device]: it shows a code, the user types it here.
Future<void> pairWith(BuildContext context, AppState state, DeviceInfo device) async {
  try {
    await state.requestPairing(device);
  } catch (e) {
    if (context.mounted) showError(context, e);
    return;
  }
  if (!context.mounted) return;
  final paired = await showDialog<PairedDevice>(
    context: context,
    barrierDismissible: false,
    builder: (context) => _EnterPinDialog(state: state, device: device),
  );
  if (paired != null && context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            Icon(Icons.check_circle_rounded, color: Theme.of(context).colorScheme.inversePrimary),
            const SizedBox(width: 12),
            Expanded(child: Text('Paired with ${paired.name}')),
          ],
        ),
      ),
    );
  }
}

class _EnterPinDialog extends StatefulWidget {
  const _EnterPinDialog({required this.state, required this.device});
  final AppState state;
  final DeviceInfo device;

  @override
  State<_EnterPinDialog> createState() => _EnterPinDialogState();
}

class _EnterPinDialogState extends State<_EnterPinDialog> {
  final _controller = TextEditingController();
  String? _error;
  bool _busy = false;

  Future<void> _submit() async {
    if (_controller.text.length != 6 || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final paired = await widget.state.confirmPairing(widget.device, _controller.text);
      if (mounted) Navigator.pop(context, paired);
    } catch (e) {
      setState(() {
        _busy = false;
        _error = '$e';
        _controller.clear();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      icon: Icon(platformIcon(widget.device.platform)),
      title: Text('Pair with ${widget.device.name}'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('Type the 6-digit code shown on ${widget.device.name}.', textAlign: TextAlign.center),
          const SizedBox(height: 20),
          SizedBox(
            width: 220,
            child: TextField(
              controller: _controller,
              autofocus: true,
              enabled: !_busy,
              textAlign: TextAlign.center,
              keyboardType: TextInputType.number,
              maxLength: 6,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              style: Theme.of(context).textTheme.headlineMedium?.copyWith(letterSpacing: 8),
              decoration: InputDecoration(counterText: '', errorText: _error, errorMaxLines: 3),
              onChanged: (v) {
                if (v.length == 6) _submit();
              },
              onSubmitted: (_) => _submit(),
            ),
          ),
          if (_busy) const Padding(padding: EdgeInsets.only(top: 16), child: LinearProgressIndicator()),
        ],
      ),
      actions: [
        TextButton(onPressed: _busy ? null : () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(onPressed: _busy ? null : _submit, child: const Text('Pair')),
      ],
    );
  }
}

class _ThisDeviceCard extends StatelessWidget {
  const _ThisDeviceCard({required this.state});
  final AppState state;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final error = state.networkError;
    final bt = state.bluetooth;
    final onCard = error == null ? scheme.onPrimaryContainer : scheme.onErrorContainer;
    final wifi = state.addresses.isNotEmpty;
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(32),
        gradient: error == null
            ? LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [scheme.primaryContainer, scheme.tertiaryContainer],
              )
            : null,
        color: error == null ? null : scheme.errorContainer,
      ),
      padding: const EdgeInsets.all(24),
      child: Row(
        children: [
          GradientBadge(icon: platformIcon(state.me.platform), size: 64),
          const SizedBox(width: 20),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('This device', style: text.labelLarge?.copyWith(color: onCard.withValues(alpha: 0.75))),
                Text(state.name, style: text.headlineSmall?.copyWith(color: onCard)),
                const SizedBox(height: 10),
                if (error != null)
                  Text(error, style: TextStyle(color: onCard))
                else
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      StatusPill(
                        icon: wifi ? Icons.wifi_rounded : Icons.wifi_off_rounded,
                        label: wifi ? state.addresses.join(', ') : 'No Wi-Fi',
                        color: wifi ? Colors.green : scheme.outline,
                        background: scheme.surface.withValues(alpha: 0.7),
                      ),
                      if (bt != null)
                        StatusPill(
                          icon: bt.status == BluetoothStatus.on
                              ? Icons.bluetooth_connected_rounded
                              : Icons.bluetooth_disabled_rounded,
                          label: bt.advertising
                              ? 'Findable'
                              : bt.status == BluetoothStatus.on
                              ? 'Can search'
                              : 'Off',
                          color: bt.status == BluetoothStatus.on ? scheme.primary : scheme.outline,
                          background: scheme.surface.withValues(alpha: 0.7),
                        ),
                    ],
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _PairedCard extends StatefulWidget {
  const _PairedCard({required this.state, required this.device, required this.onOpen});
  final AppState state;
  final PairedDevice device;
  final void Function(int tab) onOpen;

  @override
  State<_PairedCard> createState() => _PairedCardState();
}

class _PairedCardState extends State<_PairedCard> {
  bool _dragging = false;
  bool _hover = false;

  AppState get state => widget.state;
  PairedDevice get device => widget.device;

  void _open(int tab) {
    state.select(device.id);
    widget.onOpen(tab);
  }

  Future<void> _pickAndSend() async {
    final files = await pickFilesToSend(context, title: 'Send to ${device.name}');
    if (files.isNotEmpty) await state.sendFiles(device, files);
  }

  Future<void> _confirmUnpair() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Unpair ${device.name}?'),
        content: const Text("Neither device will be able to control the other until you pair again."),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Unpair')),
        ],
      ),
    );
    if (ok == true) await state.unpair(device.id);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final online = state.isOnline(device.id);
    final caps = state.capabilitiesOf(device.id);
    final reset = state.needsRepair(device) != null;

    final status = _dragging
        ? 'Drop to send'
        : reset
        ? 'Was reset: pair again'
        : state.connectingDirect.contains(device.id)
        ? 'Setting up direct Wi-Fi…'
        : state.viaBluetooth(device.id)
        ? 'Connected via Bluetooth'
        : (online ? 'Connected' : 'Offline');

    final statusIcon = _dragging
        ? Icons.file_download_outlined
        : reset
        ? Icons.error_outline_rounded
        : state.viaBluetooth(device.id)
        ? Icons.bluetooth_connected_rounded
        : online
        ? Icons.wifi_rounded
        : Icons.cloud_off_rounded;

    return MaybeDropTarget(
      onHover: (hovering) => setState(() => _dragging = hovering),
      onFiles: (files) => state.sendFiles(device, files),
      child: MouseRegion(
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: AnimatedScale(
          scale: _dragging ? 1.03 : (_hover ? 1.012 : 1),
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOutCubic,
            padding: const EdgeInsets.fromLTRB(20, 18, 12, 20),
            decoration: BoxDecoration(
              color: _dragging ? scheme.secondaryContainer : scheme.surfaceContainerLow,
              borderRadius: BorderRadius.circular(_dragging ? 36 : 28),
              border: Border.all(color: _dragging ? scheme.primary : scheme.outlineVariant, width: _dragging ? 2 : 1),
              boxShadow: [
                BoxShadow(
                  color: scheme.shadow.withValues(alpha: _hover || _dragging ? 0.10 : 0),
                  blurRadius: 24,
                  offset: const Offset(0, 8),
                ),
              ],
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      width: 52,
                      height: 52,
                      decoration: BoxDecoration(
                        color: scheme.secondaryContainer,
                        borderRadius: BorderRadius.circular(18),
                      ),
                      child: Icon(platformIcon(device.platform), color: scheme.onSecondaryContainer, size: 26),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            device.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                          const SizedBox(height: 4),
                          StatusPill(
                            icon: statusIcon,
                            label: status,
                            color: reset ? scheme.error : (online ? Colors.green : scheme.outline),
                            background: _dragging ? scheme.surface : null,
                          ),
                        ],
                      ),
                    ),
                    PopupMenuButton<String>(
                      tooltip: 'More',
                      icon: const Icon(Icons.more_horiz_rounded),
                      onSelected: (v) => v == 'unpair' ? _confirmUnpair() : null,
                      itemBuilder: (_) => const [
                        PopupMenuItem(
                          value: 'unpair',
                          child: ListTile(leading: Icon(Icons.link_off_rounded), title: Text('Unpair')),
                        ),
                      ],
                    ),
                  ],
                ),
                const SizedBox(height: 18),
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: reset
                      ? SizedBox(
                          width: double.infinity,
                          child: FilledButton.icon(
                            onPressed: () => pairWith(context, state, state.forgetForRepair(device)),
                            icon: const Icon(Icons.link, size: 18),
                            label: const Text('Pair again'),
                          ),
                        )
                      : Row(
                          children: [
                            Expanded(
                              child: FilledButton.icon(
                                onPressed: online ? _pickAndSend : null,
                                icon: const Icon(Icons.send_rounded, size: 18),
                                label: const Text('Send files'),
                              ),
                            ),
                            if (caps?.files ?? true) ...[
                              const SizedBox(width: 8),
                              IconButton.filledTonal(
                                tooltip: 'Browse files',
                                onPressed: () => _open(1),
                                icon: const Icon(Icons.folder_open_outlined),
                              ),
                            ],
                            if (caps?.input ?? true) ...[
                              const SizedBox(width: 4),
                              IconButton.filledTonal(
                                tooltip: 'Remote control',
                                onPressed: () => _open(2),
                                icon: const Icon(Icons.mouse_outlined),
                              ),
                            ],
                            if (caps?.media ?? true) ...[
                              const SizedBox(width: 4),
                              IconButton.filledTonal(
                                tooltip: 'Media',
                                onPressed: () => _open(3),
                                icon: const Icon(Icons.play_circle_outline),
                              ),
                            ],
                          ],
                        ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Searching extends StatelessWidget {
  const _Searching({required this.state});
  final AppState state;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final offline = state.addresses.isEmpty;
    final bt = state.bluetooth;
    final bluetoothOff = bt == null || bt.status != BluetoothStatus.on;
    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(color: scheme.surfaceContainerLow, borderRadius: BorderRadius.circular(28)),
      child: Row(
        children: [
          Radar(icon: offline ? Icons.bluetooth_searching_rounded : Icons.wifi_find_rounded, size: 72),
          const SizedBox(width: 18),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  bluetoothOff && offline ? 'Turn on Bluetooth to find devices' : 'Looking for devices…',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 4),
                Text(
                  offline
                      ? bluetoothOff
                            ? 'No Wi-Fi here. Turn on Bluetooth, and open Sidekick on the other device.'
                            : 'Searching over Bluetooth. Open Sidekick on the other device.'
                      : 'Open Sidekick on your other device and it shows up here.'
                            '${Platform.isWindows ? ' If Windows asks, allow Sidekick on private networks.' : ''}',
                  style: TextStyle(color: scheme.onSurfaceVariant),
                ),
                if (bt != null) ...[
                  const SizedBox(height: 12),
                  FilledButton.tonalIcon(
                    onPressed: () => showBluetoothPairing(context, state),
                    icon: const Icon(Icons.bluetooth_searching_rounded),
                    label: const Text('Pair over Bluetooth'),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

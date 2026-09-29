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
            TextButton.icon(
              onPressed: state.scanning ? null : state.scanNetwork,
              icon: state.scanning
                  ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.radar),
              label: const Text('Search'),
            ),
            if (state.bluetooth != null)
              TextButton.icon(
                onPressed: () => showBluetoothPairing(context, state),
                icon: const Icon(Icons.bluetooth_searching),
                label: const Text('Bluetooth'),
              ),
            TextButton.icon(
              onPressed: () => _addByIp(context),
              icon: const Icon(Icons.add_link),
              label: const Text('Add by IP'),
            ),
          ],
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _ThisDeviceCard(state: state),
              if (paired.isNotEmpty) ...[
                const SectionLabel('Paired'),
                LayoutBuilder(
                  // Fixed-width cards on desktop, full width on phones.
                  builder: (context, constraints) => Wrap(
                    spacing: 16,
                    runSpacing: 16,
                    children: [
                      for (final d in paired)
                        SizedBox(
                          width: constraints.maxWidth < 400 ? constraints.maxWidth : 360,
                          child: _PairedCard(state: state, device: d, onOpen: onOpen),
                        ),
                    ],
                  ),
                ),
              ],
              const SectionLabel('Nearby'),
              if (nearby.isEmpty)
                _Searching(state: state)
              else
                Card.filled(
                  clipBehavior: Clip.antiAlias,
                  child: Column(
                    children: [
                      for (final d in nearby)
                        ListTile(
                          contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 6),
                          leading: CircleAvatar(radius: 22, child: Icon(platformIcon(d.platform))),
                          title: Text(d.name),
                          subtitle: Text('${d.platform.name} · ${d.address ?? 'nearby over Bluetooth'}'),
                          trailing: FilledButton(
                            onPressed: () => pairWith(context, state, d),
                            child: const Text('Pair'),
                          ),
                        ),
                      // Always reachable, not only when nothing's nearby.
                      if (state.bluetooth != null)
                        ListTile(
                          contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 6),
                          leading: const CircleAvatar(child: Icon(Icons.bluetooth_searching)),
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
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Paired with ${paired.name}')));
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
                        label: wifi ? 'Wi-Fi · ${state.addresses.join(', ')}' : 'No Wi-Fi',
                        color: wifi ? Colors.green : scheme.outline,
                        background: scheme.surface.withValues(alpha: 0.7),
                      ),
                      if (bt != null)
                        StatusPill(
                          label: bt.advertising
                              ? 'Bluetooth · findable'
                              : bt.status == BluetoothStatus.on
                              ? 'Bluetooth · can search'
                              : 'Bluetooth off',
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

    return MaybeDropTarget(
      onHover: (hovering) => setState(() => _dragging = hovering),
      onFiles: (files) => state.sendFiles(device, files),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
        padding: const EdgeInsets.fromLTRB(20, 18, 12, 20),
        decoration: BoxDecoration(
          color: _dragging ? scheme.secondaryContainer : scheme.surfaceContainerLow,
          borderRadius: BorderRadius.circular(_dragging ? 36 : 28),
          border: Border.all(color: _dragging ? scheme.primary : scheme.outlineVariant, width: _dragging ? 2 : 1),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 52,
                  height: 52,
                  decoration: BoxDecoration(color: scheme.secondaryContainer, borderRadius: BorderRadius.circular(18)),
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
                        label: status,
                        color: reset ? scheme.error : (online ? Colors.green : scheme.outline),
                        background: _dragging ? scheme.surface : null,
                      ),
                    ],
                  ),
                ),
                PopupMenuButton<String>(
                  tooltip: 'More',
                  onSelected: (v) => v == 'unpair' ? _confirmUnpair() : null,
                  itemBuilder: (_) => const [
                    PopupMenuItem(
                      value: 'unpair',
                      child: ListTile(leading: Icon(Icons.link_off), title: Text('Unpair')),
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
          Container(
            width: 56,
            height: 56,
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(color: scheme.secondaryContainer, shape: BoxShape.circle),
            child: CircularProgressIndicator(strokeWidth: 3, color: scheme.onSecondaryContainer),
          ),
          const SizedBox(width: 20),
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
                            ? "There's no Wi-Fi here, so Sidekick finds nearby devices over Bluetooth. Turn it on, "
                                  'and open Sidekick on the other device too.'
                            : 'No Wi-Fi here: searching over Bluetooth. Open Sidekick on the other device and keep '
                                  'it on screen; it shows up here within a few seconds.'
                      : 'Open Sidekick on your other device. On the same Wi-Fi it appears right away; elsewhere, '
                            'with Bluetooth on, it appears when it\'s close by.'
                            '${Platform.isWindows ? ' If Windows asks, allow Sidekick on private networks.' : ''}',
                  style: TextStyle(color: scheme.onSurfaceVariant),
                ),
                if (bt != null) ...[
                  const SizedBox(height: 12),
                  FilledButton.tonalIcon(
                    onPressed: () => showBluetoothPairing(context, state),
                    icon: const Icon(Icons.bluetooth_searching),
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

import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';

import '../app_state.dart';
import '../core/bluetooth.dart';
import '../core/models.dart';
import '../core/pairing_qr.dart';
import 'bluetooth_pairing.dart';
import 'qr_pairing.dart';
import 'widgets.dart';

class DevicesPage extends StatelessWidget {
  const DevicesPage({super.key, required this.state, required this.onOpen});

  final AppState state;

  /// Switches to a tab (1 Files, 2 Remote).
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
            // One button; the ways to connect a device are in its menu,
            // each with a line saying when to use it.
            MenuAnchor(
              alignmentOffset: const Offset(0, 6),
              builder: (context, controller, _) => FilledButton.tonalIcon(
                onPressed: () => controller.isOpen ? controller.close() : controller.open(),
                icon: const Icon(Icons.add_link_rounded),
                label: const Text('Connect device'),
              ),
              menuChildren: [
                MenuItemButton(
                  leadingIcon: const Icon(Icons.wifi_rounded),
                  onPressed: state.scanning ? null : state.scanNetwork,
                  child: _MenuOption(
                    title: 'Wi-Fi',
                    detail: state.scanning ? 'Looking on this network…' : 'Find devices on the same Wi-Fi',
                  ),
                ),
                if (state.bluetooth != null)
                  MenuItemButton(
                    leadingIcon: const Icon(Icons.bluetooth_rounded),
                    onPressed: () => showBluetoothPairing(context, state),
                    child: const _MenuOption(title: 'Bluetooth', detail: 'When there\'s no shared Wi-Fi'),
                  ),
                MenuItemButton(
                  leadingIcon: const Icon(Icons.qr_code_2_rounded),
                  onPressed: () => showMyQrCode(context, state),
                  child: _MenuOption(
                    title: 'QR code',
                    detail: canScanQr ? 'Show or scan a code, nothing to type' : 'Show a code to scan with your phone',
                  ),
                ),
                MenuItemButton(
                  leadingIcon: const Icon(Icons.dialpad_rounded),
                  onPressed: () => _addByIp(context),
                  child: const _MenuOption(title: 'IP address', detail: 'Type the other device\'s address'),
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
  if (paired != null && context.mounted) showPaired(context, paired);
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

  /// Scans the QR code next to the 6-digit code instead of typing it. It's
  /// the same QR code as everywhere else (an invite), which pairs on its own.
  Future<void> _scan() async {
    final code = await scanPairingQr(context);
    if (code == null || !mounted) return;
    switch (code) {
      case InviteQr() when code.id == widget.device.id:
        setState(() {
          _busy = true;
          _error = null;
        });
        try {
          final paired = await widget.state.pairWithInvite(code);
          if (mounted) Navigator.pop(context, paired);
        } catch (e) {
          if (mounted) {
            setState(() {
              _busy = false;
              _error = '$e';
            });
          }
        }
      // A device before 2.6.2 shows the 6 digits as a QR code.
      case PinQr() when code.id == widget.device.id:
        _controller.text = code.pin;
        await _submit();
      default:
        setState(
          () => _error = "That's not the code ${widget.device.name} is showing. Scan the one next to the 6 digits.",
        );
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
          if (canScanQr) ...[
            const SizedBox(height: 16),
            OutlinedButton.icon(
              onPressed: _busy ? null : _scan,
              icon: const Icon(Icons.qr_code_scanner_rounded),
              label: const Text('Scan the QR code instead'),
            ),
          ],
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
        ? 'Pair again'
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
                          if (state.runsOlderApp(device))
                            Padding(
                              padding: const EdgeInsets.only(top: 6),
                              child: Tooltip(
                                message:
                                    '${device.name} runs ${state.appVersionOf(device) == null ? 'an older Sidekick' : 'Sidekick ${state.appVersionOf(device)}'}'
                                    ', this device ${state.appVersion}. Update it so they work well together.',
                                child: const StatusPill(
                                  icon: Icons.system_update_rounded,
                                  label: 'Update Sidekick on it',
                                  color: Colors.orange,
                                ),
                              ),
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

/// A menu entry: what it is, and a short line on when to use it.
class _MenuOption extends StatelessWidget {
  const _MenuOption({required this.title, required this.detail});
  final String title;
  final String detail;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(title, style: text.titleSmall),
          Text(detail, style: text.bodySmall?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant)),
        ],
      ),
    );
  }
}

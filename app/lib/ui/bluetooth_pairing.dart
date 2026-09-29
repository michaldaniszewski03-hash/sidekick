import 'package:material_ui/material_ui.dart';

import '../app_state.dart';
import '../core/bluetooth.dart';
import 'devices_page.dart';
import 'widgets.dart';

/// Pairing over Bluetooth, for when there's no Wi-Fi: searches the whole
/// time it's open and lists every Sidekick device it hears, with what's
/// happening (reading its name, or why that failed).
Future<void> showBluetoothPairing(BuildContext context, AppState state) {
  final page = _BluetoothPairing(state: state);
  if (isMobile) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      useSafeArea: true,
      builder: (_) => FractionallySizedBox(heightFactor: 0.85, child: page),
    );
  }
  return showDialog<void>(
    context: context,
    builder: (_) => Dialog(
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 520, maxHeight: 640), child: page),
    ),
  );
}

class _BluetoothPairing extends StatefulWidget {
  const _BluetoothPairing({required this.state});
  final AppState state;

  @override
  State<_BluetoothPairing> createState() => _BluetoothPairingState();
}

class _BluetoothPairingState extends State<_BluetoothPairing> {
  AppState get state => widget.state;

  @override
  void initState() {
    super.initState();
    state.bluetooth?.startSearch();
  }

  @override
  void dispose() {
    state.bluetooth?.stopSearch();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return ListenableBuilder(
      listenable: state,
      builder: (context, _) {
        final bt = state.bluetooth;
        final candidates = bt == null
            ? <MapEntry<String, BleCandidate>>[]
            : (bt.candidates.entries.toList()..sort((a, b) => b.value.rssi.compareTo(a.value.rssi)));
        return Padding(
          padding: const EdgeInsets.fromLTRB(24, 16, 24, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Icon(Icons.bluetooth_searching, color: scheme.primary, size: 28),
                  const SizedBox(width: 12),
                  Expanded(child: Text('Pair over Bluetooth', style: text.headlineSmall)),
                  IconButton(
                    tooltip: 'Close',
                    onPressed: () => Navigator.of(this.context).maybePop(),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                'For when there\'s no Wi-Fi. Open Sidekick on the other device with Bluetooth on and keep it on '
                'screen. It shows up here within a few seconds.',
                style: TextStyle(color: scheme.onSurfaceVariant),
              ),
              const SizedBox(height: 16),
              _Status(state: state),
              const SizedBox(height: 16),
              Expanded(
                child: candidates.isEmpty
                    ? Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (bt?.status == BluetoothStatus.on) const CircularProgressIndicator(),
                            const SizedBox(height: 16),
                            Text(
                              bt?.status == BluetoothStatus.on
                                  ? 'Searching for Sidekick devices nearby…'
                                  : 'Waiting for Bluetooth…',
                              textAlign: TextAlign.center,
                            ),
                            if (bt?.lastDevicesAround case final around?) ...[
                              const SizedBox(height: 8),
                              Text(
                                around == 0
                                    ? "This device doesn't hear any Bluetooth devices at all right now."
                                    : 'Hears $around Bluetooth device${around == 1 ? '' : 's'} around, but none '
                                          'running Sidekick yet.',
                                textAlign: TextAlign.center,
                                style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
                              ),
                            ],
                          ],
                        ),
                      )
                    : ListView(
                        children: [
                          for (final MapEntry(:key, value: c) in candidates) _row(context, key, c),
                          if (bt?.searching ?? false)
                            const Padding(padding: EdgeInsets.all(16), child: LinearProgressIndicator()),
                        ],
                      ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _row(BuildContext context, String key, BleCandidate c) {
    final scheme = Theme.of(context).colorScheme;
    final info = c.info;
    final paired = info == null ? null : state.pairedById(info.id);
    final signal = c.rssi == 0 ? '' : ' · ${_signal(c.rssi)}';
    return Card.filled(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        leading: CircleAvatar(
          child: info == null
              ? (c.identifying
                    ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.bluetooth))
              : Icon(platformIcon(info.platform)),
        ),
        title: Text(info?.name ?? (c.error == null ? 'Sidekick device' : 'Couldn\'t connect')),
        subtitle: Text(
          info != null
              ? '${info.platform.name}$signal'
              : c.error != null
              ? '${c.error}$signal'
              : 'Reading its name…$signal',
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(color: c.error != null && info == null ? scheme.error : null),
        ),
        trailing: info == null
            ? (c.error != null
                  ? TextButton(onPressed: () => state.bluetooth?.retry(key), child: const Text('Retry'))
                  : null)
            : paired != null && state.needsRepair(paired) == null
            ? const Chip(avatar: Icon(Icons.check, size: 16), label: Text('Paired'))
            : FilledButton(
                onPressed: () {
                  if (paired != null) state.forgetForRepair(paired);
                  pairWith(context, state, info);
                },
                child: Text(paired != null ? 'Pair again' : 'Pair'),
              ),
      ),
    );
  }

  static String _signal(int rssi) => rssi > -60
      ? 'very close'
      : rssi > -75
      ? 'nearby'
      : 'far';
}

class _Status extends StatelessWidget {
  const _Status({required this.state});
  final AppState state;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final bt = state.bluetooth;
    final (icon, message, action) = switch (bt?.status) {
      null || BluetoothStatus.unsupported => (Icons.bluetooth_disabled, 'This device has no Bluetooth LE.', null),
      BluetoothStatus.off => (Icons.bluetooth_disabled, 'Bluetooth is off. Turn it on to pair.', null),
      BluetoothStatus.unauthorized => (
        Icons.bluetooth_disabled,
        'Sidekick isn\'t allowed to use Bluetooth.',
        TextButton(onPressed: bt!.requestPermission, child: const Text('Allow')),
      ),
      BluetoothStatus.starting => (Icons.bluetooth, 'Starting Bluetooth…', null),
      BluetoothStatus.on => (
        Icons.bluetooth_connected,
        bt!.advertising
            ? 'Other devices can find this one as "${state.name}".'
            : 'This device can search, but can\'t be found. Search from here.',
        null,
      ),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(color: scheme.secondaryContainer, borderRadius: BorderRadius.circular(16)),
      child: Row(
        children: [
          Icon(icon, color: scheme.onSecondaryContainer),
          const SizedBox(width: 12),
          Expanded(
            child: Text(message, style: TextStyle(color: scheme.onSecondaryContainer)),
          ),
          ?action,
        ],
      ),
    );
  }
}

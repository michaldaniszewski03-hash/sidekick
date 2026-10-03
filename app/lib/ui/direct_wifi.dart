import 'dart:async';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../app_state.dart';

/// iPhone: the other device opened a network for a direct link, but this
/// build can't join it by itself. Shows its name and password to join in
/// Settings → Wi-Fi, and closes once the iPhone is on it.
Future<void> showManualJoin(BuildContext context, ManualJoin join) async {
  final navigator = Navigator.of(context);
  var open = true;
  unawaited(
    join.done.then((_) {
      if (open) navigator.pop();
    }),
  );
  await showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (context) => _ManualJoinDialog(join: join),
  );
  open = false;
}

class _ManualJoinDialog extends StatelessWidget {
  const _ManualJoinDialog({required this.join});
  final ManualJoin join;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final c = join.credentials;
    return AlertDialog(
      icon: const Icon(Icons.wifi_tethering_rounded),
      title: const Text('Join the direct Wi-Fi'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Open Settings → Wi-Fi, pick this network and enter the password, then come back. '
            'Files then go over Wi-Fi instead of Bluetooth.',
            style: TextStyle(color: scheme.onSurfaceVariant),
          ),
          const SizedBox(height: 16),
          _CopyRow(label: 'Network', value: c.ssid),
          const SizedBox(height: 8),
          _CopyRow(label: 'Password', value: c.passphrase),
          const SizedBox(height: 16),
          Row(
            children: [
              const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2)),
              const SizedBox(width: 12),
              Expanded(
                child: Text('Waiting for you to join…', style: TextStyle(color: scheme.onSurfaceVariant)),
              ),
            ],
          ),
        ],
      ),
      actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Not now'))],
    );
  }
}

class _CopyRow extends StatelessWidget {
  const _CopyRow({required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 6, 4, 6),
      decoration: BoxDecoration(color: scheme.surfaceContainerHighest, borderRadius: BorderRadius.circular(14)),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: Theme.of(context).textTheme.labelSmall?.copyWith(color: scheme.onSurfaceVariant)),
                SelectableText(value, style: const TextStyle(fontWeight: FontWeight.w600)),
              ],
            ),
          ),
          IconButton(
            tooltip: 'Copy',
            icon: const Icon(Icons.copy_rounded, size: 20),
            onPressed: () {
              unawaited(Clipboard.setData(ClipboardData(text: value)));
              ScaffoldMessenger.maybeOf(context)
                  ?.showSnackBar(SnackBar(content: Text('$label copied'), duration: const Duration(seconds: 1)));
            },
          ),
        ],
      ),
    );
  }
}

/// [name] isn't reachable and Bluetooth is off: asks to turn it on, since
/// it's how Sidekick finds a device on no shared network (files then go
/// over a direct Wi-Fi link). True if it was turned on.
Future<bool> askToTurnOnBluetooth(BuildContext context, AppState state, String name) async {
  final yes = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      icon: const Icon(Icons.bluetooth_searching_rounded),
      title: Text('Find $name nearby?'),
      content: const Text(
        "You're not on the same Wi-Fi. Sidekick can find it over Bluetooth, then send over a direct Wi-Fi "
        'link between the two (fast, and no router needed). Bluetooth needs to be on in Sidekick on both.',
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Not now')),
        FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Turn on Bluetooth')),
      ],
    ),
  );
  if (yes != true) return false;
  await state.setBluetooth(true);
  return true;
}

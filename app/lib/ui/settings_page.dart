import 'package:file_picker/file_picker.dart';
import 'package:material_ui/material_ui.dart';

import '../app_state.dart';
import '../core/bluetooth.dart';
import '../core/models.dart';
import 'permissions.dart';
import 'theme_chooser.dart';
import 'widgets.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key, required this.state});
  final AppState state;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late final _name = TextEditingController(text: widget.state.name);
  String? _receiveDir;

  AppState get state => widget.state;

  @override
  void initState() {
    super.initState();
    state.receiveDir().then((d) {
      if (mounted) setState(() => _receiveDir = d);
    });
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _pickReceiveDir() async {
    final dir = await FilePicker.getDirectoryPath(dialogTitle: 'Save received files to…');
    if (dir == null) return;
    state.setReceiveDir(dir);
    setState(() => _receiveDir = dir);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: state,
      builder: (context, _) {
        final perms = state.permissions;
        return PageFrame(
          title: 'Settings',
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 720),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const SectionLabel('This device'),
                  _Group(
                    children: [
                      Padding(
                        padding: const EdgeInsets.all(16),
                        child: TextField(
                          controller: _name,
                          maxLength: 40,
                          decoration: const InputDecoration(
                            labelText: 'Device name',
                            helperText: 'How this device appears to your other devices',
                            border: OutlineInputBorder(),
                          ),
                          onSubmitted: state.setName,
                          onTapOutside: (_) => state.setName(_name.text),
                        ),
                      ),
                      ListTile(
                        leading: const Icon(Icons.download_outlined),
                        title: const Text('Save received files to'),
                        subtitle: Text(_receiveDir ?? '…'),
                        trailing: TextButton(onPressed: _pickReceiveDir, child: const Text('Change')),
                      ),
                    ],
                  ),
                  if (hostIsAndroid) ...[
                    const SectionLabel('Android permissions'),
                    _Group(children: _androidPermissions()),
                  ],
                  if (hostIsMacOS) ...[
                    const SectionLabel('Mac permissions'),
                    _Group(children: [const MacAccessibilityRow()]),
                  ],
                  if (state.bluetooth case final bt?) ...[
                    const SectionLabel('Bluetooth'),
                    _Group(
                      children: [
                        ListTile(
                          leading: const Icon(Icons.bluetooth),
                          title: const Text('Connect without Wi-Fi'),
                          subtitle: Text(switch (bt.status) {
                            BluetoothStatus.on =>
                              "On. When your devices aren't on the same Wi-Fi, Sidekick connects over Bluetooth "
                                  'for pairing, files and media.',
                            BluetoothStatus.off => 'Bluetooth is off. Turn it on to connect without Wi-Fi.',
                            BluetoothStatus.unauthorized => "Sidekick isn't allowed to use Bluetooth.",
                            BluetoothStatus.unsupported => "This device doesn't support Bluetooth LE.",
                            BluetoothStatus.starting => 'Starting…',
                          }),
                          isThreeLine: true,
                          trailing: switch (bt.status) {
                            BluetoothStatus.on => const Icon(Icons.check_circle, color: Colors.green),
                            BluetoothStatus.unauthorized => FilledButton.tonal(
                              onPressed: bt.requestPermission,
                              child: const Text('Allow'),
                            ),
                            _ => null,
                          },
                        ),
                        ExpansionTile(
                          leading: const Icon(Icons.troubleshoot_outlined),
                          title: const Text('Details'),
                          subtitle: Text(
                            [
                              bt.advertising ? 'Visible to other devices' : 'Not visible to other devices',
                              if (bt.scanning) 'scanning…',
                            ].join(' · '),
                          ),
                          childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                          expandedCrossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Align(
                              alignment: Alignment.centerLeft,
                              child: FilledButton.tonalIcon(
                                onPressed: bt.scanning || !bt.canScan ? null : state.scanBluetoothNow,
                                icon: const Icon(Icons.bluetooth_searching),
                                label: Text(bt.scanning ? 'Scanning…' : 'Scan now'),
                              ),
                            ),
                            const SizedBox(height: 12),
                            Text('Seen over Bluetooth', style: Theme.of(context).textTheme.titleSmall),
                            if (state.bluetoothSightings.isEmpty) const Text('Nothing yet'),
                            for (final s in state.bluetoothSightings)
                              Text('${s.info.name} (${s.info.platform.name}), ${_ago(s.seen)}'),
                            const SizedBox(height: 12),
                            Text('Log', style: Theme.of(context).textTheme.titleSmall),
                            const SizedBox(height: 4),
                            SelectableText(
                              bt.log.isEmpty ? 'Empty' : bt.log.reversed.take(25).join('\n'),
                              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ],
                  if (hostIsIOS) ...[
                    const SectionLabel('iPhone'),
                    _Group(
                      children: [
                        SwitchListTile(
                          secondary: const Icon(Icons.bolt_outlined),
                          title: const Text('Keep running in the background'),
                          subtitle: const Text(
                            'iOS pauses apps you\'re not using, so your computer couldn\'t change the volume, control '
                            'Apple Music or send files while you\'re in another app. This keeps Sidekick awake with '
                            'a silent sound that never interrupts your music. Uses a little more battery.',
                          ),
                          isThreeLine: true,
                          value: state.keepRunning,
                          onChanged: state.setKeepRunning,
                        ),
                      ],
                    ),
                  ],
                  const SectionLabel('What paired devices can do here'),
                  _Group(
                    children: [
                      SwitchListTile(
                        secondary: const Icon(Icons.folder_open_outlined),
                        title: const Text('Browse and download files'),
                        subtitle: Text(
                          hostIsIOS
                              ? "Paired devices can open Sidekick's folder in the Files app"
                              : 'Paired devices can open any folder on this device',
                        ),
                        value: perms.files,
                        onChanged: (v) => state.setPermissions(perms.copyWith(files: v)),
                      ),
                      if (state.media.supported)
                        SwitchListTile(
                          secondary: const Icon(Icons.play_circle_outline),
                          title: const Text('Control media'),
                          subtitle: Text(
                            hostIsIOS
                                ? 'Change the volume and control Apple Music (iOS doesn\'t let apps control others)'
                                : 'Play, pause, seek and change volume',
                          ),
                          value: perms.media,
                          onChanged: (v) => state.setPermissions(perms.copyWith(media: v)),
                        ),
                      // iOS never lets another device control an iPhone, so the
                      // switch only exists elsewhere.
                      if (!hostIsIOS) ...[
                        SwitchListTile(
                          secondary: const Icon(Icons.mouse_outlined),
                          title: const Text('Control mouse and keyboard'),
                          subtitle: const Text('Use this device remotely'),
                          value: perms.input,
                          onChanged: (v) => state.setPermissions(perms.copyWith(input: v)),
                        ),
                      ],
                    ],
                  ),
                  const SectionLabel('Paired devices'),
                  _Group(
                    children: [
                      if (state.paired.isEmpty) const ListTile(title: Text('No paired devices yet')),
                      for (final d in state.paired)
                        ListTile(
                          leading: Icon(platformIcon(d.platform)),
                          title: Text(d.name),
                          subtitle: Text(
                            [if (d.lastAddress != null) d.lastAddress!, 'Tap for security code'].join(' · '),
                          ),
                          onTap: () => _showSecurityCode(d),
                          trailing: TextButton(onPressed: () => state.unpair(d.id), child: const Text('Unpair')),
                        ),
                    ],
                  ),
                  const SectionLabel('Encryption'),
                  _Group(
                    children: [
                      const ListTile(
                        leading: Icon(Icons.lock_outline),
                        title: Text('Everything between paired devices is encrypted'),
                        subtitle: Text(
                          'Wi-Fi: TLS with each device\'s own certificate, checked on every connection. '
                          'Bluetooth: AES-256-GCM. Pairing uses the 6-digit code in a way that can\'t be '
                          'intercepted or guessed offline.',
                        ),
                        isThreeLine: true,
                      ),
                      ListTile(
                        leading: Icon(
                          state.secrets.secure ? Icons.key_outlined : Icons.key_off_outlined,
                          color: state.secrets.secure ? null : Theme.of(context).colorScheme.error,
                        ),
                        title: Text(
                          state.secrets.secure
                              ? 'Keys are kept in ${switch (hostOS) {
                                  'ios' => 'the Keychain',
                                  'macos' => 'a file only your Mac account can read',
                                  'android' => 'the Android Keystore',
                                  'windows' => 'Windows-protected storage',
                                  _ => 'the system keyring',
                                }}'
                              : "Keys are in app settings: this device's secure storage didn't work",
                        ),
                        subtitle: const Text('Your private key and pairing keys never leave this device.'),
                      ),
                    ],
                  ),
                  const SectionLabel('Theme'),
                  _Group(children: [ThemeChooser(state: state)]),
                  const SectionLabel('About'),
                  _Group(
                    children: [
                      ListTile(
                        leading: const Icon(Icons.info_outline),
                        title: Text(state.appVersion.isEmpty ? 'Sidekick' : 'Sidekick ${state.appVersion}'),
                        subtitle: Text('Device ID ${state.id.substring(0, 8)} · port ${state.me.port}'),
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
}

extension on _SettingsPageState {
  void _showSecurityCode(PairedDevice d) {
    final code = state.securityCodeFor(d);
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        icon: const Icon(Icons.verified_user_outlined),
        title: Text('Security code for ${d.name}'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SelectableText(
              code,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.headlineMedium
                  ?.copyWith(fontFeatures: const [FontFeature.tabularFigures()], letterSpacing: 2),
            ),
            const SizedBox(height: 16),
            Text(
              'On ${d.name}, open Sidekick → Settings → Paired devices and tap ${state.name}. If both show the same '
              'code, your connection is private: nobody is in between.',
            ),
          ],
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Done'))],
      ),
    );
  }

  /// One row per special permission, each with a button to the system screen
  /// that grants it. Status refreshes when the user comes back to the app.
  List<Widget> _androidPermissions() => androidPermissionRows();
}

class _Group extends StatelessWidget {
  const _Group({required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Card.filled(
    clipBehavior: Clip.antiAlias,
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
    child: Column(children: children),
  );
}

String _ago(DateTime t) {
  final d = DateTime.now().difference(t);
  if (d.inSeconds < 60) return '${d.inSeconds} s ago';
  if (d.inMinutes < 60) return '${d.inMinutes} min ago';
  return '${d.inHours} h ago';
}

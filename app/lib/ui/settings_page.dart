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
    final String? dir;
    try {
      await prepareFilePicker();
      dir = await FilePicker.getDirectoryPath(dialogTitle: 'Save received files to…');
    } catch (e) {
      if (mounted) showError(context, "Couldn't open the folder picker: $e");
      return;
    }
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
          subtitle: state.appVersion.isEmpty ? null : 'Sidekick ${state.appVersion}',
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 720),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const SectionLabel('This device', icon: Icons.smartphone_rounded),
                  _Group(
                    children: [
                      Padding(
                        padding: const EdgeInsets.all(16),
                        child: TextField(
                          controller: _name,
                          maxLength: 40,
                          decoration: const InputDecoration(
                            labelText: 'Device name',
                            prefixIcon: Icon(Icons.badge_outlined),
                            helperText: 'What your other devices see',
                          ),
                          onSubmitted: state.setName,
                          onTapOutside: (_) => state.setName(_name.text),
                        ),
                      ),
                      ListTile(
                        leading: const IconTile(Icons.download_rounded, tone: TileTone.primary),
                        title: const Text('Save received files to'),
                        subtitle: Text(_receiveDir ?? '…'),
                        trailing: IconButton.filledTonal(
                          tooltip: 'Change',
                          onPressed: _pickReceiveDir,
                          icon: const Icon(Icons.edit_rounded),
                        ),
                      ),
                      SwitchListTile(
                        secondary: const IconTile(Icons.front_hand_outlined, tone: TileTone.tertiary),
                        title: const Text('Ask before receiving files'),
                        subtitle: const Text('Accept or decline each time'),
                        value: state.askBeforeReceiving,
                        onChanged: state.setAskBeforeReceiving,
                      ),
                      // One switch for every sound Sidekick makes.
                      SwitchListTile(
                        secondary: IconTile(state.sound ? Icons.volume_up_rounded : Icons.volume_off_rounded),
                        title: const Text('Sound'),
                        subtitle: Text(state.sound ? 'Sound enabled' : 'Sound disabled'),
                        value: state.sound,
                        onChanged: state.setSound,
                      ),
                    ],
                  ),
                  if (hostIsAndroid) ...[
                    const SectionLabel('Android permissions', icon: Icons.shield_outlined),
                    _Group(children: _androidPermissions()),
                  ],
                  if (hostIsMacOS) ...[
                    const SectionLabel('Mac permissions', icon: Icons.shield_outlined),
                    _Group(children: [const MacAccessibilityRow()]),
                  ],
                  if (state.bluetooth case final bt?) ...[
                    const SectionLabel('Bluetooth', icon: Icons.bluetooth_rounded),
                    _Group(
                      children: [
                        ListTile(
                          leading: const IconTile(Icons.bluetooth_rounded, tone: TileTone.primary),
                          title: const Text('Connect without Wi-Fi'),
                          subtitle: Text(switch (bt.status) {
                            _ when bt.problem != null => bt.problem!,
                            BluetoothStatus.on => 'On. Used when your devices aren\'t on the same Wi-Fi.',
                            BluetoothStatus.off => 'Bluetooth is off. Turn it on to connect without Wi-Fi.',
                            BluetoothStatus.unauthorized => "Sidekick isn't allowed to use Bluetooth.",
                            BluetoothStatus.unsupported => "This device doesn't support Bluetooth LE.",
                            BluetoothStatus.starting => 'Starting…',
                          }),
                          trailing: switch (bt.status) {
                            _ when bt.problem != null => const Icon(Icons.error_outline, color: Colors.orange),
                            BluetoothStatus.on => const Icon(Icons.check_circle, color: Colors.green),
                            BluetoothStatus.unauthorized => FilledButton.tonal(
                              onPressed: bt.requestPermission,
                              child: const Text('Allow'),
                            ),
                            _ => null,
                          },
                        ),
                        ExpansionTile(
                          leading: const IconTile(Icons.troubleshoot_rounded),
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
                    const SectionLabel('iPhone', icon: Icons.phone_iphone_rounded),
                    _Group(
                      children: [
                        SwitchListTile(
                          secondary: const IconTile(Icons.bolt_rounded, tone: TileTone.tertiary),
                          title: const Text('Keep running in the background'),
                          subtitle: const Text(
                            'So your computer can reach this iPhone while you use other apps. '
                            'Uses a little more battery.',
                          ),
                          value: state.keepRunning,
                          onChanged: state.setKeepRunning,
                        ),
                      ],
                    ),
                  ],
                  const SectionLabel('What paired devices can do here', icon: Icons.tune_rounded),
                  _Group(
                    children: [
                      SwitchListTile(
                        secondary: const IconTile(Icons.folder_open_rounded, tone: TileTone.primary),
                        title: const Text('Browse and download files'),
                        subtitle: Text(hostIsIOS ? "Sidekick's folder in the Files app" : 'Any folder on this device'),
                        value: perms.files,
                        onChanged: (v) => state.setPermissions(perms.copyWith(files: v)),
                      ),
                      // iOS never lets another device control an iPhone, so the
                      // switch only exists elsewhere.
                      if (!hostIsIOS) ...[
                        SwitchListTile(
                          secondary: const IconTile(Icons.mouse_rounded),
                          title: const Text('Control mouse and keyboard'),
                          subtitle: const Text('Use this device remotely'),
                          value: perms.input,
                          onChanged: (v) => state.setPermissions(perms.copyWith(input: v)),
                        ),
                      ],
                    ],
                  ),
                  const SectionLabel('Paired devices', icon: Icons.link_rounded),
                  _Group(
                    children: [
                      if (state.paired.isEmpty)
                        const ListTile(leading: IconTile(Icons.link_off_rounded), title: Text('No paired devices yet')),
                      for (final d in state.paired)
                        ListTile(
                          leading: IconTile(platformIcon(d.platform), tone: TileTone.primary),
                          title: Text(d.name),
                          subtitle: const Text('Tap for its security code'),
                          onTap: () => _showSecurityCode(d),
                          trailing: IconButton(
                            tooltip: 'Unpair',
                            onPressed: () => state.unpair(d.id),
                            icon: const Icon(Icons.link_off_rounded),
                          ),
                        ),
                    ],
                  ),
                  const SectionLabel('Security', icon: Icons.lock_outline_rounded),
                  _Group(
                    children: [
                      const ListTile(
                        leading: IconTile(Icons.lock_rounded, tone: TileTone.primary),
                        title: Text('Everything is encrypted'),
                        subtitle: Text('TLS over Wi-Fi, AES-256-GCM over Bluetooth'),
                      ),
                      ListTile(
                        leading: IconTile(
                          state.secrets.secure ? Icons.key_rounded : Icons.key_off_rounded,
                          tone: state.secrets.secure ? TileTone.secondary : TileTone.error,
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
                        subtitle: const Text('They never leave this device'),
                      ),
                    ],
                  ),
                  const SectionLabel('Look', icon: Icons.palette_outlined),
                  _Group(children: [ThemeChooser(state: state)]),
                  const SectionLabel('About', icon: Icons.info_outline_rounded),
                  _Group(
                    children: [
                      ListTile(
                        leading: const IconTile(Icons.info_outline_rounded),
                        title: Text(state.appVersion.isEmpty ? 'Sidekick' : 'Sidekick ${state.appVersion}'),
                        subtitle: Text(
                          'Device ID ${state.id.substring(0, state.id.length.clamp(0, 8))} · port ${state.me.port}',
                        ),
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
        icon: const Icon(Icons.verified_user_rounded),
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
  Widget build(BuildContext context) => Entrance(
    child: Card.filled(
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      child: Column(children: children),
    ),
  );
}

String _ago(DateTime t) {
  final d = DateTime.now().difference(t);
  if (d.inSeconds < 60) return '${d.inSeconds} s ago';
  if (d.inMinutes < 60) return '${d.inMinutes} min ago';
  return '${d.inHours} h ago';
}

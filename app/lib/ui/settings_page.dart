import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:material_ui/material_ui.dart';

import '../app_state.dart';
import '../core/bluetooth.dart';
import '../platform/android.dart';
import '../platform/macos.dart';
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
                  if (Platform.isAndroid) ...[
                    const SectionLabel('Android permissions'),
                    _Group(children: _androidPermissions()),
                  ],
                  if (Platform.isMacOS) ...[
                    const SectionLabel('Mac permissions'),
                    _Group(
                      children: [
                        ListTile(
                          leading: const Icon(Icons.mouse_outlined),
                          title: const Text('Accessibility'),
                          subtitle: const Text(
                            'So your other devices can move the mouse, click and type on this Mac. If Sidekick is '
                            'already switched on in that list but this still asks for it (common after an update), '
                            'select Sidekick, remove it with −, then add it again.',
                          ),
                          isThreeLine: true,
                          trailing: MacBridge.accessibility
                              ? const Icon(Icons.check_circle, color: Colors.green)
                              : FilledButton.tonal(
                                  onPressed: MacBridge.requestAccessibility,
                                  child: const Text('Grant'),
                                ),
                        ),
                        ListTile(
                          leading: const Icon(Icons.screen_share_outlined),
                          title: const Text('Screen Recording'),
                          subtitle: const Text(
                            'So your other devices can see this screen. After allowing it, quit and reopen Sidekick. '
                            'If it stops working after an update, remove Sidekick from that list and add it again.',
                          ),
                          isThreeLine: true,
                          trailing: MacBridge.screenRecording
                              ? const Icon(Icons.check_circle, color: Colors.green)
                              : FilledButton.tonal(
                                  onPressed: MacBridge.requestScreenRecording,
                                  child: const Text('Grant'),
                                ),
                        ),
                      ],
                    ),
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
                                onPressed: bt.scanning || bt.status != BluetoothStatus.on
                                    ? null
                                    : state.scanBluetoothNow,
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
                  const SectionLabel('What paired devices can do here'),
                  _Group(
                    children: [
                      SwitchListTile(
                        secondary: const Icon(Icons.folder_open_outlined),
                        title: const Text('Browse and download files'),
                        subtitle: Text(
                          Platform.isIOS
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
                            Platform.isIOS
                                ? 'Change the volume and control Apple Music (iOS doesn\'t let apps control others)'
                                : 'Play, pause, seek and change volume',
                          ),
                          value: perms.media,
                          onChanged: (v) => state.setPermissions(perms.copyWith(media: v)),
                        ),
                      // iOS never lets another device control an iPhone or see its
                      // screen, so those switches only exist elsewhere.
                      if (!Platform.isIOS) ...[
                        SwitchListTile(
                          secondary: const Icon(Icons.mouse_outlined),
                          title: const Text('Control mouse and keyboard'),
                          subtitle: const Text('Use this device remotely'),
                          value: perms.input,
                          onChanged: (v) => state.setPermissions(perms.copyWith(input: v)),
                        ),
                        if (state.screen.supported)
                          SwitchListTile(
                            secondary: const Icon(Icons.screen_share_outlined),
                            title: const Text('See this screen'),
                            subtitle: Text(
                              Platform.isAndroid
                                  ? 'Paired devices can ask to see this screen; you allow it each time'
                                  : 'Paired devices can see this screen live, with a banner here while they do',
                            ),
                            value: perms.screen,
                            onChanged: (v) => state.setPermissions(perms.copyWith(screen: v)),
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
                          subtitle: Text(d.lastAddress ?? ''),
                          trailing: TextButton(onPressed: () => state.unpair(d.id), child: const Text('Unpair')),
                        ),
                    ],
                  ),
                  const SectionLabel('Appearance'),
                  _Group(
                    children: [
                      Padding(
                        padding: const EdgeInsets.all(16),
                        child: SegmentedButton<ThemeMode>(
                          segments: const [
                            ButtonSegment(
                              value: ThemeMode.system,
                              icon: Icon(Icons.brightness_auto_outlined),
                              label: Text('System'),
                            ),
                            ButtonSegment(
                              value: ThemeMode.light,
                              icon: Icon(Icons.light_mode_outlined),
                              label: Text('Light'),
                            ),
                            ButtonSegment(
                              value: ThemeMode.dark,
                              icon: Icon(Icons.dark_mode_outlined),
                              label: Text('Dark'),
                            ),
                          ],
                          selected: {state.themeMode},
                          onSelectionChanged: (s) => state.setThemeMode(s.first),
                        ),
                      ),
                      if (!Platform.isIOS)
                        ListTile(
                          leading: const Icon(Icons.palette_outlined),
                          title: Text(switch (Platform.operatingSystem) {
                            'android' => 'Colors follow your wallpaper (Android 12 and newer)',
                            'macos' => "Colors follow your Mac's accent color",
                            _ => 'Colors follow your Windows accent color',
                          }),
                          subtitle: switch (Platform.operatingSystem) {
                            'macos' => const Text('System Settings → Appearance'),
                            'windows' => const Text('Settings → Personalization → Colors'),
                            _ => null,
                          },
                        ),
                    ],
                  ),
                  const SectionLabel('About'),
                  _Group(
                    children: [
                      ListTile(
                        leading: const Icon(Icons.info_outline),
                        title: const Text('Sidekick 0.1.0'),
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
  /// One row per special permission, each with a button to the system screen
  /// that grants it. Status refreshes when the user comes back to the app.
  List<Widget> _androidPermissions() {
    final perms = AndroidBridge.permissions;
    Widget row({
      required IconData icon,
      required String title,
      required String why,
      required bool granted,
      required Future<void> Function() grant,
    }) => ListTile(
      leading: Icon(icon),
      title: Text(title),
      subtitle: Text(why),
      isThreeLine: true,
      trailing: granted
          ? const Icon(Icons.check_circle, color: Colors.green)
          : FilledButton.tonal(onPressed: grant, child: const Text('Grant')),
    );
    return [
      row(
        icon: Icons.folder_open_outlined,
        title: 'All files access',
        why: 'So your PC can browse this phone and received files go to Download/Sidekick.',
        granted: perms.allFiles,
        grant: AndroidBridge.requestAllFilesAccess,
      ),
      row(
        icon: Icons.play_circle_outline,
        title: 'Notification access',
        why: "So your PC can see what's playing and seek. Sidekick doesn't read your notifications.",
        granted: perms.notifications,
        grant: AndroidBridge.openNotificationAccessSettings,
      ),
      row(
        icon: Icons.touch_app_outlined,
        title: 'Remote control (Accessibility)',
        why:
            'So your PC can tap, scroll and type here. In Accessibility, open "Installed apps" → Sidekick remote '
            'control. If it\'s greyed out: App info → ⋮ → Allow restricted settings.',
        granted: perms.accessibility,
        grant: AndroidBridge.openAccessibilitySettings,
      ),
      if (!perms.accessibility)
        ListTile(
          leading: const SizedBox(),
          title: const Text('Open App info'),
          subtitle: const Text('For "Allow restricted settings" on Android 13 and newer'),
          onTap: AndroidBridge.openAppSettings,
        ),
    ];
  }
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

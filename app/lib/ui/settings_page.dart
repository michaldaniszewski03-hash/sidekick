import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:material_ui/material_ui.dart';

import '../app_state.dart';
import '../core/server.dart';
import '../platform/android.dart';
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
                  const SectionLabel('What paired devices can do here'),
                  _Group(
                    children: [
                      SwitchListTile(
                        secondary: const Icon(Icons.folder_open_outlined),
                        title: const Text('Browse and download files'),
                        subtitle: const Text('Paired devices can open any folder on this device'),
                        value: perms.files,
                        onChanged: (v) =>
                            state.setPermissions(Permissions(files: v, media: perms.media, input: perms.input)),
                      ),
                      SwitchListTile(
                        secondary: const Icon(Icons.play_circle_outline),
                        title: const Text('Control media'),
                        subtitle: Text(
                          state.media.supported
                              ? 'Play, pause, seek and change volume'
                              : 'Not supported on this platform yet',
                        ),
                        value: perms.media && state.media.supported,
                        onChanged: state.media.supported
                            ? (v) => state.setPermissions(Permissions(files: perms.files, media: v, input: perms.input))
                            : null,
                      ),
                      SwitchListTile(
                        secondary: const Icon(Icons.mouse_outlined),
                        title: const Text('Control mouse and keyboard'),
                        subtitle: Text(
                          state.input.supported ? 'Use this device remotely' : 'Not supported on this platform yet',
                        ),
                        value: perms.input && state.input.supported,
                        onChanged: state.input.supported
                            ? (v) => state.setPermissions(Permissions(files: perms.files, media: perms.media, input: v))
                            : null,
                      ),
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
                      ListTile(
                        leading: const Icon(Icons.palette_outlined),
                        title: Text(
                          Platform.isAndroid
                              ? 'Colors follow your wallpaper (Android 12 and newer)'
                              : 'Colors follow your Windows accent color',
                        ),
                        subtitle: Platform.isAndroid ? null : const Text('Settings → Personalization → Colors'),
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

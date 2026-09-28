import 'package:file_picker/file_picker.dart';
import 'package:material_ui/material_ui.dart';

import '../app_state.dart';
import '../core/server.dart';
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
                  const SectionLabel('What paired devices can do here'),
                  _Group(
                    children: [
                      SwitchListTile(
                        secondary: const Icon(Icons.folder_open_outlined),
                        title: const Text('Browse and download files'),
                        subtitle: const Text('Paired devices can open any folder on this computer'),
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
                          state.input.supported ? 'Use this computer remotely' : 'Not supported on this platform yet',
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
                      const ListTile(
                        leading: Icon(Icons.palette_outlined),
                        title: Text('Colors follow your Windows accent color'),
                        subtitle: Text('Settings → Personalization → Colors'),
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

import 'package:material_ui/material_ui.dart';

import '../app_state.dart';
import '../core/bluetooth.dart';
import 'permissions.dart';
import 'theme_chooser.dart';
import 'widgets.dart';

/// The first-launch setup: what Sidekick does, this device's name, the
/// permissions it needs here, a look, and how to connect another device.
/// Shown once; [AppState.finishWelcome] remembers it.
class WelcomeFlow extends StatefulWidget {
  const WelcomeFlow({super.key, required this.state});
  final AppState state;

  @override
  State<WelcomeFlow> createState() => _WelcomeFlowState();
}

enum _Step { hello, name, permissions, look, connect }

class _WelcomeFlowState extends State<WelcomeFlow> {
  late final TextEditingController _name = TextEditingController(text: widget.state.name);
  late final AppLifecycleListener _lifecycle;
  int _index = 0;
  bool _forward = true;

  AppState get state => widget.state;

  /// Windows needs nothing granted (the installer set up the firewall).
  List<_Step> get _steps => [
    _Step.hello,
    _Step.name,
    if (hostIsAndroid || hostIsMacOS || hostIsIOS) _Step.permissions,
    _Step.look,
    _Step.connect,
  ];

  @override
  void initState() {
    super.initState();
    // Coming back from system settings after granting something.
    _lifecycle = AppLifecycleListener(onResume: () => state.refreshPlatform());
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    _name.dispose();
    super.dispose();
  }

  void _go(int delta) {
    if (_steps[_index] == _Step.name) state.setName(_name.text);
    final next = _index + delta;
    if (next >= _steps.length) {
      state.finishWelcome();
      return;
    }
    if (next < 0) return;
    FocusScope.of(context).unfocus();
    setState(() {
      _forward = delta > 0;
      _index = next;
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final steps = _steps;
    final step = steps[_index];
    final last = _index == steps.length - 1;
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 16, 24, 20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Image.asset(
                        'assets/logo/logo.png',
                        height: 36,
                        color: scheme.onSurface,
                        semanticLabel: 'Sidekick',
                      ),
                      const Spacer(),
                      // Hidden rather than removed, so the header doesn't jump.
                      Visibility.maintain(
                        visible: !last,
                        child: TextButton(onPressed: state.finishWelcome, child: const Text('Skip')),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  _Progress(count: steps.length, index: _index),
                  Expanded(
                    child: ListenableBuilder(
                      listenable: state,
                      builder: (context, _) => AnimatedSwitcher(
                        duration: const Duration(milliseconds: 320),
                        switchInCurve: Curves.easeOutCubic,
                        switchOutCurve: Curves.easeInCubic,
                        transitionBuilder: (child, animation) => FadeTransition(
                          opacity: animation,
                          child: SlideTransition(
                            position: Tween(
                              begin: Offset(_forward ? 0.08 : -0.08, 0),
                              end: Offset.zero,
                            ).animate(animation),
                            child: child,
                          ),
                        ),
                        child: KeyedSubtree(
                          key: ValueKey(step),
                          child: SingleChildScrollView(
                            padding: const EdgeInsets.symmetric(vertical: 24),
                            child: _page(step, scheme),
                          ),
                        ),
                      ),
                    ),
                  ),
                  Row(
                    children: [
                      if (_index > 0) TextButton(onPressed: () => _go(-1), child: const Text('Back')),
                      const Spacer(),
                      FilledButton.icon(
                        onPressed: () => _go(1),
                        icon: Icon(last ? Icons.check : Icons.arrow_forward),
                        iconAlignment: IconAlignment.end,
                        label: Text(last ? 'Start using Sidekick' : 'Continue'),
                        style: FilledButton.styleFrom(minimumSize: const Size(0, 52)),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _page(_Step step, ColorScheme scheme) => switch (step) {
    _Step.hello => _Page(
      icon: Icons.waving_hand_outlined,
      title: 'Welcome to Sidekick',
      body: 'Your phone and computer, working as one. Here\'s what you can do:',
      children: const [
        _Feature(Icons.swap_horiz, 'Send files both ways', 'Drag, drop or pick: photos, videos, documents.'),
        _Feature(Icons.mouse_outlined, 'Use one device from another', 'Touchpad, keyboard and shortcuts.'),
        _Feature(Icons.play_circle_outline, 'Control what\'s playing', 'Play, pause, skip and volume.'),
        _Feature(Icons.bluetooth, 'Works without Wi-Fi', 'Nearby devices connect over Bluetooth.'),
        _Feature(Icons.lock_outline, 'Private by design', 'Everything is encrypted and stays between your devices.'),
      ],
    ),
    _Step.name => _Page(
      icon: Icons.badge_outlined,
      title: 'Name this device',
      body: 'This is how your other devices will see it. You can change it later in Settings.',
      children: [
        TextField(
          controller: _name,
          autofocus: !isMobile,
          maxLength: 40,
          textInputAction: TextInputAction.next,
          onSubmitted: (_) => _go(1),
          decoration: InputDecoration(labelText: 'Device name', prefixIcon: Icon(platformIcon(state.me.platform))),
        ),
      ],
    ),
    _Step.permissions => _Page(
      icon: Icons.verified_user_outlined,
      title: 'A few permissions',
      body: hostIsIOS
          ? 'iOS will ask to let Sidekick find devices on your network and use Bluetooth. Allow both so your '
                'computer can find this iPhone.'
          : 'Each one unlocks a feature. Grant what you need now or later in Settings.',
      children: [
        _Group(
          children: [
            if (hostIsAndroid) ...androidPermissionRows(),
            if (hostIsMacOS) const MacAccessibilityRow(),
            if (hostIsIOS)
              SwitchListTile(
                secondary: const Icon(Icons.bolt_outlined),
                title: const Text('Keep running in the background'),
                subtitle: const Text(
                  'So your computer can still reach this iPhone while you use other apps. Uses a little more '
                  'battery.',
                ),
                isThreeLine: true,
                value: state.keepRunning,
                onChanged: state.setKeepRunning,
              ),
            if (state.bluetooth case final bt?)
              ListTile(
                leading: const Icon(Icons.bluetooth),
                title: const Text('Bluetooth'),
                subtitle: const Text('To find nearby devices when there\'s no Wi-Fi.'),
                trailing: switch (bt.status) {
                  BluetoothStatus.on => const Icon(Icons.check_circle, color: Colors.green),
                  BluetoothStatus.unauthorized => FilledButton.tonal(
                    onPressed: bt.requestPermission,
                    child: const Text('Allow'),
                  ),
                  BluetoothStatus.off => const Text('Off'),
                  _ => null,
                },
              ),
          ],
        ),
      ],
    ),
    _Step.look => _Page(
      icon: Icons.palette_outlined,
      title: 'Make it yours',
      body: 'Pick a look. Settings → Theme has it all again later.',
      children: [
        _Group(
          children: [
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: ThemeChooser(state: state),
            ),
          ],
        ),
      ],
    ),
    _Step.connect => _Page(
      icon: Icons.devices_outlined,
      title: 'Connect your other device',
      body: 'Install Sidekick there too, then:',
      children: const [
        _Feature(
          Icons.looks_one_outlined,
          'Open Sidekick on both',
          'On the same Wi-Fi, or close by with Bluetooth on.',
        ),
        _Feature(
          Icons.looks_two_outlined,
          'Tap Pair next to the other device',
          'It shows up under Nearby on the Devices tab. No Wi-Fi? Tap Bluetooth there.',
        ),
        _Feature(
          Icons.looks_3_outlined,
          'Type the 6-digit code it shows',
          'That\'s it: the two devices now trust each other, and only each other.',
        ),
      ],
    ),
  };
}

class _Progress extends StatelessWidget {
  const _Progress({required this.count, required this.index});
  final int count;
  final int index;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      children: [
        for (var i = 0; i < count; i++)
          Expanded(
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 300),
              height: 6,
              margin: EdgeInsets.only(right: i == count - 1 ? 0 : 6),
              decoration: BoxDecoration(
                color: i <= index ? scheme.primary : scheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(3),
              ),
            ),
          ),
      ],
    );
  }
}

class _Page extends StatelessWidget {
  const _Page({required this.icon, required this.title, required this.body, required this.children});
  final IconData icon;
  final String title;
  final String body;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Align(
          alignment: Alignment.centerLeft,
          child: Container(
            width: 72,
            height: 72,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [scheme.primary, scheme.tertiary],
              ),
              borderRadius: BorderRadius.circular(24),
            ),
            child: Icon(icon, color: scheme.onPrimary, size: 36),
          ),
        ),
        const SizedBox(height: 24),
        Text(title, style: text.headlineMedium?.copyWith(fontWeight: FontWeight.w700)),
        const SizedBox(height: 8),
        Text(body, style: text.bodyLarge?.copyWith(color: scheme.onSurfaceVariant)),
        const SizedBox(height: 24),
        ...children,
      ],
    );
  }
}

class _Feature extends StatelessWidget {
  const _Feature(this.icon, this.title, this.subtitle);
  final IconData icon;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(color: scheme.secondaryContainer, borderRadius: BorderRadius.circular(14)),
            child: Icon(icon, color: scheme.onSecondaryContainer),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: Theme.of(context).textTheme.titleMedium),
                Text(subtitle, style: TextStyle(color: scheme.onSurfaceVariant)),
              ],
            ),
          ),
        ],
      ),
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

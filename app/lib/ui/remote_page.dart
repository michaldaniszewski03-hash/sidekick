import 'dart:async';
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';

import '../app_state.dart';
import '../core/client.dart';
import '../core/models.dart';
import 'widgets.dart';

/// What to send so text that reads [before] ends up reading [after]:
/// that many backspaces, then [insert]. Handles autocorrect rewrites.
(int backspaces, String insert) typingDiff(String before, String after) {
  var common = 0;
  while (common < before.length && common < after.length && before.codeUnitAt(common) == after.codeUnitAt(common)) {
    common++;
  }
  return (before.length - common, after.substring(common));
}

class RemotePage extends StatelessWidget {
  const RemotePage({super.key, required this.state, this.onGoToDevices});
  final AppState state;
  final VoidCallback? onGoToDevices;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: state,
    builder: (context, _) => DeviceGate(
      state: state,
      feature: 'remote control',
      icon: Icons.mouse_outlined,
      onGoToDevices: onGoToDevices,
      builder: (context, device) => device.platform == DevicePlatform.ios
          ? _IphoneCantBeControlled(key: ValueKey(device.id), state: state, device: device)
          : _Remote(key: ValueKey(device.id), state: state, device: device),
    ),
  );
}

/// Shown once, the first time this device meets an iPhone (paired with it,
/// or picked it in Remote): Apple doesn't let any app control an iPhone.
Future<void> showIphoneRemoteNotice(BuildContext context, AppState state, String name) async {
  if (state.iphoneRemoteNoticeSeen) return;
  state.markIphoneRemoteNoticeSeen();
  await showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      icon: const Icon(Icons.phone_iphone_rounded),
      title: const Text("iPhones can't be controlled"),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 380),
        child: Text(
          "Apple doesn't let any app move the pointer or type on an iPhone, so $name can't be controlled "
          'from here. Everything else works: send files both ways, and use the iPhone as a touchpad and '
          'keyboard for your computer.',
          textAlign: TextAlign.center,
        ),
      ),
      actions: [FilledButton(onPressed: () => Navigator.pop(context), child: const Text('Got it'))],
    ),
  );
}

/// Remote on an iPhone: no touchpad or keyboard (it can't be controlled),
/// just why, and the picker to choose another device.
class _IphoneCantBeControlled extends StatefulWidget {
  const _IphoneCantBeControlled({super.key, required this.state, required this.device});
  final AppState state;
  final PairedDevice device;

  @override
  State<_IphoneCantBeControlled> createState() => _IphoneCantBeControlledState();
}

class _IphoneCantBeControlledState extends State<_IphoneCantBeControlled> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(showIphoneRemoteNotice(context, widget.state, widget.device.name));
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return PageFrame(
      title: 'Remote',
      subtitle: widget.device.name,
      actions: [DevicePicker(state: widget.state)],
      child: Container(
        padding: const EdgeInsets.all(28),
        decoration: BoxDecoration(color: scheme.surfaceContainerLow, borderRadius: BorderRadius.circular(28)),
        child: Column(
          children: [
            const GradientBadge(icon: Icons.phone_iphone_rounded, size: 64),
            const SizedBox(height: 16),
            Text("iPhones can't be controlled", style: text.titleLarge, textAlign: TextAlign.center),
            const SizedBox(height: 8),
            Text(
              "Apple doesn't let any app move the pointer or type on an iPhone. Use ${widget.device.name} as "
              'the remote instead: open Sidekick on it and pick this device in its Remote tab.',
              textAlign: TextAlign.center,
              style: TextStyle(color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}

enum _Conn { connecting, connected, failed }

class _Remote extends StatefulWidget {
  const _Remote({super.key, required this.state, required this.device});
  final AppState state;
  final PairedDevice device;

  @override
  State<_Remote> createState() => _RemoteState();
}

class _RemoteState extends State<_Remote> {
  InputSession? _session;
  _Conn _conn = _Conn.connecting;
  String? _error;
  double _speed = 1.6;
  bool _holding = false;
  final _captureFocus = FocusNode();
  final _textController = TextEditingController();
  final _liveController = TextEditingController();
  String _live = '';

  @override
  void initState() {
    super.initState();
    _connect();
  }

  @override
  void dispose() {
    if (_holding) _session?.buttonUp();
    _session?.close();
    _captureFocus.dispose();
    _textController.dispose();
    _liveController.dispose();
    super.dispose();
  }

  Future<void> _connect() async {
    setState(() {
      _conn = _Conn.connecting;
      _error = null;
    });
    try {
      // Remote control needs Wi-Fi; over Bluetooth, set up a direct link.
      if (widget.state.viaBluetooth(widget.device.id)) await widget.state.connectDirect(widget.device);
      final session = await widget.state.clientFor(widget.device).openInput();
      if (!mounted) {
        await session.close();
        return;
      }
      setState(() {
        _session = session;
        _conn = _Conn.connected;
      });
      unawaited(
        session.closed.then((_) {
          if (mounted && _session == session) {
            setState(() {
              _conn = _Conn.failed;
              _error = 'Disconnected';
            });
          }
        }),
      );
    } catch (e) {
      if (mounted) {
        setState(() {
          _conn = _Conn.failed;
          _error = '$e';
        });
      }
    }
  }

  InputSession? get _s => _conn == _Conn.connected ? _session : null;

  /// Forwards physical key presses while the capture box has focus.
  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    final s = _s;
    if (s == null || event is KeyUpEvent) return KeyEventResult.ignored;
    final keyboard = HardwareKeyboard.instance;
    // A Mac user presses Cmd where a Windows user presses Ctrl. Translate
    // so Cmd+C on a Mac copies on a Windows PC, and Control stays Control
    // when Mac controls Mac.
    final targetMac = widget.device.platform == DevicePlatform.macos;
    final fromMac = Platform.isMacOS;
    final mods = [
      if (keyboard.isControlPressed) fromMac && targetMac ? 'macctrl' : 'ctrl',
      if (keyboard.isAltPressed) 'alt',
      if (keyboard.isShiftPressed) 'shift',
      if (keyboard.isMetaPressed) fromMac ? (targetMac ? 'cmd' : 'ctrl') : 'win',
    ];
    final special = _specialKeys[event.logicalKey];
    if (special != null) {
      s.key(special, modifiers: mods);
      return KeyEventResult.handled;
    }
    final label = event.logicalKey.keyLabel.toLowerCase();
    final hasCommandMod = mods.any((m) => m != 'shift');
    if (hasCommandMod && label.length == 1) {
      s.key(label, modifiers: mods);
      return KeyEventResult.handled;
    }
    final char = event.character;
    if (char != null && char.isNotEmpty && char.codeUnitAt(0) >= 0x20) {
      s.text(char);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  static final _specialKeys = {
    LogicalKeyboardKey.enter: 'enter',
    LogicalKeyboardKey.backspace: 'backspace',
    LogicalKeyboardKey.tab: 'tab',
    LogicalKeyboardKey.escape: 'esc',
    LogicalKeyboardKey.delete: 'delete',
    LogicalKeyboardKey.arrowLeft: 'left',
    LogicalKeyboardKey.arrowRight: 'right',
    LogicalKeyboardKey.arrowUp: 'up',
    LogicalKeyboardKey.arrowDown: 'down',
    LogicalKeyboardKey.home: 'home',
    LogicalKeyboardKey.end: 'end',
    LogicalKeyboardKey.pageUp: 'pageup',
    LogicalKeyboardKey.pageDown: 'pagedown',
    for (var i = 1; i <= 12; i++) LogicalKeyboardKey.findKeyByKeyId(LogicalKeyboardKey.f1.keyId + i - 1)!: 'f$i',
  };

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final supported = widget.state.capabilitiesOf(widget.device.id)?.input ?? true;

    return PageFrame(
      title: 'Remote',
      subtitle: 'Use ${widget.device.name} from here',
      actions: [
        _StatusChip(conn: _conn, onRetry: _connect),
        const SizedBox(width: 8),
        DevicePicker(state: widget.state),
      ],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          OfflineBanner(state: widget.state, device: widget.device),
          if (!supported)
            const Padding(
              padding: EdgeInsets.only(bottom: 16),
              child: Text(
                "This device doesn't accept remote control (it's off in its settings, or its platform doesn't allow it).",
              ),
            ),
          if (_conn == _Conn.failed && _error != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 16),
              child: Text(_error!, style: TextStyle(color: scheme.error)),
            ),
          _Touchpad(
            enabled: _s != null,
            onMove: (d) => _s?.move(d.dx * _speed, d.dy * _speed),
            onClick: () => _s?.click(),
            onRightClick: () => _s?.click(button: 'right'),
            onScroll: (dx, dy) => _s?.scroll(dx: dx, dy: dy),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: _BigButton(label: 'Left click', onPressed: _s == null ? null : () => _s!.click()),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _BigButton(
                  label: 'Right click',
                  onPressed: _s == null ? null : () => _s!.click(button: 'right'),
                ),
              ),
              const SizedBox(width: 12),
              Tooltip(
                message: 'Hold the left button down, for dragging and selecting',
                child: SizedBox(
                  height: 56,
                  child: FilterChip(
                    label: const Text('Hold'),
                    avatar: const Icon(Icons.pan_tool_alt_outlined, size: 18),
                    selected: _holding,
                    onSelected: _s == null
                        ? null
                        : (v) {
                            v ? _s!.buttonDown() : _s!.buttonUp();
                            setState(() => _holding = v);
                          },
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              const Icon(Icons.speed, size: 20),
              const SizedBox(width: 8),
              const Text('Pointer speed'),
              Expanded(
                child: Slider(value: _speed, min: 0.5, max: 4, onChanged: (v) => setState(() => _speed = v)),
              ),
            ],
          ),
          const SectionLabel('Keyboard'),
          if (isMobile) _liveTyping() else ..._desktopKeyboard(scheme),
          const SectionLabel('Shortcuts'),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final (label, key, mods) in _shortcutsFor(widget.device.platform))
                ActionChip(
                  label: _arrows[label] == null ? Text(label) : Icon(_arrows[label], size: 18, semanticLabel: key),
                  onPressed: _s == null ? null : () => _s!.key(key, modifiers: mods),
                ),
            ],
          ),
        ],
      ),
    );
  }

  /// Physical-keyboard capture and a send-text box, for desktops.
  List<Widget> _desktopKeyboard(ColorScheme scheme) => [
    Focus(
      focusNode: _captureFocus,
      onKeyEvent: _onKey,
      child: ListenableBuilder(
        listenable: _captureFocus,
        builder: (context, _) {
          final active = _captureFocus.hasFocus;
          return InkWell(
            borderRadius: BorderRadius.circular(20),
            onTap: _s == null ? null : () => active ? _captureFocus.unfocus() : _captureFocus.requestFocus(),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              padding: const EdgeInsets.all(18),
              decoration: BoxDecoration(
                color: active ? scheme.primaryContainer : scheme.surfaceContainerHigh,
                borderRadius: BorderRadius.circular(active ? 28 : 20),
                border: Border.all(color: active ? scheme.primary : Colors.transparent, width: 2),
              ),
              child: Row(
                children: [
                  Icon(
                    active ? Icons.keyboard : Icons.keyboard_outlined,
                    color: active ? scheme.onPrimaryContainer : scheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Text(
                      active
                          ? 'Typing on ${widget.device.name}. Everything you type goes there. Click here to stop.'
                          : 'Click here, then type. Your keystrokes go straight to ${widget.device.name}.',
                      style: TextStyle(color: active ? scheme.onPrimaryContainer : scheme.onSurfaceVariant),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    ),
    const SizedBox(height: 12),
    TextField(
      controller: _textController,
      enabled: _s != null,
      decoration: InputDecoration(
        hintText: 'Or write text here and press Enter to send it all at once',
        suffixIcon: IconButton(
          icon: const Icon(Icons.send),
          onPressed: () {
            _s?.text(_textController.text);
            _textController.clear();
          },
        ),
      ),
      onSubmitted: (v) {
        _s?.text(v);
        _textController.clear();
      },
    ),
  ];

  /// On phones: a text field that forwards every change as you type,
  /// including backspaces and autocorrect rewrites.
  Widget _liveTyping() => TextField(
    controller: _liveController,
    enabled: _s != null,
    autocorrect: false,
    enableSuggestions: false,
    textInputAction: TextInputAction.send,
    decoration: InputDecoration(
      hintText: 'Type here to type on ${widget.device.name}',
      prefixIcon: const Icon(Icons.keyboard_outlined),
    ),
    onChanged: _onLiveChanged,
    // Keep the keyboard open after Enter.
    onEditingComplete: () {},
    onSubmitted: (_) {
      _s?.key('enter');
      _liveController.clear();
      _live = '';
    },
  );

  void _onLiveChanged(String value) {
    final s = _s;
    if (s == null) return;
    final (backspaces, insert) = typingDiff(_live, value);
    for (var i = 0; i < backspaces; i++) {
      s.key('backspace');
    }
    if (insert.isNotEmpty) s.text(insert);
    _live = value;
  }

  static List<(String, String, List<String>)> _shortcutsFor(DevicePlatform target) => switch (target) {
    DevicePlatform.android || DevicePlatform.ios => _phoneShortcuts,
    DevicePlatform.macos => _macShortcuts,
    _ => _shortcuts,
  };

  static const _macShortcuts = <(String, String, List<String>)>[
    ('Esc', 'esc', []),
    ('Tab', 'tab', []),
    ('Return', 'enter', []),
    ('Delete', 'backspace', []),
    ('←', 'left', []),
    ('→', 'right', []),
    ('↑', 'up', []),
    ('↓', 'down', []),
    ('Spotlight', 'space', ['cmd']),
    ('Switch app', 'tab', ['cmd']),
    ('Mission Control', 'up', ['macctrl']),
    ('Show desktop', 'f11', []),
    ('Copy', 'c', ['cmd']),
    ('Paste', 'v', ['cmd']),
    ('Undo', 'z', ['cmd']),
    ('Full screen', 'f', ['cmd', 'macctrl']),
    ('Close window', 'w', ['cmd']),
    ('Lock Mac', 'q', ['cmd', 'macctrl']),
  ];

  static const _phoneShortcuts = <(String, String, List<String>)>[
    ('Back', 'back', []),
    ('Home', 'home', []),
    ('Recent apps', 'recents', []),
    ('Notifications', 'notifications', []),
    ('Quick settings', 'quicksettings', []),
    ('Enter', 'enter', []),
    ('Backspace', 'backspace', []),
    ('Select all', 'a', ['ctrl']),
    ('Copy', 'c', ['ctrl']),
    ('Paste', 'v', ['ctrl']),
    ('Lock screen', 'lock', []),
  ];

  static const _arrows = {
    '←': Icons.arrow_back,
    '→': Icons.arrow_forward,
    '↑': Icons.arrow_upward,
    '↓': Icons.arrow_downward,
  };

  static const _shortcuts = <(String, String, List<String>)>[
    ('Esc', 'esc', []),
    ('Tab', 'tab', []),
    ('Enter', 'enter', []),
    ('Backspace', 'backspace', []),
    ('←', 'left', []),
    ('→', 'right', []),
    ('↑', 'up', []),
    ('↓', 'down', []),
    ('Start menu', 'win', []),
    ('Switch window', 'tab', ['alt']),
    ('Show desktop', 'd', ['win']),
    ('Copy', 'c', ['ctrl']),
    ('Paste', 'v', ['ctrl']),
    ('Undo', 'z', ['ctrl']),
    ('Fullscreen (F11)', 'f11', []),
    ('Close window', 'f4', ['alt']),
    ('Lock PC', 'l', ['win']),
  ];
}

class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.conn, required this.onRetry});
  final _Conn conn;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => switch (conn) {
    _Conn.connecting => const Chip(
      avatar: SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)),
      label: Text('Connecting'),
    ),
    _Conn.connected => const Chip(
      avatar: Icon(Icons.circle, size: 10, color: Colors.green),
      label: Text('Connected'),
    ),
    _Conn.failed => ActionChip(
      avatar: const Icon(Icons.refresh, size: 18),
      label: const Text('Reconnect'),
      onPressed: onRetry,
    ),
  };
}

class _BigButton extends StatelessWidget {
  const _BigButton({required this.label, required this.onPressed});
  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: 56,
    child: FilledButton.tonal(
      onPressed: onPressed,
      style: FilledButton.styleFrom(shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18))),
      child: Text(label),
    ),
  );
}

/// Drag to move the pointer, tap to click, right-click (or long-press) for
/// a right click, mouse wheel or two fingers to scroll.
class _Touchpad extends StatefulWidget {
  const _Touchpad({
    required this.enabled,
    required this.onMove,
    required this.onClick,
    required this.onRightClick,
    required this.onScroll,
  });

  final bool enabled;
  final void Function(Offset delta) onMove;
  final VoidCallback onClick;
  final VoidCallback onRightClick;
  final void Function(int dx, int dy) onScroll;

  @override
  State<_Touchpad> createState() => _TouchpadState();
}

class _TouchpadState extends State<_Touchpad> {
  bool _active = false;
  Offset? _dot;
  Offset _scrollRemainder = Offset.zero;

  void _scrollBy(Offset delta) {
    // Flutter reports pixels; Windows wants 120 units per wheel notch. One
    // notch in Flutter is usually ~100 px, so scale a little.
    final total = _scrollRemainder + delta * 1.2;
    final dx = total.dx.truncate(), dy = total.dy.truncate();
    _scrollRemainder = total - Offset(dx.toDouble(), dy.toDouble());
    if (dx != 0 || dy != 0) widget.onScroll(dx, -dy);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Listener(
      onPointerSignal: (e) {
        if (widget.enabled && e is PointerScrollEvent) _scrollBy(e.scrollDelta);
      },
      child: GestureDetector(
        onTap: widget.enabled ? widget.onClick : null,
        onSecondaryTap: widget.enabled ? widget.onRightClick : null,
        onLongPress: widget.enabled ? widget.onRightClick : null,
        onScaleStart: widget.enabled ? (d) => setState(() => _active = true) : null,
        onScaleUpdate: widget.enabled
            ? (d) {
                setState(() => _dot = d.localFocalPoint);
                if (d.pointerCount >= 2) {
                  _scrollBy(-d.focalPointDelta);
                } else {
                  widget.onMove(d.focalPointDelta);
                }
              }
            : null,
        onScaleEnd: widget.enabled ? (_) => setState(() => _active = false) : null,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          height: 300,
          decoration: BoxDecoration(
            color: _active ? scheme.secondaryContainer : scheme.surfaceContainerHigh,
            borderRadius: BorderRadius.circular(_active ? 36 : 28),
          ),
          child: Stack(
            children: [
              Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.touch_app_outlined, size: 36, color: scheme.onSurfaceVariant.withValues(alpha: 0.6)),
                    const SizedBox(height: 8),
                    Text(
                      widget.enabled
                          ? (isMobile
                                ? 'Drag to move · tap to click · two fingers to scroll'
                                : 'Drag to move · click to click · scroll to scroll')
                          : 'Not connected',
                      style: TextStyle(color: scheme.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
              if (_active && _dot != null)
                Positioned(
                  left: _dot!.dx - 14,
                  top: _dot!.dy - 14,
                  child: IgnorePointer(
                    child: Container(
                      width: 28,
                      height: 28,
                      decoration: BoxDecoration(color: scheme.primary.withValues(alpha: 0.35), shape: BoxShape.circle),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

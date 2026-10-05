import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';
import 'package:window_manager/window_manager.dart';

import '../app_state.dart';
import '../core/client.dart';
import '../core/mirror.dart';
import '../core/models.dart';
import '../platform/desktop_window.dart';
import 'widgets.dart';

/// The Screen Mirroring tab (Macs and PCs): watch a paired iPhone's or
/// Android phone's screen, live and lossless (see core/mirror.dart).
class MirrorPage extends StatelessWidget {
  const MirrorPage({super.key, required this.state, this.onGoToDevices});
  final AppState state;
  final VoidCallback? onGoToDevices;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: state,
    builder: (context, _) {
      final phones = state.paired.where((d) => d.platform.isPhone).toList();
      final count = phones.where((d) => state.isOnline(d.id)).length;
      return PageFrame(
        title: 'Screen Mirroring',
        subtitle: phones.isEmpty
            ? "See your phone's screen here, live"
            : '${phones.length} ${phones.length == 1 ? 'phone' : 'phones'} · $count online',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (phones.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 24),
                child: EmptyState(
                  icon: Icons.cast_rounded,
                  title: 'Pair your phone',
                  message:
                      'Install Sidekick on your iPhone or Android phone and pair with it on the Devices tab. Its '
                      'screen then shows up here, pixel for pixel.',
                  action: onGoToDevices == null
                      ? null
                      : FilledButton.tonalIcon(
                          onPressed: onGoToDevices,
                          icon: const Icon(Icons.devices_outlined),
                          label: const Text('Go to Devices'),
                        ),
                ),
              )
            else ...[
              const SectionLabel('Watch a phone', icon: Icons.cast_rounded),
              for (final (i, d) in phones.indexed)
                Entrance(
                  index: i,
                  child: _PhoneCard(state: state, device: d),
                ),
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 4, 4, 16),
                child: Text(
                  'The phone asks first. On an iPhone, tap Start Broadcast; on Android, Start now.',
                  style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
                ),
              ),
            ],
          ],
        ),
      );
    },
  );
}

extension on DevicePlatform {
  bool get isPhone => this == DevicePlatform.ios || this == DevicePlatform.android;
}

class _PhoneCard extends StatelessWidget {
  const _PhoneCard({required this.state, required this.device});
  final AppState state;
  final PairedDevice device;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final online = state.isOnline(device.id);
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            GradientBadge(
              icon: device.platform == DevicePlatform.ios ? Icons.phone_iphone_rounded : Icons.phone_android_rounded,
              size: 48,
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(device.name, style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 2),
                  Text(
                    online ? 'Ready · lossless' : 'Not reachable right now',
                    style: TextStyle(color: online ? scheme.primary : scheme.onSurfaceVariant),
                  ),
                ],
              ),
            ),
            FilledButton.icon(
              onPressed: online ? () => openMirror(context, state, device) : null,
              icon: const Icon(Icons.cast_rounded),
              label: const Text('Mirror'),
            ),
          ],
        ),
      ),
    );
  }
}

/// Settings on a phone: whether paired computers may see this screen, and
/// which ones can without asking.
class MirrorSettings extends StatelessWidget {
  const MirrorSettings({super.key, required this.state});
  final AppState state;

  @override
  Widget build(BuildContext context) {
    final always = state.paired.where((d) => state.mirrorAlways.contains(d.id)).toList();
    return Card(
      child: Column(
        children: [
          SwitchListTile(
            secondary: const IconTile(Icons.cast_rounded, tone: TileTone.primary),
            title: const Text('Let paired computers see this screen'),
            subtitle: const Text("They ask first, and you'll see who's watching"),
            value: state.permissions.mirror,
            onChanged: (v) => state.setPermissions(state.permissions.copyWith(mirror: v)),
          ),
          for (final d in always)
            ListTile(
              leading: const IconTile(Icons.verified_user_rounded, tone: TileTone.secondary),
              title: Text(d.name),
              subtitle: const Text('Can start without asking'),
              trailing: TextButton(onPressed: () => state.forgetMirrorAlways(d.id), child: const Text('Ask again')),
            ),
        ],
      ),
    );
  }
}

/// Asks the person holding this phone whether [request]'s computer may see
/// its screen.
Future<void> showMirrorRequest(BuildContext context, MirrorRequest request) async {
  final name = request.peer.name;
  await showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (context) => AlertDialog(
      icon: const Icon(Icons.cast_rounded),
      title: Text('Show your screen to $name?'),
      content: Text(
        '$name will see everything on this screen, live, even in other apps, until you or it stops. '
        '${hostIsIOS ? 'Next, tap Start Broadcast.' : 'Next, Android asks too: tap Start now.'}',
      ),
      actions: [
        TextButton(
          onPressed: () {
            request.deny();
            Navigator.pop(context);
          },
          child: const Text("Don't allow"),
        ),
        TextButton(
          onPressed: () {
            request.allow(always: true);
            Navigator.pop(context);
          },
          child: const Text('Always allow'),
        ),
        FilledButton(
          onPressed: () {
            request.allow();
            Navigator.pop(context);
          },
          child: const Text('Allow'),
        ),
      ],
    ),
  );
  // Closed some other way (the request timed out): it's a no.
  request.deny();
}

Future<void> openMirror(BuildContext context, AppState state, PairedDevice device) => Navigator.of(context).push(
  MaterialPageRoute<void>(
    builder: (_) => MirrorViewer(state: state, device: device),
    fullscreenDialog: true,
  ),
);

enum _Phase { connecting, waiting, live, failed }

/// A phone's screen, full screen: the picture, and how fast and sharp it's
/// coming in.
class MirrorViewer extends StatefulWidget {
  const MirrorViewer({super.key, required this.state, required this.device});
  final AppState state;
  final PairedDevice device;

  @override
  State<MirrorViewer> createState() => _MirrorViewerState();
}

class _MirrorViewerState extends State<MirrorViewer> {
  MirrorStream? _stream;
  MirrorZip? _zip;
  final _canvas = MirrorCanvas();
  ui.Image? _image;
  _Phase _phase = _Phase.connecting;
  String _message = 'Connecting…';
  bool _sharp = false;
  bool _fullScreen = false;
  final _queue = <Uint8List>[];
  bool _busy = false;
  int _shown = 0;
  int _fps = 0;
  int _bytes = 0;
  double _mbps = 0;
  Timer? _meter;
  final List<StreamSubscription<Object>> _subs = [];

  @override
  void initState() {
    super.initState();
    _meter = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() {
        _fps = _shown;
        _mbps = _bytes * 8 / 1e6;
        _shown = 0;
        _bytes = 0;
      });
    });
    unawaited(_connect());
  }

  @override
  void dispose() {
    _meter?.cancel();
    unawaited(_close());
    _image?.dispose();
    if (_fullScreen) unawaited(windowManager.setFullScreen(false));
    super.dispose();
  }

  Future<void> _close() async {
    for (final s in _subs) {
      await s.cancel();
    }
    _subs.clear();
    final stream = _stream;
    _stream = null;
    _zip?.close();
    _zip = null;
    _queue.clear();
    await stream?.close();
  }

  Future<void> _connect() async {
    await _close();
    setState(() {
      _phase = _Phase.connecting;
      _message = 'Connecting…';
    });
    try {
      final id = widget.device.id;
      // Mirroring needs Wi-Fi; with only Bluetooth, set up a direct link.
      if (widget.state.viaBluetooth(id) || widget.state.viaDirectLinkOnly(id)) {
        setState(() => _message = 'Setting up a direct Wi-Fi link…');
        await widget.state.connectDirect(widget.device);
      }
      final zip = await MirrorZip.start();
      final stream = await widget.state.clientFor(widget.device).openMirror(sharp: _sharp);
      if (!mounted) {
        zip.close();
        await stream.close();
        return;
      }
      _zip = zip;
      _stream = stream;
      _subs
        ..add(stream.frames.listen(_onFrame, onDone: _onClosed))
        ..add(
          stream.messages.listen((m) {
            if (!mounted) return;
            setState(() {
              switch (m.type) {
                case 'status':
                  _phase = _Phase.waiting;
                  _message = m.message;
                case 'started':
                  _phase = _Phase.live;
                case 'error':
                  _phase = _Phase.failed;
                  _message = m.message;
              }
            });
          }),
        );
    } catch (e) {
      if (mounted) {
        setState(() {
          _phase = _Phase.failed;
          _message = '$e';
        });
      }
    }
  }

  void _onClosed() {
    if (!mounted || _phase == _Phase.failed) return;
    setState(() {
      _phase = _Phase.failed;
      _message = 'Mirroring stopped.';
    });
  }

  void _onFrame(Uint8List compressed) {
    _bytes += compressed.length;
    _queue.add(compressed);
    unawaited(_drain());
  }

  /// Applies every packet that came in (in order: each builds on the last),
  /// then shows the newest picture once.
  Future<void> _drain() async {
    if (_busy) return;
    _busy = true;
    try {
      while (_queue.isNotEmpty && mounted) {
        final batch = List.of(_queue);
        _queue.clear();
        var changed = false;
        for (final z in batch) {
          final zip = _zip, stream = _stream;
          if (zip == null || stream == null) return;
          final packet = MirrorPacket.parse(await zip.decompress(z));
          _canvas.apply(packet);
          changed |= packet.tiles.isNotEmpty;
          stream.ack();
        }
        if (_canvas.isEmpty) continue;
        if (!changed) {
          // Only the pointer moved.
          if (mounted) setState(() {});
          continue;
        }
        final image = await _decode();
        if (!mounted) {
          image.dispose();
          return;
        }
        setState(() {
          _image?.dispose();
          _image = image;
          _phase = _Phase.live;
          _shown++;
        });
      }
    } catch (e) {
      // A damaged packet: start over from a full picture.
      _stream?.keyframe();
    } finally {
      _busy = false;
    }
  }

  Future<ui.Image> _decode() {
    final done = Completer<ui.Image>();
    ui.decodeImageFromPixels(
      _canvas.pixels,
      _canvas.width,
      _canvas.height,
      _canvas.rgba ? ui.PixelFormat.rgba8888 : ui.PixelFormat.bgra8888,
      done.complete,
    );
    return done.future;
  }

  /// Every pixel or half size: the phone switches without asking again.
  void _setSharp(bool sharp) {
    if (sharp == _sharp) return;
    setState(() => _sharp = sharp);
    _stream?.sharp(sharp);
  }

  Future<void> _toggleFullScreen() async {
    final next = !_fullScreen;
    await windowManager.setFullScreen(next);
    if (mounted) setState(() => _fullScreen = next);
  }

  @override
  Widget build(BuildContext context) {
    final image = _image;
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          Positioned.fill(
            child: image == null
                ? _Status(phase: _phase, message: _message, onRetry: _connect)
                : InteractiveViewer(
                    maxScale: 6,
                    child: Center(
                      // An iPhone app held sideways arrives upright for the
                      // phone; turned here.
                      child: RotatedBox(
                        quarterTurns: _canvas.turns,
                        child: AspectRatio(
                          aspectRatio: image.width / image.height,
                          child: Stack(
                            fit: StackFit.expand,
                            children: [
                              RawImage(image: image, fit: BoxFit.fill, filterQuality: FilterQuality.medium),
                              if (_canvas.cursorX >= 0)
                                CustomPaint(
                                  painter: _PointerPainter(
                                    _canvas.cursorX / _canvas.width,
                                    _canvas.cursorY / _canvas.height,
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
          ),
          if (image != null && _phase == _Phase.failed)
            Positioned.fill(
              child: ColoredBox(
                color: Colors.black54,
                child: _Status(phase: _phase, message: _message, onRetry: _connect),
              ),
            ),
          Positioned(
            left: 0,
            right: 0,
            top: 0,
            child: SafeArea(
              child: _TopBar(
                name: widget.device.name,
                detail: image == null
                    ? null
                    : '${_canvas.width}×${_canvas.height} · lossless · $_fps fps · ${_mbps.toStringAsFixed(1)} Mbit/s',
                sharp: _sharp,
                onSharp: _setSharp,
                fullScreen: DesktopWindow.supported ? _fullScreen : null,
                onFullScreen: _toggleFullScreen,
                onClose: () => Navigator.pop(context),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _TopBar extends StatelessWidget {
  const _TopBar({
    required this.name,
    required this.detail,
    required this.sharp,
    required this.onSharp,
    required this.fullScreen,
    required this.onFullScreen,
    required this.onClose,
  });

  final String name;
  final String? detail;
  final bool sharp;
  final ValueChanged<bool> onSharp;
  final bool? fullScreen;
  final VoidCallback onFullScreen;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(10),
      child: Container(
        padding: const EdgeInsets.fromLTRB(16, 6, 6, 6),
        decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.55), borderRadius: BorderRadius.circular(18)),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    name,
                    style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (detail != null)
                    Text(
                      detail!,
                      style: const TextStyle(color: Colors.white70, fontSize: 12),
                      overflow: TextOverflow.ellipsis,
                    ),
                ],
              ),
            ),
            Tooltip(
              message: sharp ? 'Every pixel of the phone' : 'Half size each way: fastest, still lossless',
              child: SegmentedButton<bool>(
                style: SegmentedButton.styleFrom(
                  foregroundColor: Colors.white,
                  selectedForegroundColor: Colors.black,
                  selectedBackgroundColor: Colors.white,
                  visualDensity: VisualDensity.compact,
                ),
                showSelectedIcon: false,
                segments: const [
                  ButtonSegment(value: false, label: Text('Fast')),
                  ButtonSegment(value: true, label: Text('Sharp')),
                ],
                selected: {sharp},
                onSelectionChanged: (s) => onSharp(s.first),
              ),
            ),
            if (fullScreen != null)
              IconButton(
                tooltip: fullScreen! ? 'Exit full screen' : 'Full screen',
                color: Colors.white,
                onPressed: onFullScreen,
                icon: Icon(fullScreen! ? Icons.fullscreen_exit_rounded : Icons.fullscreen_rounded),
              ),
            IconButton(tooltip: 'Stop', color: Colors.white, onPressed: onClose, icon: const Icon(Icons.close_rounded)),
          ],
        ),
      ),
    );
  }
}

class _Status extends StatelessWidget {
  const _Status({required this.phase, required this.message, required this.onRetry});
  final _Phase phase;
  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final failed = phase == _Phase.failed;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (failed)
              const Icon(Icons.mobile_off_rounded, color: Colors.white70, size: 48)
            else
              const SizedBox.square(dimension: 36, child: CircularProgressIndicator(color: Colors.white)),
            const SizedBox(height: 20),
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white, fontSize: 16),
            ),
            if (failed) ...[
              const SizedBox(height: 20),
              FilledButton.tonalIcon(
                onPressed: onRetry,
                icon: const Icon(Icons.refresh_rounded),
                label: const Text('Try again'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// A pointer, drawn here (it isn't in the picture, so moving it costs
/// almost nothing to send). Phones have none; kept for sources that do.
class _PointerPainter extends CustomPainter {
  _PointerPainter(this.fx, this.fy);
  final double fx, fy;

  @override
  void paint(Canvas canvas, Size size) {
    final x = fx * size.width, y = fy * size.height;
    final path = Path()
      ..moveTo(x, y)
      ..lineTo(x, y + 18)
      ..lineTo(x + 4.5, y + 13.5)
      ..lineTo(x + 8, y + 21)
      ..lineTo(x + 11, y + 19.6)
      ..lineTo(x + 7.6, y + 12.4)
      ..lineTo(x + 13.6, y + 12.4)
      ..close();
    canvas.drawShadow(path, Colors.black, 2, false);
    canvas.drawPath(path, Paint()..color = Colors.black);
    canvas.drawPath(
      path,
      Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.4,
    );
  }

  @override
  bool shouldRepaint(_PointerPainter old) => old.fx != fx || old.fy != fy;
}

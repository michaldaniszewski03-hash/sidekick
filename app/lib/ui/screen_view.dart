import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../app_state.dart';
import '../core/client.dart';
import '../core/models.dart';
import 'widgets.dart';

/// Shows another device's screen live and turns clicks, taps and drags on
/// it into input at the same spot over there.
///
/// With a mouse: the pointer follows yours, clicks and drags go through,
/// the wheel scrolls, and keys go there while the view has focus.
/// On a touch screen: tap = click, double-tap = double-click, long-press =
/// right-click, long-press then move = drag, pinch or two fingers = zoom.
class ScreenView extends StatefulWidget {
  const ScreenView({
    super.key,
    required this.state,
    required this.device,
    required this.input,
    this.onKey,
    this.expanded = false,
  });

  final AppState state;
  final PairedDevice device;

  /// The remote-control session to send input through (null: view only).
  final InputSession? Function() input;

  /// Handles physical keys while the view has focus.
  final KeyEventResult Function(FocusNode node, KeyEvent event)? onKey;

  /// Fill the available space (full-window mode) instead of fitting the page.
  final bool expanded;

  @override
  State<ScreenView> createState() => _ScreenViewState();
}

class _ScreenViewState extends State<ScreenView> {
  ScreenSession? _session;
  StreamSubscription<Uint8List>? _frames;
  StreamSubscription<void>? _notes;
  ui.Image? _image;
  String? _error;
  String? _status;
  bool _connecting = true;
  final _focus = FocusNode();
  final _zoom = TransformationController();

  // Mouse state.
  String? _held;

  // Touch drag state.
  Offset? _pressAt;
  bool _dragging = false;

  InputSession? get _in => widget.input();

  @override
  void initState() {
    super.initState();
    _open();
  }

  @override
  void dispose() {
    _close();
    _image?.dispose();
    _focus.dispose();
    _zoom.dispose();
    super.dispose();
  }

  void _close() {
    _frames?.cancel();
    _notes?.cancel();
    _session?.close();
    _session = null;
  }

  Future<void> _open() async {
    _close();
    setState(() {
      _connecting = true;
      _error = null;
      _status = null;
    });
    try {
      final session = await widget.state
          .clientFor(widget.device)
          .openScreen(maxWidth: isMobile ? 1280 : 1920, quality: isMobile ? 55 : 65);
      if (!mounted) {
        await session.close();
        return;
      }
      _session = session;
      _notes = session.notes.listen((_) {
        if (mounted) {
          setState(() {
            _status = session.status;
            _error = session.error;
          });
        }
      });
      _frames = session.frames.listen(
        _onFrame,
        onDone: () {
          if (mounted && _session == session) {
            setState(() {
              _session = null;
              _error ??= session.error ?? 'Screen sharing ended.';
            });
          }
        },
      );
      setState(() => _connecting = false);
    } catch (e) {
      if (mounted) {
        setState(() {
          _connecting = false;
          _error = '$e';
        });
      }
    }
  }

  Future<void> _onFrame(Uint8List bytes) async {
    final session = _session;
    try {
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      codec.dispose();
      if (!mounted) {
        frame.image.dispose();
        return;
      }
      final old = _image;
      setState(() {
        _image = frame.image;
        _status = null;
      });
      old?.dispose();
    } catch (_) {
      // A bad frame; just ask for the next one.
    }
    // Only now ask for the next frame, so we never fall behind.
    session?.ack();
  }

  // -------------------------------------------------------------- input

  /// [p] in the image's own coordinates, [size] the image's laid-out size.
  void _moveTo(Offset p, Size size) =>
      _in?.moveTo((p.dx / size.width).clamp(0.0, 1.0), (p.dy / size.height).clamp(0.0, 1.0));

  static String _buttonOf(int buttons) {
    if (buttons & kSecondaryMouseButton != 0) return 'right';
    if (buttons & kMiddleMouseButton != 0) return 'middle';
    return 'left';
  }

  Widget _mouseLayer(Size size, Widget child) => Focus(
    focusNode: _focus,
    onKeyEvent: widget.onKey,
    child: MouseRegion(
      cursor: SystemMouseCursors.precise,
      onHover: (e) => _moveTo(e.localPosition, size),
      child: Listener(
        onPointerDown: (e) {
          if (e.kind == PointerDeviceKind.touch) return;
          _focus.requestFocus();
          final s = _in;
          if (s == null) return;
          _moveTo(e.localPosition, size);
          _held = _buttonOf(e.buttons);
          s.buttonDown(_held!);
        },
        onPointerMove: (e) {
          if (_held != null) _moveTo(e.localPosition, size);
        },
        onPointerUp: (e) {
          final held = _held;
          _held = null;
          if (held != null) {
            _moveTo(e.localPosition, size);
            _in?.buttonUp(held);
          }
        },
        onPointerSignal: (e) {
          if (e is PointerScrollEvent) {
            // One wheel notch is ~50 logical pixels here and 120 units there.
            _in?.scroll(
              dx: (e.scrollDelta.dx * 2.4).round().clamp(-1200, 1200),
              dy: (-e.scrollDelta.dy * 2.4).round().clamp(-1200, 1200),
            );
          }
        },
        child: child,
      ),
    ),
  );

  Widget _touchLayer(Size size, Widget child) => GestureDetector(
    onTapUp: (d) {
      final s = _in;
      if (s == null) return;
      _moveTo(d.localPosition, size);
      s.click();
    },
    onDoubleTapDown: (d) => _pressAt = d.localPosition,
    onDoubleTap: () {
      final s = _in;
      final at = _pressAt;
      if (s == null || at == null) return;
      _moveTo(at, size);
      s.click(count: 2);
    },
    onLongPressStart: (d) {
      _pressAt = d.localPosition;
      _dragging = false;
      HapticFeedback.mediumImpact();
    },
    onLongPressMoveUpdate: (d) {
      final s = _in;
      final start = _pressAt;
      if (s == null || start == null) return;
      if (!_dragging && (d.localPosition - start).distance > 12) {
        _dragging = true;
        _moveTo(start, size);
        s.buttonDown();
      }
      if (_dragging) _moveTo(d.localPosition, size);
    },
    onLongPressEnd: (d) {
      final s = _in;
      final start = _pressAt;
      if (s == null || start == null) return;
      if (_dragging) {
        _moveTo(d.localPosition, size);
        s.buttonUp();
      } else {
        _moveTo(start, size);
        s.click(button: 'right');
      }
      _dragging = false;
    },
    child: child,
  );

  // -------------------------------------------------------------- build

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final image = _image;
    final Widget content;
    if (image == null) {
      content = AspectRatio(
        aspectRatio: 16 / 9,
        child: Container(
          decoration: BoxDecoration(color: scheme.surfaceContainerHighest, borderRadius: BorderRadius.circular(20)),
          padding: const EdgeInsets.all(24),
          child: Center(child: _placeholder(scheme)),
        ),
      );
    } else {
      final aspect = image.width / image.height;
      final screen = AspectRatio(
        aspectRatio: aspect,
        child: LayoutBuilder(
          builder: (context, box) {
            final size = box.biggest;
            final picture = RawImage(image: image, fit: BoxFit.fill, filterQuality: FilterQuality.medium);
            return isMobile ? _touchLayer(size, picture) : _mouseLayer(size, picture);
          },
        ),
      );
      final framed = ClipRRect(
        borderRadius: BorderRadius.circular(widget.expanded ? 0 : 16),
        child: isMobile ? InteractiveViewer(transformationController: _zoom, maxScale: 6, child: screen) : screen,
      );
      content = Stack(
        children: [
          Center(child: framed),
          if (_error != null)
            Positioned(
              left: 12,
              right: 12,
              bottom: 12,
              child: _ErrorBar(message: _error!, onRetry: _open),
            ),
        ],
      );
    }
    return widget.expanded ? Container(color: Colors.black, child: content) : content;
  }

  Widget _placeholder(ColorScheme scheme) {
    if (_error != null) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.desktop_access_disabled_outlined, size: 40, color: scheme.error),
          const SizedBox(height: 12),
          Text(_error!, textAlign: TextAlign.center),
          const SizedBox(height: 12),
          FilledButton.tonal(onPressed: _open, child: const Text('Try again')),
        ],
      );
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const CircularProgressIndicator(),
        const SizedBox(height: 16),
        Text(
          _status ?? (_connecting ? 'Connecting to ${widget.device.name}…' : 'Waiting for the first picture…'),
          textAlign: TextAlign.center,
        ),
      ],
    );
  }
}

class _ErrorBar extends StatelessWidget {
  const _ErrorBar({required this.message, required this.onRetry});
  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.errorContainer,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
          children: [
            Expanded(
              child: Text(message, style: TextStyle(color: scheme.onErrorContainer)),
            ),
            TextButton(onPressed: onRetry, child: const Text('Reconnect')),
          ],
        ),
      ),
    );
  }
}

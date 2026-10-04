import 'dart:async';
import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import '../app_state.dart';
import '../core/models.dart';
import '../platform/desktop_window.dart';
import '../platform/notifications.dart';
import 'widgets.dart';

/// Another device pinged this one: the ringtone plays on repeat (AppState
/// starts it) until Found It here. In the tray the window opens for it; on
/// a phone in the background a notification says who.
Future<void> showPinged(BuildContext context, AppState state, TrustedPeer from) async {
  OfferNotifications.showPing(from.name);
  if (DesktopWindow.supported) await DesktopWindow.instance.open();
  if (!context.mounted) return state.foundIt();
  await showDialog<void>(
    context: context,
    // Only Found It stops it.
    barrierDismissible: false,
    builder: (context) => PopScope(canPop: false, child: _PingDialog(from: from)),
  );
  state.foundIt();
}

/// The Ping button found the device already ringing.
Future<void> showAlreadyPinged(BuildContext context, String name) => showDialog<void>(
  context: context,
  builder: (context) => AlertDialog(
    icon: const Icon(Icons.notifications_active_rounded),
    title: const Text('This device is already being pinged'),
    content: Text('$name keeps ringing until someone taps Found It on it.'),
    actions: [FilledButton(onPressed: () => Navigator.pop(context), child: const Text('OK'))],
  ),
);

class _PingDialog extends StatefulWidget {
  const _PingDialog({required this.from});
  final TrustedPeer from;

  @override
  State<_PingDialog> createState() => _PingDialogState();
}

class _PingDialogState extends State<_PingDialog> with SingleTickerProviderStateMixin {
  late final AnimationController _waves = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!MediaQuery.of(context).disableAnimations && !_waves.isAnimating) unawaited(_waves.repeat());
  }

  @override
  void dispose() {
    _waves.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AlertDialog(
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox.square(
            dimension: 132,
            child: AnimatedBuilder(
              animation: _waves,
              builder: (_, child) => CustomPaint(painter: _Waves(_waves.value, scheme.primary), child: child),
              child: const Center(child: GradientBadge(icon: Icons.notifications_active_rounded, size: 64)),
            ),
          ),
          const SizedBox(height: 12),
          Text(
            '${widget.from.name} is pinging you',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 6),
          Text(
            'It keeps ringing until you tap Found It.',
            textAlign: TextAlign.center,
            style: TextStyle(color: scheme.onSurfaceVariant),
          ),
        ],
      ),
      actionsAlignment: MainAxisAlignment.center,
      actions: [
        FilledButton.icon(
          onPressed: () => Navigator.pop(context),
          style: FilledButton.styleFrom(minimumSize: const Size(200, 52)),
          icon: const Icon(Icons.check_circle_rounded),
          label: const Text('Found It!'),
        ),
      ],
    );
  }
}

/// Sound waves spreading out from the bell.
class _Waves extends CustomPainter {
  _Waves(this.t, this.color);
  final double t;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    for (final shift in [0.0, 0.33, 0.66]) {
      final p = (t + shift) % 1;
      canvas.drawCircle(
        center,
        36 + p * (size.width / 2 - 36),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3 * (1 - p) + 1
          ..color = color.withValues(alpha: 0.5 * math.pow(1 - p, 1.5).toDouble()),
      );
    }
  }

  @override
  bool shouldRepaint(_Waves old) => old.t != t || old.color != color;
}

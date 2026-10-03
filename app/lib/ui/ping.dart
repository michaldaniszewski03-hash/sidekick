import 'dart:async';
import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import '../core/models.dart';
import '../platform/desktop_window.dart';
import '../platform/notifications.dart';
import '../platform/sound.dart';
import 'widgets.dart';

/// Another device pinged this one: a loud ping, three times (about 5 s),
/// and a card saying who, with Stop. In the tray, the window opens for it;
/// on a phone in the background, a notification says who.
Future<void> showPinged(BuildContext context, TrustedPeer from) async {
  final repeats = Timer.periodic(const Duration(milliseconds: 1700), (t) {
    if (t.tick < 3) unawaited(playPingSound());
    if (t.tick >= 2) t.cancel();
  });
  unawaited(playPingSound());
  OfferNotifications.showPing(from.name);
  if (DesktopWindow.supported) await DesktopWindow.instance.open();
  if (!context.mounted) return repeats.cancel();
  await showDialog<void>(
    context: context,
    builder: (context) => _PingDialog(from: from),
  );
  repeats.cancel();
}

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
            'Ping from ${widget.from.name}',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 6),
          Text(
            'It wanted to find this device, or to get your attention.',
            textAlign: TextAlign.center,
            style: TextStyle(color: scheme.onSurfaceVariant),
          ),
        ],
      ),
      actionsAlignment: MainAxisAlignment.center,
      actions: [FilledButton(onPressed: () => Navigator.pop(context), child: const Text('Stop'))],
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

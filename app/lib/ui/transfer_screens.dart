import 'dart:async';
import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import '../app_state.dart';
import '../core/server.dart';
import 'widgets.dart';

// ------------------------------------------------------------------ sender

/// Shows [send] full screen: waiting for the other device to accept, then
/// the progress, then it closes by itself.
Future<void> showSendingScreen(BuildContext context, OutgoingSend send) => Navigator.of(context).push(
  PageRouteBuilder<void>(
    transitionDuration: const Duration(milliseconds: 450),
    reverseTransitionDuration: const Duration(milliseconds: 300),
    pageBuilder: (_, _, _) => SendingScreen(send: send),
    transitionsBuilder: (_, animation, _, child) {
      final curved = CurvedAnimation(parent: animation, curve: Curves.easeOutCubic);
      return FadeTransition(
        opacity: curved,
        child: ScaleTransition(scale: Tween(begin: 0.94, end: 1.0).animate(curved), child: child),
      );
    },
  ),
);

class SendingScreen extends StatefulWidget {
  const SendingScreen({super.key, required this.send});
  final OutgoingSend send;

  @override
  State<SendingScreen> createState() => _SendingScreenState();
}

class _SendingScreenState extends State<SendingScreen> {
  OutgoingSend get send => widget.send;
  Timer? _close;
  bool _closing = false;

  @override
  void initState() {
    super.initState();
    send.addListener(_changed);
  }

  @override
  void dispose() {
    send.removeListener(_changed);
    _close?.cancel();
    super.dispose();
  }

  void _changed() {
    if (send.cancelled) return _leave();
    // Finished: let the result sink in, then back to the app.
    final wait = switch (send.phase) {
      SendPhase.done => const Duration(milliseconds: 1500),
      SendPhase.declined || SendPhase.noAnswer => const Duration(milliseconds: 2800),
      _ => null,
    };
    if (wait != null) _close ??= Timer(wait, _leave);
    setState(() {});
  }

  void _leave() {
    if (_closing || !mounted) return;
    _closing = true;
    Navigator.of(context).maybePop();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final d = send.device;
    final what = send.names.length == 1 ? send.names.first : '${send.names.length} files';
    final (title, subtitle) = switch (send.phase) {
      SendPhase.connecting => ('Connecting…', 'Reaching ${d.name}'),
      SendPhase.waiting => ('Waiting for permission…', 'Ask ${d.name} to tap Accept'),
      SendPhase.sending => ('Sending to ${d.name}', what),
      SendPhase.done => ('Sent!', '$what ${send.names.length == 1 ? 'is' : 'are'} on ${d.name}'),
      SendPhase.declined => ('${d.name} declined', 'Nothing was sent'),
      SendPhase.noAnswer => ('No answer', 'Nobody accepted on ${d.name} in time. Nothing was sent.'),
      SendPhase.failed => ("Couldn't send", send.error ?? 'Something went wrong'),
    };
    return Scaffold(
      body: DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [scheme.primaryContainer.withValues(alpha: 0.55), scheme.surface],
          ),
        ),
        child: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 480),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
                child: Column(
                  children: [
                    const Spacer(flex: 2),
                    SizedBox(
                      width: 260,
                      height: 260,
                      child: _SendGraphic(send: send, icon: platformIcon(d.platform)),
                    ),
                    const SizedBox(height: 32),
                    AnimatedSwitcher(
                      duration: const Duration(milliseconds: 300),
                      transitionBuilder: (child, a) => FadeTransition(
                        opacity: a,
                        child: SlideTransition(
                          position: Tween(begin: const Offset(0, 0.25), end: Offset.zero).animate(a),
                          child: child,
                        ),
                      ),
                      child: Column(
                        key: ValueKey(send.phase),
                        children: [
                          Text(
                            title,
                            textAlign: TextAlign.center,
                            style: text.headlineMedium?.copyWith(fontWeight: FontWeight.w700),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            subtitle,
                            textAlign: TextAlign.center,
                            maxLines: 3,
                            overflow: TextOverflow.ellipsis,
                            style: text.bodyLarge?.copyWith(color: scheme.onSurfaceVariant),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 28),
                    AnimatedSize(
                      duration: const Duration(milliseconds: 300),
                      curve: Curves.easeOutCubic,
                      child: send.phase == SendPhase.sending ? _progress(context) : const SizedBox(width: 1),
                    ),
                    const Spacer(flex: 3),
                    _actions(),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _progress(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final many = send.names.length > 1;
    return Column(
      children: [
        TweenAnimationBuilder<double>(
          tween: Tween(end: send.fraction),
          duration: const Duration(milliseconds: 250),
          builder: (context, value, _) => ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: LinearProgressIndicator(
              value: value,
              minHeight: 12,
              backgroundColor: scheme.surfaceContainerHighest,
            ),
          ),
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: Text(
                many ? 'File ${send.current + 1} of ${send.names.length}: ${send.names[send.current]}' : '',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: scheme.onSurfaceVariant),
              ),
            ),
            Text(
              '${formatBytes(send.done)} of ${formatBytes(send.total)}',
              style: TextStyle(color: scheme.onSurfaceVariant, fontFeatures: const [FontFeature.tabularFigures()]),
            ),
          ],
        ),
      ],
    );
  }

  Widget _actions() {
    final (label, onPressed) = switch (send.phase) {
      SendPhase.connecting || SendPhase.waiting => ('Cancel', send.cancel),
      // It keeps going in the background; the Files tab shows it.
      SendPhase.sending => ('Hide', _leave),
      _ => ('Close', _leave),
    };
    return SizedBox(
      width: double.infinity,
      child: send.phase == SendPhase.failed
          ? FilledButton(
              onPressed: onPressed,
              style: FilledButton.styleFrom(minimumSize: const Size(0, 52)),
              child: Text(label),
            )
          : OutlinedButton(
              onPressed: onPressed,
              style: OutlinedButton.styleFrom(minimumSize: const Size(0, 52)),
              child: Text(label),
            ),
    );
  }
}

/// The picture in the middle: radar rings while waiting, a progress ring
/// while sending, a check (or a cross) at the end.
class _SendGraphic extends StatefulWidget {
  const _SendGraphic({required this.send, required this.icon});
  final OutgoingSend send;
  final IconData icon;

  @override
  State<_SendGraphic> createState() => _SendGraphicState();
}

class _SendGraphicState extends State<_SendGraphic> with SingleTickerProviderStateMixin {
  late final AnimationController _loop = AnimationController(vsync: this, duration: const Duration(seconds: 2))
    ..repeat();

  @override
  void dispose() {
    _loop.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final send = widget.send;
    final phase = send.phase;
    final waiting = phase == SendPhase.connecting || phase == SendPhase.waiting;
    final ok = phase == SendPhase.done;
    final bad = phase == SendPhase.declined || phase == SendPhase.noAnswer || phase == SendPhase.failed;
    return Stack(
      alignment: Alignment.center,
      children: [
        if (waiting)
          AnimatedBuilder(
            animation: _loop,
            builder: (_, _) => CustomPaint(
              size: const Size.square(260),
              painter: _Rings(progress: _loop.value, color: scheme.primary),
            ),
          ),
        if (phase == SendPhase.sending)
          TweenAnimationBuilder<double>(
            tween: Tween(end: send.fraction),
            duration: const Duration(milliseconds: 250),
            builder: (_, value, _) => CustomPaint(
              size: const Size.square(200),
              painter: _Arc(value: value, color: scheme.primary, track: scheme.surfaceContainerHighest),
            ),
          ),
        AnimatedContainer(
          duration: const Duration(milliseconds: 400),
          curve: Curves.easeOutBack,
          width: ok || bad ? 150 : 120,
          height: ok || bad ? 150 : 120,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: bad
                  ? [scheme.errorContainer, scheme.errorContainer]
                  : ok
                  ? [Colors.green.shade400, Colors.green.shade700]
                  : [scheme.primary, scheme.tertiary],
            ),
            boxShadow: [
              BoxShadow(
                color: (bad ? scheme.error : scheme.primary).withValues(alpha: 0.3),
                blurRadius: 32,
                spreadRadius: 2,
              ),
            ],
          ),
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 450),
            transitionBuilder: (child, a) => ScaleTransition(
              scale: CurvedAnimation(parent: a, curve: Curves.elasticOut),
              child: child,
            ),
            child: phase == SendPhase.sending
                ? Text(
                    '${(send.fraction * 100).floor()}%',
                    key: const ValueKey('percent'),
                    style: TextStyle(
                      color: scheme.onPrimary,
                      fontSize: 30,
                      fontWeight: FontWeight.w700,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  )
                : Icon(
                    ok
                        ? Icons.check_rounded
                        : bad
                        ? (phase == SendPhase.noAnswer ? Icons.hourglass_empty_rounded : Icons.close_rounded)
                        : widget.icon,
                    key: ValueKey(phase),
                    size: ok || bad ? 72 : 52,
                    color: bad ? scheme.onErrorContainer : (ok ? Colors.white : scheme.onPrimary),
                  ),
          ),
        ),
        // A file waiting to fly over, bobbing above the device.
        if (waiting)
          AnimatedBuilder(
            animation: _loop,
            builder: (_, child) =>
                Transform.translate(offset: Offset(58, -64 + 6 * math.sin(_loop.value * 2 * math.pi)), child: child),
            child: _FileChip(count: send.names.length),
          ),
      ],
    );
  }
}

class _FileChip extends StatelessWidget {
  const _FileChip({required this.count});
  final int count;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(14),
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.15), blurRadius: 12, offset: const Offset(0, 4))],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.insert_drive_file_rounded, color: scheme.primary, size: 22),
          if (count > 1) ...[
            const SizedBox(width: 4),
            Text(
              '×$count',
              style: TextStyle(fontWeight: FontWeight.w700, color: scheme.primary),
            ),
          ],
        ],
      ),
    );
  }
}

/// Three rings spreading out and fading, like a radar ping.
class _Rings extends CustomPainter {
  _Rings({required this.progress, required this.color});
  final double progress;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final maxRadius = size.shortestSide / 2;
    for (var i = 0; i < 3; i++) {
      final t = (progress + i / 3) % 1.0;
      final radius = 60 + (maxRadius - 60) * Curves.easeOut.transform(t);
      canvas.drawCircle(
        center,
        radius,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3
          ..color = color.withValues(alpha: (1 - t) * 0.5),
      );
    }
  }

  @override
  bool shouldRepaint(_Rings old) => old.progress != progress || old.color != color;
}

/// A round progress ring.
class _Arc extends CustomPainter {
  _Arc({required this.value, required this.color, required this.track});
  final double value;
  final Color color;
  final Color track;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 10
      ..strokeCap = StrokeCap.round;
    canvas.drawArc(rect.deflate(5), 0, 2 * math.pi, false, stroke..color = track);
    canvas.drawArc(rect.deflate(5), -math.pi / 2, 2 * math.pi * value, false, stroke..color = color);
  }

  @override
  bool shouldRepaint(_Arc old) => old.value != value || old.color != color || old.track != track;
}

// ------------------------------------------------------------------ receiver

/// Asks whether to accept [offer], with an animated card. Once accepted it
/// shows the files coming in and closes when they're all here. Closes by
/// itself if the sender gives up or time runs out.
Future<void> showIncomingOffer(BuildContext context, TransferOffer offer) => showGeneralDialog<void>(
  context: context,
  barrierDismissible: false,
  barrierLabel: 'Incoming files',
  barrierColor: Colors.black54,
  transitionDuration: const Duration(milliseconds: 550),
  pageBuilder: (_, _, _) => _IncomingOffer(offer: offer),
  transitionBuilder: (_, animation, _, child) => FadeTransition(
    opacity: CurvedAnimation(parent: animation, curve: Curves.easeOut),
    child: ScaleTransition(
      scale: Tween(begin: 0.7, end: 1.0).animate(CurvedAnimation(parent: animation, curve: Curves.easeOutBack)),
      child: child,
    ),
  ),
);

class _IncomingOffer extends StatefulWidget {
  const _IncomingOffer({required this.offer});
  final TransferOffer offer;

  @override
  State<_IncomingOffer> createState() => _IncomingOfferState();
}

enum _Stage { asking, receiving, done, gone }

class _IncomingOfferState extends State<_IncomingOffer> with TickerProviderStateMixin {
  TransferOffer get offer => widget.offer;
  late final AnimationController _loop = AnimationController(vsync: this, duration: const Duration(seconds: 2))
    ..repeat();

  /// Time left to answer, running down.
  late final AnimationController _countdown = AnimationController(vsync: this, duration: SidekickServer.offerTimeout)
    ..reverse(from: 1);
  _Stage _stage = _Stage.asking;
  int _received = 0;
  StreamSubscription<int>? _progress;
  bool _closing = false;

  @override
  void initState() {
    super.initState();
    offer.answer.then((answer) {
      if (!mounted || answer == OfferAnswer.accepted) return;
      // The sender gave up, or time ran out.
      if (_stage == _Stage.asking) {
        setState(() => _stage = _Stage.gone);
        Timer(const Duration(milliseconds: 1400), _leave);
      }
    });
  }

  @override
  void dispose() {
    _loop.dispose();
    _countdown.dispose();
    _progress?.cancel();
    super.dispose();
  }

  void _leave() {
    if (_closing || !mounted) return;
    _closing = true;
    Navigator.of(context).pop();
  }

  void _accept() {
    offer.accept();
    _countdown.stop();
    setState(() => _stage = _Stage.receiving);
    _progress = offer.progress.listen(
      (bytes) => setState(() => _received = bytes),
      onDone: () {
        if (!mounted) return;
        setState(() => _stage = _Stage.done);
        Timer(const Duration(milliseconds: 1300), _leave);
      },
    );
  }

  void _decline() {
    offer.decline();
    _leave();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final files = offer.files;
    final what = files.length == 1 ? files.first.name : '${files.length} files';
    final total = offer.totalBytes;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Material(
            color: scheme.surfaceContainerHigh,
            borderRadius: BorderRadius.circular(32),
            clipBehavior: Clip.antiAlias,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 28, 24, 20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox(height: 150, width: 200, child: _graphic(scheme)),
                  const SizedBox(height: 16),
                  AnimatedSwitcher(
                    duration: const Duration(milliseconds: 250),
                    child: Text(
                      switch (_stage) {
                        _Stage.asking => '${offer.from.name} wants to send you',
                        _Stage.receiving => 'Receiving from ${offer.from.name}…',
                        _Stage.done => 'All here!',
                        _Stage.gone => '${offer.from.name} stopped sending',
                      },
                      key: ValueKey(_stage),
                      textAlign: TextAlign.center,
                      style: text.titleLarge?.copyWith(fontWeight: FontWeight.w700),
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    total > 0 ? '$what · ${formatBytes(total)}' : what,
                    textAlign: TextAlign.center,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: text.bodyLarge?.copyWith(color: scheme.onSurfaceVariant),
                  ),
                  if (_stage == _Stage.asking && files.length > 1) ...[
                    const SizedBox(height: 12),
                    for (final f in files.take(3))
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 2),
                        child: Row(
                          children: [
                            Icon(Icons.insert_drive_file_outlined, size: 18, color: scheme.onSurfaceVariant),
                            const SizedBox(width: 8),
                            Expanded(child: Text(f.name, maxLines: 1, overflow: TextOverflow.ellipsis)),
                            Text(formatBytes(f.size), style: TextStyle(color: scheme.onSurfaceVariant)),
                          ],
                        ),
                      ),
                    if (files.length > 3)
                      Align(
                        alignment: Alignment.centerLeft,
                        child: Text('and ${files.length - 3} more', style: TextStyle(color: scheme.onSurfaceVariant)),
                      ),
                  ],
                  const SizedBox(height: 20),
                  AnimatedSize(
                    duration: const Duration(milliseconds: 300),
                    curve: Curves.easeOutCubic,
                    child: switch (_stage) {
                      _Stage.asking => Column(
                        children: [
                          AnimatedBuilder(
                            animation: _countdown,
                            builder: (_, _) => ClipRRect(
                              borderRadius: BorderRadius.circular(4),
                              child: LinearProgressIndicator(
                                value: _countdown.value,
                                minHeight: 4,
                                backgroundColor: scheme.surfaceContainerHighest,
                              ),
                            ),
                          ),
                          const SizedBox(height: 16),
                          Row(
                            children: [
                              Expanded(
                                child: OutlinedButton(
                                  onPressed: _decline,
                                  style: OutlinedButton.styleFrom(minimumSize: const Size(0, 52)),
                                  child: const Text('Decline'),
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: FilledButton.icon(
                                  onPressed: _accept,
                                  icon: const Icon(Icons.download_rounded),
                                  label: const Text('Accept'),
                                  style: FilledButton.styleFrom(minimumSize: const Size(0, 52)),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                      _Stage.receiving => Column(
                        children: [
                          TweenAnimationBuilder<double>(
                            tween: Tween(end: total > 0 ? (_received / total).clamp(0.0, 1.0) : 0),
                            duration: const Duration(milliseconds: 250),
                            builder: (_, value, _) => ClipRRect(
                              borderRadius: BorderRadius.circular(8),
                              child: LinearProgressIndicator(
                                value: total > 0 ? value : null,
                                minHeight: 10,
                                backgroundColor: scheme.surfaceContainerHighest,
                              ),
                            ),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            '${formatBytes(_received)} of ${formatBytes(total)}',
                            style: TextStyle(color: scheme.onSurfaceVariant),
                          ),
                          const SizedBox(height: 8),
                          TextButton(onPressed: _leave, child: const Text('Hide')),
                        ],
                      ),
                      _ => const SizedBox(height: 8, width: double.infinity),
                    },
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _graphic(ColorScheme scheme) {
    final done = _stage == _Stage.done;
    final gone = _stage == _Stage.gone;
    return Stack(
      alignment: Alignment.center,
      children: [
        if (_stage == _Stage.asking || _stage == _Stage.receiving)
          AnimatedBuilder(
            animation: _loop,
            builder: (_, _) => CustomPaint(
              size: const Size.square(150),
              painter: _Rings(progress: 1 - _loop.value, color: scheme.primary),
            ),
          ),
        AnimatedContainer(
          duration: const Duration(milliseconds: 400),
          curve: Curves.easeOutBack,
          width: done ? 104 : 88,
          height: done ? 104 : 88,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: done
                  ? [Colors.green.shade400, Colors.green.shade700]
                  : gone
                  ? [scheme.surfaceContainerHighest, scheme.surfaceContainerHighest]
                  : [scheme.primary, scheme.tertiary],
            ),
          ),
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 450),
            transitionBuilder: (child, a) => ScaleTransition(
              scale: CurvedAnimation(parent: a, curve: Curves.elasticOut),
              child: child,
            ),
            child: Icon(
              done
                  ? Icons.check_rounded
                  : gone
                  ? Icons.close_rounded
                  : platformIcon(offer.from.platform),
              key: ValueKey(_stage),
              size: done ? 60 : 44,
              // On the theme's gradient the icon takes the matching "on" color:
              // fixed white vanished on light gradients (dark mode, mono).
              color: gone
                  ? scheme.onSurfaceVariant
                  : done
                  ? Colors.white
                  : scheme.onPrimary,
            ),
          ),
        ),
        // Files dropping in toward this device.
        if (_stage == _Stage.asking || _stage == _Stage.receiving)
          AnimatedBuilder(
            animation: _loop,
            builder: (_, child) {
              final t = _loop.value;
              return Transform.translate(
                offset: Offset(52, -50 + 10 * math.sin(t * 2 * math.pi)),
                child: Transform.rotate(angle: 0.12 * math.sin(t * 2 * math.pi), child: child),
              );
            },
            child: _FileChip(count: offer.files.length),
          ),
      ],
    );
  }
}

import 'dart:async';
import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import '../core/server.dart';
import '../platform/sound.dart';
import 'widgets.dart';

/// The small window in the bottom-right corner when a request arrives while
/// Sidekick is in the tray: who, what, Accept / Decline, then the progress.
/// It closes ([onDone]) as soon as the files are in, or right away on
/// Decline, after a short exit animation.
class CornerPopup extends StatefulWidget {
  const CornerPopup({super.key, required this.offer, required this.onDone, this.sounds = false});
  final TransferOffer offer;
  final VoidCallback onDone;
  final bool sounds;

  /// How long the contents take to fade away before [onDone].
  static const exit = Duration(milliseconds: 220);

  @override
  State<CornerPopup> createState() => _CornerPopupState();
}

enum _Stage { asking, receiving, done, gone }

class _CornerPopupState extends State<CornerPopup> with TickerProviderStateMixin {
  TransferOffer get offer => widget.offer;
  _Stage _stage = _Stage.asking;
  int _received = 0;
  StreamSubscription<int>? _progress;
  bool _finished = false;
  bool _still = false;
  String _gone = '';

  /// Rings around the device and the glow on Accept, while asking.
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1800),
  );

  /// Time left to answer, running down along the top edge.
  late final AnimationController _countdown = AnimationController(vsync: this, duration: SidekickServer.offerTimeout);

  /// The contents fading away before the window goes.
  late final AnimationController _out = AnimationController(vsync: this, duration: CornerPopup.exit);

  @override
  void initState() {
    super.initState();
    _countdown.reverse(from: 1);
    _watch();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _still = MediaQuery.of(context).disableAnimations;
    if (_still) {
      _pulse.stop();
    } else if (_stage == _Stage.asking && !_pulse.isAnimating) {
      unawaited(_pulse.repeat());
    }
  }

  @override
  void didUpdateWidget(CornerPopup old) {
    super.didUpdateWidget(old);
    // The next request in line.
    if (old.offer != offer) {
      _progress?.cancel();
      _progress = null;
      _stage = _Stage.asking;
      _received = 0;
      _finished = false;
      _out.value = 0;
      _countdown.reverse(from: 1);
      if (!_still) unawaited(_pulse.repeat());
      _watch();
    }
  }

  @override
  void dispose() {
    _progress?.cancel();
    _pulse.dispose();
    _countdown.dispose();
    _out.dispose();
    super.dispose();
  }

  void _watch() {
    final mine = offer;
    unawaited(
      mine.answer.then((answer) {
        if (!mounted || mine != offer || _stage != _Stage.asking) return;
        switch (answer) {
          case OfferAnswer.accepted:
            _receive();
          case OfferAnswer.declined:
            _gone = 'Declined';
            _settle(_Stage.gone);
            _finish();
          case OfferAnswer.cancelled || OfferAnswer.timedOut:
            _gone = answer == OfferAnswer.timedOut ? 'No answer in time' : 'Stopped sending';
            _settle(_Stage.gone);
            _finish(after: const Duration(milliseconds: 1200));
        }
      }),
    );
  }

  void _settle(_Stage stage) {
    _pulse.stop();
    _countdown.stop();
    setState(() => _stage = stage);
  }

  /// Fades the contents out, then hands the window back.
  void _finish({Duration after = Duration.zero}) {
    if (_finished) return;
    _finished = true;
    final mine = offer;
    Future<void> go() async {
      if (!mounted || mine != offer) return;
      if (!_still) await _out.forward(from: 0).orCancel.catchError((_) {});
      if (mounted && mine == offer) widget.onDone();
    }

    after == Duration.zero ? unawaited(go()) : Timer(after, go);
  }

  void _accept() {
    offer.accept();
    if (widget.sounds) unawaited(playAcceptSound());
    _receive();
  }

  void _decline() {
    offer.decline();
    if (widget.sounds) unawaited(playDeclineSound());
    _gone = 'Declined';
    _settle(_Stage.gone);
    _finish();
  }

  void _receive() {
    if (_stage != _Stage.asking) return;
    _settle(_Stage.receiving);
    _progress = offer.progress.listen(
      (bytes) => setState(() => _received = bytes),
      onDone: () {
        if (!mounted) return;
        _settle(_Stage.done);
        _finish(after: const Duration(milliseconds: 1100));
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final files = offer.files;
    final total = offer.totalBytes;
    final fraction = total > 0 ? (_received / total).clamp(0.0, 1.0) : 0.0;
    final count = files.length == 1 ? 'a file' : '${files.length} files';
    final subtitle = switch (_stage) {
      _Stage.asking => 'wants to send you $count',
      _Stage.receiving => 'Receiving… ${(fraction * 100).round()}%',
      _Stage.done => files.length == 1 ? 'Received' : 'All ${files.length} files received',
      _Stage.gone => _gone,
    };
    return Material(
      color: scheme.surfaceContainerHigh,
      child: AnimatedBuilder(
        animation: _out,
        builder: (context, child) => Opacity(
          opacity: 1 - _out.value,
          child: Transform.translate(offset: Offset(0, 10 * _out.value), child: child),
        ),
        child: Stack(
          children: [
            // Time left to answer, warming up to red near the end.
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: AnimatedOpacity(
                opacity: _stage == _Stage.asking ? 1 : 0,
                duration: const Duration(milliseconds: 250),
                child: AnimatedBuilder(
                  animation: _countdown,
                  builder: (_, _) => LinearProgressIndicator(
                    value: _countdown.value,
                    minHeight: 3,
                    backgroundColor: Colors.transparent,
                    color: Color.lerp(scheme.error, scheme.primary, (_countdown.value / 0.25).clamp(0.0, 1.0)),
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 14),
              child: Column(
                key: ValueKey(offer),
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Entrance(
                    child: Row(
                      children: [
                        _Badge(stage: _stage, offer: offer, pulse: _pulse, fraction: fraction),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                offer.from.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: text.titleMedium?.copyWith(fontWeight: FontWeight.w700, height: 1.2),
                              ),
                              AnimatedSwitcher(
                                duration: const Duration(milliseconds: 200),
                                layoutBuilder: (current, previous) =>
                                    Stack(alignment: Alignment.centerLeft, children: [...previous, ?current]),
                                child: Text(
                                  subtitle,
                                  key: ValueKey(_stage),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: text.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 10),
                  Entrance(
                    index: 1,
                    child: _FileChip(files: files, total: total),
                  ),
                  const Spacer(),
                  Entrance(
                    index: 2,
                    child: SizedBox(
                      height: 40,
                      child: AnimatedSwitcher(
                        duration: const Duration(milliseconds: 280),
                        switchInCurve: Curves.easeOutCubic,
                        transitionBuilder: (child, animation) => FadeTransition(
                          opacity: animation,
                          child: SlideTransition(
                            position: Tween(begin: const Offset(0, 0.25), end: Offset.zero).animate(animation),
                            child: child,
                          ),
                        ),
                        child: switch (_stage) {
                          _Stage.asking => _Answer(pulse: _pulse, onAccept: _accept, onDecline: _decline),
                          _Stage.receiving || _Stage.done => _Progress(
                            key: const ValueKey('progress'),
                            fraction: _stage == _Stage.done ? 1 : fraction,
                            received: _stage == _Stage.done ? total : _received,
                            total: total,
                          ),
                          _Stage.gone => const SizedBox.shrink(),
                        },
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The sending device: rings ripple out while it asks, a ring fills while
/// files come in, and a check pops in at the end.
class _Badge extends StatelessWidget {
  const _Badge({required this.stage, required this.offer, required this.pulse, required this.fraction});
  final _Stage stage;
  final TransferOffer offer;
  final Animation<double> pulse;
  final double fraction;

  static const _size = 46.0;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox.square(
      dimension: _size + 8,
      child: Stack(
        alignment: Alignment.center,
        clipBehavior: Clip.none,
        children: [
          if (stage == _Stage.asking)
            AnimatedBuilder(
              animation: pulse,
              builder: (_, _) =>
                  CustomPaint(size: const Size.square(_size), painter: _Rings(pulse.value, scheme.primary)),
            ),
          if (stage == _Stage.receiving)
            SizedBox.square(
              dimension: _size + 8,
              child: CircularProgressIndicator(
                value: fraction > 0 ? fraction : null,
                strokeWidth: 3,
                strokeCap: StrokeCap.round,
                backgroundColor: scheme.surfaceContainerHighest,
              ),
            ),
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 500),
            switchInCurve: Curves.elasticOut,
            switchOutCurve: Curves.easeIn,
            transitionBuilder: (child, animation) => ScaleTransition(scale: animation, child: child),
            child: switch (stage) {
              _Stage.done => _Circle(key: const ValueKey('done'), icon: Icons.check_rounded, color: scheme.primary),
              _Stage.gone => _Circle(
                key: const ValueKey('gone'),
                icon: Icons.close_rounded,
                color: scheme.surfaceContainerHighest,
                iconColor: scheme.onSurfaceVariant,
              ),
              _ => AnimatedBuilder(
                key: const ValueKey('device'),
                animation: pulse,
                // A gentle breath while it waits for an answer.
                builder: (_, child) => Transform.scale(
                  scale: stage == _Stage.asking ? 1 + 0.04 * math.sin(pulse.value * 2 * math.pi) : 0.86,
                  child: child,
                ),
                child: GradientBadge(icon: platformIcon(offer.from.platform), size: _size),
              ),
            },
          ),
        ],
      ),
    );
  }
}

class _Circle extends StatelessWidget {
  const _Circle({super.key, required this.icon, required this.color, this.iconColor});
  final IconData icon;
  final Color color;
  final Color? iconColor;

  @override
  Widget build(BuildContext context) => Container(
    width: _Badge._size,
    height: _Badge._size,
    decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    child: Icon(icon, size: 26, color: iconColor ?? Theme.of(context).colorScheme.onPrimary),
  );
}

/// Two rings spreading out from the badge, one after the other.
class _Rings extends CustomPainter {
  _Rings(this.t, this.color);
  final double t;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    for (final shift in [0.0, 0.5]) {
      final p = (t + shift) % 1;
      final paint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = color.withValues(alpha: 0.45 * (1 - p));
      final side = size.width * (0.95 + 0.6 * Curves.easeOut.transform(p));
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromCenter(center: center, width: side, height: side),
          Radius.circular(side * 0.34),
        ),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_Rings old) => old.t != t || old.color != color;
}

/// What's coming: the file (or the first one and how many more) and size.
class _FileChip extends StatelessWidget {
  const _FileChip({required this.files, required this.total});
  final List<OfferedFile> files;
  final int total;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final first = files.isEmpty ? '' : files.first.name;
    return Container(
      height: 34,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(color: scheme.surfaceContainerHighest, borderRadius: BorderRadius.circular(12)),
      child: Row(
        children: [
          Icon(_iconFor(first), size: 18, color: scheme.primary),
          const SizedBox(width: 8),
          Expanded(
            child: Text.rich(
              TextSpan(
                children: [
                  TextSpan(text: first),
                  if (files.length > 1)
                    TextSpan(
                      text: '  +${files.length - 1} more',
                      style: TextStyle(color: scheme.onSurfaceVariant),
                    ),
                ],
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: text.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
            ),
          ),
          if (total > 0) ...[
            const SizedBox(width: 8),
            Text(formatBytes(total), style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
          ],
        ],
      ),
    );
  }

  static IconData _iconFor(String name) {
    final dot = name.lastIndexOf('.');
    final ext = dot < 0 ? '' : name.substring(dot + 1).toLowerCase();
    return switch (ext) {
      'jpg' || 'jpeg' || 'png' || 'heic' || 'heif' || 'gif' || 'webp' => Icons.image_outlined,
      'mov' || 'mp4' || 'm4v' || 'avi' || 'mkv' => Icons.movie_outlined,
      'mp3' || 'm4a' || 'wav' || 'aac' || 'flac' => Icons.music_note_outlined,
      'pdf' => Icons.picture_as_pdf_outlined,
      'zip' || 'rar' || '7z' => Icons.folder_zip_outlined,
      _ => Icons.insert_drive_file_outlined,
    };
  }
}

class _Answer extends StatelessWidget {
  const _Answer({required this.pulse, required this.onAccept, required this.onDecline});
  final Animation<double> pulse;
  final VoidCallback onAccept;
  final VoidCallback onDecline;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    const shape = Size(0, 40);
    return Row(
      children: [
        Expanded(
          child: OutlinedButton(
            onPressed: onDecline,
            style: OutlinedButton.styleFrom(minimumSize: shape, padding: EdgeInsets.zero),
            child: const Text('Decline'),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          // A soft glow that breathes, inviting a click.
          child: AnimatedBuilder(
            animation: pulse,
            builder: (_, button) => DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(20),
                boxShadow: [
                  BoxShadow(
                    color: scheme.primary.withValues(alpha: 0.12 + 0.16 * math.sin(pulse.value * math.pi)),
                    blurRadius: 14,
                  ),
                ],
              ),
              child: button,
            ),
            child: FilledButton.icon(
              onPressed: onAccept,
              style: FilledButton.styleFrom(minimumSize: shape, padding: EdgeInsets.zero),
              icon: const Icon(Icons.download_rounded, size: 18),
              label: const Text('Accept'),
            ),
          ),
        ),
      ],
    );
  }
}

class _Progress extends StatelessWidget {
  const _Progress({super.key, required this.fraction, required this.received, required this.total});
  final double fraction;
  final int received;
  final int total;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TweenAnimationBuilder<double>(
          tween: Tween(end: fraction),
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOutCubic,
          builder: (_, value, _) => ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: total > 0 ? value : null,
              minHeight: 6,
              backgroundColor: scheme.surfaceContainerHighest,
            ),
          ),
        ),
        const SizedBox(height: 6),
        Text(
          total > 0 ? '${formatBytes(received)} of ${formatBytes(total)}' : formatBytes(received),
          style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
        ),
      ],
    );
  }
}

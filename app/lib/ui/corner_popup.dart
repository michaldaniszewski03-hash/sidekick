import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../core/server.dart';
import '../platform/sound.dart';
import 'widgets.dart';

/// The small window in the bottom-right corner when a request arrives while
/// Sidekick is in the tray: who, what, Accept / Decline, then a progress
/// bar. It closes ([onDone]) as soon as the files are in, or right away on
/// Decline.
class CornerPopup extends StatefulWidget {
  const CornerPopup({super.key, required this.offer, required this.onDone, this.sounds = false});
  final TransferOffer offer;
  final VoidCallback onDone;
  final bool sounds;

  @override
  State<CornerPopup> createState() => _CornerPopupState();
}

enum _Stage { asking, receiving, done, gone }

class _CornerPopupState extends State<CornerPopup> {
  TransferOffer get offer => widget.offer;
  _Stage _stage = _Stage.asking;
  int _received = 0;
  StreamSubscription<int>? _progress;
  bool _finished = false;

  @override
  void initState() {
    super.initState();
    _watch();
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
      _watch();
    }
  }

  @override
  void dispose() {
    _progress?.cancel();
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
            _finish();
          case OfferAnswer.cancelled || OfferAnswer.timedOut:
            setState(() => _stage = _Stage.gone);
            _finish(after: const Duration(milliseconds: 1200));
        }
      }),
    );
  }

  void _finish({Duration after = Duration.zero}) {
    if (_finished) return;
    _finished = true;
    if (after == Duration.zero) return widget.onDone();
    final mine = offer;
    Timer(after, () {
      if (mounted && mine == offer) widget.onDone();
    });
  }

  void _accept() {
    offer.accept();
    if (widget.sounds) unawaited(playAcceptSound());
    _receive();
  }

  void _decline() {
    offer.decline();
    if (widget.sounds) unawaited(playDeclineSound());
    _finish();
  }

  void _receive() {
    if (_stage != _Stage.asking) return;
    setState(() => _stage = _Stage.receiving);
    _progress = offer.progress.listen(
      (bytes) => setState(() => _received = bytes),
      onDone: () {
        if (!mounted) return;
        setState(() => _stage = _Stage.done);
        _finish(after: const Duration(milliseconds: 900));
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final files = offer.files;
    final what = files.length == 1 ? files.first.name : '${files.length} files';
    final total = offer.totalBytes;
    final subtitle = switch (_stage) {
      _Stage.asking => total > 0 ? '$what · ${formatBytes(total)}' : what,
      _Stage.receiving => '${formatBytes(_received)} of ${formatBytes(total)}',
      _Stage.done => 'Received $what',
      _Stage.gone => 'Stopped sending',
    };
    return Material(
      color: scheme.surfaceContainerHigh,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                _stage == _Stage.done
                    ? CircleAvatar(
                        radius: 20,
                        backgroundColor: scheme.primary,
                        child: Icon(Icons.check_rounded, color: scheme.onPrimary),
                      )
                    : GradientBadge(icon: platformIcon(offer.from.platform), size: 40),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _stage == _Stage.asking ? '${offer.from.name} wants to send' : offer.from.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: text.titleSmall?.copyWith(fontWeight: FontWeight.w700),
                      ),
                      Text(
                        subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const Spacer(),
            if (_stage == _Stage.asking)
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(onPressed: _decline, child: const Text('Decline')),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: _accept,
                      icon: const Icon(Icons.download_rounded, size: 18),
                      label: const Text('Accept'),
                    ),
                  ),
                ],
              )
            else
              Padding(
                padding: const EdgeInsets.only(bottom: 14),
                child: LinearProgressIndicator(
                  value: _stage == _Stage.receiving ? (total > 0 ? _received / total : null) : 1,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

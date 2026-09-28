import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../app_state.dart';
import '../core/models.dart';
import 'widgets.dart';

class MediaPage extends StatelessWidget {
  const MediaPage({super.key, required this.state, this.onGoToDevices});
  final AppState state;
  final VoidCallback? onGoToDevices;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: state,
    builder: (context, _) => DeviceGate(
      state: state,
      feature: 'the media controller',
      icon: Icons.play_circle_outline,
      onGoToDevices: onGoToDevices,
      builder: (context, device) => _Media(key: ValueKey(device.id), state: state, device: device),
    ),
  );
}

class _Media extends StatefulWidget {
  const _Media({super.key, required this.state, required this.device});
  final AppState state;
  final PairedDevice device;

  @override
  State<_Media> createState() => _MediaState();
}

class _MediaState extends State<_Media> {
  MediaStatus? _status;
  DateTime _fetchedAt = DateTime.now();
  String? _error;
  Timer? _poll;
  Timer? _tick;
  double? _seekDrag;
  double? _volumeDrag;
  DateTime _lastVolumeSend = DateTime.fromMillisecondsSinceEpoch(0);

  @override
  void initState() {
    super.initState();
    _refresh();
    _poll = Timer.periodic(const Duration(seconds: 1), (_) => _refresh());
    // Repaint between polls so the progress bar moves smoothly.
    _tick = Timer.periodic(const Duration(milliseconds: 250), (_) {
      if (_status?.isPlaying == true && mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _poll?.cancel();
    _tick?.cancel();
    super.dispose();
  }

  bool _fetching = false;

  Future<void> _refresh() async {
    if (_fetching) return;
    _fetching = true;
    try {
      final status = await widget.state.clientFor(widget.device).mediaStatus();
      if (!mounted) return;
      setState(() {
        _status = status;
        _fetchedAt = DateTime.now();
        _error = null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      _fetching = false;
    }
  }

  Future<void> _do(MediaAction action, {Duration? position, double? volume}) async {
    try {
      await widget.state.clientFor(widget.device).media(action, position: position, volume: volume);
      await _refresh();
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  /// Position now, extrapolated from the last poll while playing.
  Duration get _position {
    final s = _status;
    if (s == null) return Duration.zero;
    var pos = s.position;
    if (s.isPlaying) pos += DateTime.now().difference(_fetchedAt);
    if (s.duration > Duration.zero && pos > s.duration) pos = s.duration;
    return pos;
  }

  void _skip(int seconds) {
    final s = _status;
    if (s == null || !s.canSeek) return;
    var target = _position + Duration(seconds: seconds);
    if (target < Duration.zero) target = Duration.zero;
    if (target > s.duration) target = s.duration;
    _do(MediaAction.seek, position: target);
  }

  @override
  Widget build(BuildContext context) {
    final s = _status;
    return PageFrame(
      title: 'Media',
      actions: [DevicePicker(state: widget.state)],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          OfflineBanner(state: widget.state, device: widget.device),
          if (s == null && _error == null)
            const Padding(
              padding: EdgeInsets.all(48),
              child: Center(child: CircularProgressIndicator()),
            )
          else if (s == null)
            EmptyState(
              icon: Icons.error_outline,
              title: "Couldn't reach ${widget.device.name}",
              message: _error!,
              action: FilledButton.tonal(onPressed: _refresh, child: const Text('Try again')),
            )
          else
            Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 560),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _NowPlaying(status: s),
                    const SizedBox(height: 24),
                    _seekBar(s),
                    const SizedBox(height: 16),
                    _controls(s),
                    const SizedBox(height: 28),
                    _volume(s),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _seekBar(MediaStatus s) {
    final durationMs = s.duration.inMilliseconds.toDouble();
    final canSeek = s.canSeek && durationMs > 0;
    final value = (_seekDrag ?? _position.inMilliseconds.toDouble()).clamp(0.0, durationMs > 0 ? durationMs : 1.0);
    final muted = TextStyle(
      color: Theme.of(context).colorScheme.onSurfaceVariant,
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    return Column(
      children: [
        Slider(
          value: value,
          max: durationMs > 0 ? durationMs : 1,
          onChanged: canSeek ? (v) => setState(() => _seekDrag = v) : null,
          onChangeEnd: canSeek
              ? (v) {
                  setState(() => _seekDrag = null);
                  _do(MediaAction.seek, position: Duration(milliseconds: v.round()));
                }
              : null,
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(formatDuration(Duration(milliseconds: value.round())), style: muted),
              Text(durationMs > 0 ? formatDuration(s.duration) : '--:--', style: muted),
            ],
          ),
        ),
      ],
    );
  }

  Widget _controls(MediaStatus s) {
    final scheme = Theme.of(context).colorScheme;
    final playing = s.isPlaying;
    // Scales down on narrow phones instead of overflowing.
    return FittedBox(
      fit: BoxFit.scaleDown,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          IconButton(
            iconSize: 32,
            tooltip: 'Previous',
            onPressed: () => _do(MediaAction.previous),
            icon: const Icon(Icons.skip_previous_rounded),
          ),
          const SizedBox(width: 8),
          IconButton(
            iconSize: 28,
            tooltip: 'Back 10 seconds',
            onPressed: s.canSeek ? () => _skip(-10) : null,
            icon: const Icon(Icons.replay_10_rounded),
          ),
          const SizedBox(width: 16),
          // Material 3 expressive: the button morphs between a rounded square
          // (paused) and a wider pill (playing).
          AnimatedContainer(
            duration: const Duration(milliseconds: 350),
            curve: Curves.easeOutBack,
            width: playing ? 104 : 88,
            height: 72,
            decoration: BoxDecoration(color: scheme.primary, borderRadius: BorderRadius.circular(playing ? 36 : 22)),
            child: Material(
              type: MaterialType.transparency,
              child: InkWell(
                borderRadius: BorderRadius.circular(playing ? 36 : 22),
                onTap: () => _do(MediaAction.playPause),
                child: Icon(
                  playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                  size: 40,
                  color: scheme.onPrimary,
                ),
              ),
            ),
          ),
          const SizedBox(width: 16),
          IconButton(
            iconSize: 28,
            tooltip: 'Forward 10 seconds',
            onPressed: s.canSeek ? () => _skip(10) : null,
            icon: const Icon(Icons.forward_10_rounded),
          ),
          const SizedBox(width: 8),
          IconButton(
            iconSize: 32,
            tooltip: 'Next',
            onPressed: () => _do(MediaAction.next),
            icon: const Icon(Icons.skip_next_rounded),
          ),
        ],
      ),
    );
  }

  Widget _volume(MediaStatus s) {
    final volume = _volumeDrag ?? s.volume;
    return Card.filled(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          children: [
            IconButton(
              tooltip: s.muted ? 'Unmute' : 'Mute',
              onPressed: () => _do(MediaAction.toggleMute),
              icon: Icon(s.muted ? Icons.volume_off_rounded : Icons.volume_up_rounded),
            ),
            Expanded(
              child: volume == null
                  // Volume level unknown: fall back to step buttons.
                  ? Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        FilledButton.tonalIcon(
                          onPressed: () => _do(MediaAction.volumeDown),
                          icon: const Icon(Icons.remove),
                          label: const Text('Quieter'),
                        ),
                        const SizedBox(width: 12),
                        FilledButton.tonalIcon(
                          onPressed: () => _do(MediaAction.volumeUp),
                          icon: const Icon(Icons.add),
                          label: const Text('Louder'),
                        ),
                      ],
                    )
                  : Slider(
                      value: volume.clamp(0.0, 1.0),
                      onChanged: (v) {
                        setState(() => _volumeDrag = v);
                        // Update live while dragging, a few times a second.
                        if (DateTime.now().difference(_lastVolumeSend) > const Duration(milliseconds: 150)) {
                          _lastVolumeSend = DateTime.now();
                          widget.state
                              .clientFor(widget.device)
                              .media(MediaAction.setVolume, volume: v)
                              .catchError((_) {});
                        }
                      },
                      onChangeEnd: (v) async {
                        await _do(MediaAction.setVolume, volume: v);
                        if (mounted) setState(() => _volumeDrag = null);
                      },
                    ),
            ),
            SizedBox(
              width: 48,
              child: Text(volume == null ? '' : '${(volume * 100).round()}%', textAlign: TextAlign.end),
            ),
          ],
        ),
      ),
    );
  }
}

class _NowPlaying extends StatelessWidget {
  const _NowPlaying({required this.status});
  final MediaStatus status;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final nothing = !status.available;
    return Row(
      children: [
        Container(
          width: 112,
          height: 112,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(28),
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [scheme.primary, scheme.tertiary],
            ),
          ),
          child: Icon(nothing ? Icons.music_off_rounded : Icons.music_note_rounded, size: 48, color: scheme.onPrimary),
        ),
        const SizedBox(width: 24),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                nothing ? 'Nothing playing' : (status.title.isEmpty ? 'Unknown title' : status.title),
                style: text.headlineSmall?.copyWith(fontWeight: FontWeight.w600),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 6),
              Text(
                nothing
                    ? 'Start something in Spotify, YouTube, VLC or any other player.'
                    : [status.artist, status.app].where((x) => x.isNotEmpty).join(' · '),
                style: text.bodyLarge?.copyWith(color: scheme.onSurfaceVariant),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

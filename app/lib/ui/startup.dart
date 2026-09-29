import 'package:material_ui/material_ui.dart';

/// The startup animation, played once when Sidekick opens.
///
/// The "sk" tile pops in, two ripples spread from it, the name rises into
/// place, then the whole thing zooms away and the app settles in behind it.
/// A tap skips it; with reduced motion it doesn't play at all.
class StartupSplash extends StatefulWidget {
  const StartupSplash({super.key, required this.child, this.onStart});

  final Widget child;

  /// Called when the animation starts (the Mac plays its chime here).
  final VoidCallback? onStart;

  @override
  State<StartupSplash> createState() => _StartupSplashState();
}

class _StartupSplashState extends State<StartupSplash> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 1700));
  bool _done = false;
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    if (MediaQuery.of(context).disableAnimations) {
      _done = true;
      return;
    }
    widget.onStart?.call();
    _c.forward().whenComplete(() {
      if (mounted) setState(() => _done = true);
    });
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  /// A tap jumps to the zoom-away part.
  void _skip() {
    if (_c.value < 0.72) _c.animateTo(0.72, duration: const Duration(milliseconds: 120));
  }

  @override
  Widget build(BuildContext context) {
    if (_done) return widget.child;
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;

    Animation<double> part(double from, double to, [Curve curve = Curves.easeOutCubic]) => CurvedAnimation(
      parent: _c,
      curve: Interval(from, to, curve: curve),
    );
    final pop = part(0.0, 0.42, Curves.elasticOut);
    final ripple = part(0.18, 0.85, Curves.easeOut);
    final title = part(0.28, 0.55);
    final leave = part(0.72, 1.0, Curves.easeInCubic);
    final reveal = part(0.72, 1.0);

    return Stack(
      fit: StackFit.expand,
      children: [
        // The app underneath grows into place as the splash leaves.
        AnimatedBuilder(
          animation: reveal,
          builder: (context, child) => Transform.scale(scale: 0.94 + 0.06 * reveal.value, child: child),
          child: widget.child,
        ),
        GestureDetector(
          onTap: _skip,
          child: AnimatedBuilder(
            animation: _c,
            builder: (context, _) => Opacity(
              opacity: 1 - leave.value,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: RadialGradient(
                    radius: 1.1,
                    colors: [Color.lerp(scheme.surface, scheme.primaryContainer, 0.55)!, scheme.surface],
                  ),
                ),
                child: Center(
                  child: Transform.scale(
                    scale: 1 + 0.35 * leave.value,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        SizedBox.square(
                          dimension: 260,
                          child: Stack(
                            alignment: Alignment.center,
                            children: [
                              for (final delay in [0.0, 0.22])
                                _Ripple(
                                  t: ((ripple.value - delay) / (1 - delay)).clamp(0.0, 1.0),
                                  color: scheme.primary,
                                ),
                              Transform.scale(scale: pop.value, child: _LogoTile(size: 112)),
                            ],
                          ),
                        ),
                        Opacity(
                          opacity: title.value,
                          child: Transform.translate(
                            offset: Offset(0, 14 * (1 - title.value)),
                            child: Column(
                              children: [
                                Text('Sidekick', style: text.headlineMedium?.copyWith(color: scheme.onSurface)),
                                const SizedBox(height: 4),
                                Text(
                                  'Your devices, together',
                                  style: text.bodyLarge?.copyWith(color: scheme.onSurfaceVariant),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// A ring that grows from the logo and fades as it goes.
class _Ripple extends StatelessWidget {
  const _Ripple({required this.t, required this.color});
  final double t;
  final Color color;

  @override
  Widget build(BuildContext context) {
    if (t <= 0 || t >= 1) return const SizedBox.shrink();
    final size = 112 + 148 * t;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(
          color: color.withValues(alpha: 0.45 * (1 - t)),
          width: 2 + 4 * (1 - t),
        ),
      ),
    );
  }
}

/// The "sk" monogram in white on the primary → tertiary gradient tile.
class _LogoTile extends StatelessWidget {
  const _LogoTile({required this.size});
  final double size;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: size,
      height: size,
      padding: EdgeInsets.all(size * 0.24),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [scheme.primary, scheme.tertiary],
        ),
        borderRadius: BorderRadius.circular(size * 0.3),
        boxShadow: [
          BoxShadow(
            color: scheme.primary.withValues(alpha: 0.35),
            blurRadius: size * 0.35,
            offset: Offset(0, size * 0.1),
          ),
        ],
      ),
      child: Image.asset('assets/logo/logo.png', color: scheme.onPrimary, semanticLabel: 'Sidekick'),
    );
  }
}

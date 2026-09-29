import 'package:material_ui/material_ui.dart';

import '../app_state.dart';
import 'widgets.dart';

/// Light/dark mode, color theme and pure black: used in Settings → Theme and
/// on the welcome screen.
class ThemeChooser extends StatelessWidget {
  const ThemeChooser({super.key, required this.state});
  final AppState state;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
        child: SegmentedButton<ThemeMode>(
          segments: const [
            ButtonSegment(value: ThemeMode.system, icon: Icon(Icons.brightness_auto_outlined), label: Text('System')),
            ButtonSegment(value: ThemeMode.light, icon: Icon(Icons.light_mode_outlined), label: Text('Light')),
            ButtonSegment(value: ThemeMode.dark, icon: Icon(Icons.dark_mode_outlined), label: Text('Dark')),
          ],
          selected: {state.themeMode},
          onSelectionChanged: (s) => state.setThemeMode(s.first),
        ),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
        child: Align(
          alignment: Alignment.centerLeft,
          child: Text('Color', style: Theme.of(context).textTheme.titleSmall),
        ),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
        child: Wrap(
          spacing: 4,
          runSpacing: 4,
          children: [
            if (!hostIsIOS)
              _ColorChoice(
                label: switch (hostOS) {
                  'android' => 'Wallpaper',
                  _ => 'System accent',
                },
                selected: state.themeColor == 'system',
                onTap: () => state.setThemeColor('system'),
              ),
            for (final MapEntry(:key, value: (label, color)) in themeColors.entries)
              _ColorChoice(
                label: label,
                color: color,
                mono: key == 'mono',
                // iOS has no system colors; its default is purple.
                selected: state.themeColor == key || (hostIsIOS && state.themeColor == 'system' && key == 'purple'),
                onTap: () => state.setThemeColor(key),
              ),
          ],
        ),
      ),
      if (state.themeColor == 'system' && !hostIsIOS)
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Text(switch (hostOS) {
            'android' => 'Follows your wallpaper colors (Android 12 and newer).',
            'macos' => "Follows your Mac's accent color (System Settings → Appearance).",
            _ => 'Follows your Windows accent color (Settings → Personalization → Colors).',
          }, style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 13)),
        ),
      SwitchListTile(
        secondary: const IconTile(Icons.contrast_rounded),
        title: const Text('Pure black in dark mode'),
        subtitle: const Text('Darker backgrounds; saves battery on OLED screens'),
        value: state.pureBlack,
        onChanged: state.setPureBlack,
      ),
    ],
  );
}

/// A round color swatch with its name, for Settings → Theme.
class _ColorChoice extends StatelessWidget {
  const _ColorChoice({required this.label, required this.selected, required this.onTap, this.color, this.mono = false});

  final String label;

  /// Null for "follow the system".
  final Color? color;
  final bool selected;
  final VoidCallback onTap;
  final bool mono;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final swatch = color == null
        ? null
        : ColorScheme.fromSeed(
            seedColor: color!,
            brightness: Theme.of(context).brightness,
            dynamicSchemeVariant: mono ? DynamicSchemeVariant.monochrome : DynamicSchemeVariant.tonalSpot,
          );
    return Tooltip(
      message: label,
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: SizedBox(
          width: 76,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Column(
              children: [
                AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: swatch == null
                        ? SweepGradient(colors: [scheme.primary, scheme.tertiary, scheme.secondary, scheme.primary])
                        : LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: [swatch.primary, swatch.primary, swatch.primaryContainer, swatch.primaryContainer],
                            stops: const [0, 0.62, 0.62, 1],
                          ),
                    border: Border.all(color: selected ? scheme.onSurface : Colors.transparent, width: 3),
                  ),
                  child: selected ? Icon(Icons.check, color: swatch?.onPrimary ?? scheme.onPrimary) : null,
                ),
                const SizedBox(height: 6),
                Text(label, textAlign: TextAlign.center, maxLines: 2, style: const TextStyle(fontSize: 12)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

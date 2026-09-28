import 'package:dynamic_color/dynamic_color.dart';
import 'package:material_ui/material_ui.dart';

import 'app_state.dart';
import 'ui/shell.dart';

/// Used when the OS doesn't give us an accent color. Matches the website.
const _fallbackSeed = Color(0xFF6750A4);

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final state = await AppState.load();
  await state.start();
  runApp(SidekickApp(state: state));
}

class SidekickApp extends StatelessWidget {
  const SidekickApp({super.key, required this.state});

  final AppState state;

  static ThemeData _theme(ColorScheme scheme) => ThemeData(
    colorScheme: scheme,
    useMaterial3: true,
    visualDensity: VisualDensity.standard,
    cardTheme: const CardThemeData(elevation: 0, margin: EdgeInsets.zero),
    snackBarTheme: const SnackBarThemeData(behavior: SnackBarBehavior.floating),
  );

  static ColorScheme _scheme(ColorScheme? dynamic, Brightness brightness) {
    if (dynamic != null) return dynamic;
    return ColorScheme.fromSeed(seedColor: _fallbackSeed, brightness: brightness);
  }

  @override
  Widget build(BuildContext context) {
    // On Windows, DynamicColorBuilder builds the palette from the user's
    // accent color (Settings → Personalization → Colors).
    return DynamicColorBuilder(
      builder: (lightDynamic, darkDynamic) => ListenableBuilder(
        listenable: state,
        builder: (context, _) => MaterialApp(
          title: 'Sidekick',
          debugShowCheckedModeBanner: false,
          themeMode: state.themeMode,
          theme: _theme(_scheme(lightDynamic, Brightness.light)),
          darkTheme: _theme(_scheme(darkDynamic, Brightness.dark)),
          home: Shell(state: state),
        ),
      ),
    );
  }
}

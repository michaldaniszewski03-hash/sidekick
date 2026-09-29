import 'package:dynamic_color/dynamic_color.dart';
import 'package:material_ui/material_ui.dart';

import 'app_state.dart';
import 'ui/shell.dart';
import 'ui/welcome.dart';

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

  ColorScheme _scheme(ColorScheme? dynamic, Brightness brightness) {
    final choice = state.themeColor;
    ColorScheme scheme;
    if (choice == 'system' && dynamic != null) {
      scheme = dynamic;
    } else {
      // No OS colors (iOS, older Android): Sidekick purple, like the website.
      final (_, seed) = themeColors[choice] ?? themeColors['purple']!;
      scheme = ColorScheme.fromSeed(
        seedColor: seed,
        brightness: brightness,
        dynamicSchemeVariant: choice == 'mono' ? DynamicSchemeVariant.monochrome : DynamicSchemeVariant.tonalSpot,
      );
    }
    if (brightness == Brightness.dark && state.pureBlack) {
      scheme = scheme.copyWith(
        surface: Colors.black,
        surfaceContainerLowest: Colors.black,
        surfaceContainerLow: const Color(0xFF0B0B0B),
        surfaceContainer: const Color(0xFF121212),
        surfaceContainerHigh: const Color(0xFF1A1A1A),
        surfaceContainerHighest: const Color(0xFF232323),
      );
    }
    return scheme;
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
          home: AnimatedSwitcher(
            duration: const Duration(milliseconds: 400),
            child: state.welcomed ? Shell(state: state) : WelcomeFlow(state: state),
          ),
        ),
      ),
    );
  }
}

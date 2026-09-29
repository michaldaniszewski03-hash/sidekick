import 'package:material_ui/material_ui.dart';

import '../platform/android.dart';
import '../platform/macos.dart';

/// The Android permissions Sidekick asks for, one row each with a button
/// to the system screen that grants it (Settings and the welcome screen).
List<Widget> androidPermissionRows() {
  final perms = AndroidBridge.permissions;
  Widget row({
    required IconData icon,
    required String title,
    required String why,
    required bool granted,
    required Future<void> Function() grant,
  }) => ListTile(
    leading: Icon(icon),
    title: Text(title),
    subtitle: Text(why),
    isThreeLine: true,
    trailing: granted
        ? const Icon(Icons.check_circle, color: Colors.green)
        : FilledButton.tonal(onPressed: grant, child: const Text('Grant')),
  );
  return [
    row(
      icon: Icons.folder_open_outlined,
      title: 'All files access',
      why: 'So your PC can browse this phone and received files go to Download/Sidekick.',
      granted: perms.allFiles,
      grant: AndroidBridge.requestAllFilesAccess,
    ),
    row(
      icon: Icons.play_circle_outline,
      title: 'Notification access',
      why: "So your PC can see what's playing and seek. Sidekick doesn't read your notifications.",
      granted: perms.notifications,
      grant: AndroidBridge.openNotificationAccessSettings,
    ),
    row(
      icon: Icons.touch_app_outlined,
      title: 'Remote control (Accessibility)',
      why:
          'So your PC can tap, scroll and type here. In Accessibility, open "Installed apps" → Sidekick remote '
          'control. If it\'s greyed out: App info → ⋮ → Allow restricted settings.',
      granted: perms.accessibility,
      grant: AndroidBridge.openAccessibilitySettings,
    ),
    if (!perms.accessibility)
      ListTile(
        leading: const SizedBox(),
        title: const Text('Open App info'),
        subtitle: const Text('For "Allow restricted settings" on Android 13 and newer'),
        onTap: AndroidBridge.openAppSettings,
      ),
  ];
}

/// The Mac's Accessibility permission, needed for remote control.
class MacAccessibilityRow extends StatelessWidget {
  const MacAccessibilityRow({super.key});

  @override
  Widget build(BuildContext context) => ListTile(
    leading: const Icon(Icons.mouse_outlined),
    title: const Text('Accessibility'),
    subtitle: const Text(
      'So your other devices can move the mouse, click and type on this Mac. If Sidekick is '
      'already switched on in that list but this still asks for it (common after an update), '
      'select Sidekick, remove it with −, then add it again.',
    ),
    isThreeLine: true,
    trailing: MacBridge.accessibility
        ? const Icon(Icons.check_circle, color: Colors.green)
        : FilledButton.tonal(onPressed: MacBridge.requestAccessibility, child: const Text('Grant')),
  );
}

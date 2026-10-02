import 'dart:async';
import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:screen_retriever/screen_retriever.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import '../core/server.dart';

/// Windows and Mac: closing the window keeps Sidekick running in the tray
/// (the menu bar on a Mac), still able to receive. A request that arrives
/// then opens a small window in the bottom-right corner ([popup]) with
/// Accept and Decline, which closes by itself once the files are in.
class DesktopWindow with WindowListener, TrayListener {
  DesktopWindow._();
  static final instance = DesktopWindow._();

  static bool get supported => Platform.isWindows || Platform.isMacOS;

  /// The size of the corner window.
  static const popupSize = Size(360, 150);

  /// The request in the corner window. While it's set, the app draws only
  /// the small card (see main.dart).
  final popup = ValueNotifier<TransferOffer?>(null);
  final _queue = <TransferOffer>[];

  /// The window is closed to the tray: nothing to draw, so the app pauses
  /// its animations (see main.dart).
  final hidden = ValueNotifier(false);
  bool get _hidden => hidden.value;
  set _hidden(bool value) => hidden.value = value;

  /// Where the full window was, to put it back after the corner window.
  Rect? _bounds;

  /// "Open Sidekick" was picked while the corner window was up.
  bool _openAfter = false;

  Future<void> init() async {
    await windowManager.ensureInitialized();
    await windowManager.setPreventClose(true);
    windowManager.addListener(this);
    try {
      await trayManager.setIcon(
        Platform.isWindows ? 'assets/tray/tray.ico' : 'assets/tray/tray_mac.png',
        isTemplate: Platform.isMacOS,
      );
      await trayManager.setToolTip('Sidekick');
      await trayManager.setContextMenu(
        Menu(
          items: [
            MenuItem(key: 'open', label: 'Open Sidekick'),
            MenuItem.separator(),
            MenuItem(key: 'quit', label: 'Quit Sidekick'),
          ],
        ),
      );
      trayManager.addListener(this);
    } catch (e) {
      // No tray: closing the window quits, as before.
      debugPrint('Sidekick: no tray icon: $e');
      await windowManager.setPreventClose(false);
    }
  }

  /// Shows [offer] in the corner window if Sidekick is in the tray. False
  /// when its window is open: the app shows its own card then.
  bool show(TransferOffer offer) {
    if (!_hidden) return false;
    if (popup.value == null) {
      unawaited(_openPopup(offer));
    } else {
      _queue.add(offer);
    }
    return true;
  }

  Future<void> _openPopup(TransferOffer offer) async {
    popup.value = offer;
    _bounds ??= await windowManager.getBounds();
    await windowManager.setTitleBarStyle(TitleBarStyle.hidden, windowButtonVisibility: false);
    await windowManager.setResizable(false);
    await windowManager.setAlwaysOnTop(true);
    await windowManager.setSkipTaskbar(true);
    final display = await screenRetriever.getPrimaryDisplay();
    final area = (display.visiblePosition ?? Offset.zero) & (display.visibleSize ?? display.size);
    const margin = 16.0;
    await windowManager.setBounds(
      Rect.fromLTWH(
        area.right - popupSize.width - margin,
        area.bottom - popupSize.height - margin,
        popupSize.width,
        popupSize.height,
      ),
    );
    // Without taking focus from whatever you're doing.
    await windowManager.show(inactive: true);
  }

  /// The corner window is finished with its request: received, declined,
  /// or the sender gave up. The next one takes its place, or it goes away.
  Future<void> popupDone() async {
    if (_queue.isNotEmpty) {
      popup.value = _queue.removeAt(0);
      return;
    }
    await windowManager.hide();
    popup.value = null;
    await windowManager.setAlwaysOnTop(false);
    await windowManager.setSkipTaskbar(false);
    await windowManager.setResizable(true);
    await windowManager.setTitleBarStyle(TitleBarStyle.normal);
    if (_bounds case final bounds?) await windowManager.setBounds(bounds);
    _bounds = null;
    if (_openAfter) {
      _openAfter = false;
      await open();
    }
  }

  /// Back from the tray.
  Future<void> open() async {
    if (popup.value != null) {
      _openAfter = true;
      return;
    }
    _hidden = false;
    await windowManager.show();
    await windowManager.focus();
  }

  Future<void> quit() async {
    await trayManager.destroy();
    exit(0);
  }

  // Closing the window hides it; Quit is in the tray menu.
  @override
  void onWindowClose() {
    if (popup.value != null) return;
    _hidden = true;
    unawaited(windowManager.hide());
  }

  // Shown some other way (on a Mac, clicking the Dock icon).
  @override
  void onWindowFocus() {
    if (popup.value == null) _hidden = false;
  }

  @override
  void onTrayIconMouseDown() {
    // Windows: a click opens Sidekick, a right-click shows the menu. The
    // Mac's menu bar shows the menu on a click.
    if (Platform.isWindows) {
      unawaited(open());
    } else {
      unawaited(trayManager.popUpContextMenu());
    }
  }

  @override
  void onTrayIconRightMouseDown() => unawaited(trayManager.popUpContextMenu());

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    switch (menuItem.key) {
      case 'open':
        unawaited(open());
      case 'quit':
        unawaited(quit());
    }
  }
}

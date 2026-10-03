import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
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
  static const popupSize = Size(380, 172);

  /// The Mac's own window code (MainFlutterWindow.swift): it catches the red
  /// button itself and shows the pop-up without taking the focus.
  static const _mac = MethodChannel('sidekick/macos');

  /// The Mac window's usual minimum size, lifted while it's the small pop-up.
  static const _macMinSize = Size(420, 560);

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
    // Windows: window_manager catches the close button. The Mac does it in
    // MainFlutterWindow.performClose: the plugin never got the close there,
    // and the red button quit Sidekick.
    if (Platform.isWindows) await windowManager.setPreventClose(true);
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
      if (Platform.isWindows) await windowManager.setPreventClose(false);
      return;
    }
    if (Platform.isMacOS) {
      _mac.setMethodCallHandler((call) async {
        switch (call.method) {
          case 'closedToMenuBar':
            _hidden = true;
          case 'openedFromMenuBar':
            if (popup.value == null) _hidden = false;
        }
        return null;
      });
      await _mac.invokeMethod('setKeepInMenuBar', {'on': true});
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
    // The Mac window can't usually be this small.
    if (Platform.isMacOS) await windowManager.setMinimumSize(popupSize);
    // Never setSkipTaskbar: on Windows, window_manager only creates its
    // taskbar object in waitUntilReadyToShow (which Sidekick doesn't use),
    // so setSkipTaskbar dereferenced a null pointer and the whole app
    // crashed the moment a request arrived in the tray (2.6.2).
    final display = await screenRetriever.getPrimaryDisplay();
    final area = (display.visiblePosition ?? Offset.zero) & (display.visibleSize ?? display.size);
    const margin = 16.0;
    final target = Rect.fromLTWH(
      area.right - popupSize.width - margin,
      area.bottom - popupSize.height - margin,
      popupSize.width,
      popupSize.height,
    );
    // Without taking focus from whatever you're doing (window_manager's
    // show always activates the app on a Mac). The Mac fades it in itself.
    if (Platform.isMacOS) {
      await windowManager.setBounds(target);
      await _mac.invokeMethod('showPopup');
    } else {
      await _riseInto(target);
    }
  }

  /// Windows: the corner window rises a little into place as it appears.
  Future<void> _riseInto(Rect target) async {
    const rise = 18.0, steps = 8;
    await windowManager.setBounds(target.translate(0, rise));
    await windowManager.show(inactive: true);
    for (var i = 1; i <= steps; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 16));
      if (popup.value == null) return;
      final t = Curves.easeOutCubic.transform(i / steps);
      await windowManager.setPosition(target.topLeft.translate(0, rise * (1 - t)));
    }
  }

  /// The corner window is finished with its request: received, declined,
  /// or the sender gave up. The next one takes its place, or it goes away.
  Future<void> popupDone() async {
    if (_queue.isNotEmpty) {
      popup.value = _queue.removeAt(0);
      return;
    }
    if (Platform.isMacOS) {
      await _mac.invokeMethod('hidePopup');
    } else {
      await windowManager.hide();
    }
    popup.value = null;
    await windowManager.setAlwaysOnTop(false);
    await windowManager.setResizable(true);
    await windowManager.setTitleBarStyle(TitleBarStyle.normal);
    if (Platform.isMacOS) await windowManager.setMinimumSize(_macMinSize);
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

  // Closing the window hides it; Quit is in the tray menu. (Windows: the
  // Mac reports it as closedToMenuBar.)
  @override
  void onWindowClose() {
    if (!Platform.isWindows || popup.value != null) return;
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

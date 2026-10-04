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

  /// The panel a click on the tray icon opens (like CleanMyMac's).
  static const panelSize = Size(380, 640);

  /// The tray panel is showing (the app draws only it, see main.dart).
  final panel = ValueNotifier(false);

  /// A tab the main window should show when it opens (the panel's Settings).
  final openTab = ValueNotifier<int?>(null);

  /// When the panel last closed on its own (focus went elsewhere): a click
  /// on the tray icon that did it shouldn't open it again at once.
  DateTime _panelClosedAt = DateTime(0);

  /// The panel opened the file picker: losing focus to it isn't leaving.
  bool holdPanel = false;

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

  Future<void> init({bool startHidden = false}) async {
    await windowManager.ensureInitialized();
    // The close button hides the window instead (onWindowClose).
    await windowManager.setPreventClose(true);
    windowManager.addListener(this);
    // The Mac also catches the red button itself (MainFlutterWindow) and
    // never quits after the last window: 2.6.6 and 2.7.0 still quit on it.
    // Set first, needing no menu-bar icon: Sidekick stays in the Dock, and
    // a click there always brings the window back.
    if (Platform.isMacOS) {
      _mac.setMethodCallHandler((call) async {
        switch (call.method) {
          case 'closedToMenuBar':
            _hidden = true;
          case 'openedFromMenuBar':
            if (popup.value == null && !panel.value) _hidden = false;
        }
        return null;
      });
      try {
        await _mac.invokeMethod('setKeepInMenuBar', {'on': true});
      } catch (e) {
        debugPrint('Sidekick: keep in menu bar: $e');
      }
    }
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
      // No tray icon. Windows has no other way back: closing quits, as
      // before. (The Mac still has its Dock icon.)
      debugPrint('Sidekick: no tray icon: $e');
      if (Platform.isWindows) {
        await windowManager.setPreventClose(false);
        // No tray to come back from: never start hidden.
        if (startHidden) await windowManager.show();
        return;
      }
    }
    // Started at login (Auto-load): straight to the tray. (Windows' runner
    // never showed the window; the Mac hides it.)
    if (startHidden) {
      _hidden = true;
      if (Platform.isMacOS) await _mac.invokeMethod('hideToMenuBar');
    }
  }

  /// Shows [offer] in the corner window if Sidekick is in the tray. False
  /// when its window is open: the app shows its own card then.
  bool show(TransferOffer offer) {
    if (!_hidden) return false;
    // The panel gives way to the request (same window, same settings).
    panel.value = false;
    if (popup.value == null) {
      unawaited(_openPopup(offer));
    } else {
      _queue.add(offer);
    }
    return true;
  }

  /// The small-window look shared by the corner pop-up and the panel.
  Future<void> _compact(Size size) async {
    _bounds ??= await windowManager.getBounds();
    await windowManager.setTitleBarStyle(TitleBarStyle.hidden, windowButtonVisibility: false);
    await windowManager.setResizable(false);
    await windowManager.setAlwaysOnTop(true);
    // The Mac window can't usually be this small.
    if (Platform.isMacOS) await windowManager.setMinimumSize(size);
  }

  /// Back to the full window's look and place, hidden.
  Future<void> _restore() async {
    await windowManager.setAlwaysOnTop(false);
    await windowManager.setResizable(true);
    await windowManager.setTitleBarStyle(TitleBarStyle.normal);
    if (Platform.isMacOS) await windowManager.setMinimumSize(_macMinSize);
    if (_bounds case final bounds?) await windowManager.setBounds(bounds);
    _bounds = null;
  }

  // ------------------------------------------------------------ tray panel

  /// The tray icon was clicked: the panel opens (or closes) by the icon.
  /// With the main window open, it comes to the front instead.
  Future<void> togglePanel() async {
    if (popup.value != null) return;
    if (panel.value) return closePanel();
    if (!_hidden) return open();
    if (DateTime.now().difference(_panelClosedAt) < const Duration(milliseconds: 400)) return;
    panel.value = true;
    await _compact(panelSize);
    final display = await screenRetriever.getPrimaryDisplay();
    final area = (display.visiblePosition ?? Offset.zero) & (display.visibleSize ?? display.size);
    const margin = 10.0;
    final icon = await trayManager.getBounds();
    // Mac: under the menu bar, below the icon. Windows: above the taskbar
    // in the corner, where the tray is.
    final left = Platform.isMacOS && icon != null
        ? (icon.center.dx - panelSize.width / 2).clamp(area.left + margin, area.right - panelSize.width - margin)
        : area.right - panelSize.width - margin;
    final top = Platform.isMacOS ? area.top + margin : area.bottom - panelSize.height - margin;
    await windowManager.setBounds(Rect.fromLTWH(left, top, panelSize.width, panelSize.height));
    // Taking focus, so a click anywhere else closes it (onWindowBlur).
    await windowManager.show();
    await windowManager.focus();
  }

  /// Closes the panel (focus went elsewhere, or one of its buttons).
  Future<void> closePanel() async {
    if (!panel.value) return;
    _panelClosedAt = DateTime.now();
    if (Platform.isMacOS) {
      await _mac.invokeMethod('hidePopup');
    } else {
      await windowManager.hide();
    }
    panel.value = false;
    await _restore();
  }

  /// The panel's Open Sidekick (and Settings: [tab] 3).
  Future<void> openFromPanel({int? tab}) async {
    openTab.value = tab;
    await closePanel();
    await open();
  }

  Future<void> _openPopup(TransferOffer offer) async {
    popup.value = offer;
    await _compact(popupSize);
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
    await _restore();
    if (_openAfter) {
      _openAfter = false;
      await open();
    }
  }

  /// Back from the tray.
  Future<void> open() async {
    if (panel.value) await closePanel();
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

  // Closing the window hides it; Quit is in the tray menu. (On the Mac,
  // when MainFlutterWindow didn't catch it first.)
  @override
  void onWindowClose() {
    if (popup.value != null) return;
    _hidden = true;
    unawaited(Platform.isMacOS ? _mac.invokeMethod('hideToMenuBar') : windowManager.hide());
  }

  // Shown some other way (on a Mac, clicking the Dock icon).
  @override
  void onWindowFocus() {
    if (popup.value == null && !panel.value) _hidden = false;
  }

  // A click anywhere else closes the panel.
  @override
  void onWindowBlur() {
    if (panel.value && !holdPanel) unawaited(closePanel());
  }

  // A click opens the panel; a right-click (or Control-click) the menu.
  @override
  void onTrayIconMouseDown() => unawaited(togglePanel());

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

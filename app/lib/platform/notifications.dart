import 'dart:async';
import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';

import '../core/server.dart';
import '../ui/widgets.dart';

/// Phones: a request that arrives while Sidekick isn't on screen shows a
/// notification with Accept and Decline (`notifyOffer` on `sidekick/ios`
/// and `sidekick/android`; the buttons come back as `offerAction`). On
/// Android it then shows the progress, and a foreground service keeps a
/// small "Ready to receive" notification while Sidekick runs in the
/// background.
abstract final class OfferNotifications {
  static bool get supported => Platform.isIOS || Platform.isAndroid;

  static final _channel = MethodChannel(Platform.isIOS ? 'sidekick/ios' : 'sidekick/android');

  /// Requests with a notification up, by id.
  static final _shown = <String, TransferOffer>{};

  /// Asks for permission to notify, answers the buttons, and on Android
  /// starts the "Ready to receive" service. Call once, on start.
  static Future<void> init() async {
    if (!supported) return;
    _channel.setMethodCallHandler((call) async {
      if (call.method != 'offerAction') return null;
      final args = (call.arguments as Map).cast<String, Object?>();
      final offer = _shown[args['id']];
      if (offer == null || !offer.isOpen) return null;
      switch (args['action']) {
        case 'accept':
          offer.accept();
        case 'decline':
          offer.decline();
      }
      return null;
    });
    try {
      await _channel.invokeMethod('requestNotifications');
    } catch (e) {
      debugPrint('Sidekick: notifications: $e');
    }
  }

  /// Shows [offer] as a notification if Sidekick isn't on screen.
  static void show(TransferOffer offer) {
    if (!supported || WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed) return;
    final files = offer.files;
    final what = files.length == 1 ? files.first.name : '${files.length} files';
    final size = offer.totalBytes;
    _shown[offer.id] = offer;
    _call('notifyOffer', {
      'id': offer.id,
      'title': '${offer.from.name} wants to send you $what',
      'body': size > 0 ? '${files.length == 1 ? '1 file' : '${files.length} files'} · ${formatBytes(size)}' : what,
      'timeout': SidekickServer.offerTimeout.inMilliseconds,
    });
    unawaited(
      offer.answer.then((answer) {
        if (answer != OfferAnswer.accepted) {
          _shown.remove(offer.id);
          _call('cancelOffer', {'id': offer.id});
          return;
        }
        // Android shows the progress (at most twice a second), then "Received".
        var last = DateTime(0);
        offer.progress.listen(
          (bytes) {
            final now = DateTime.now();
            if (!Platform.isAndroid || now.difference(last).inMilliseconds < 500) return;
            last = now;
            _call('offerProgress', {
              'id': offer.id,
              'title': 'Receiving $what from ${offer.from.name}',
              'done': bytes,
              'total': size,
            });
          },
          onDone: () {
            _shown.remove(offer.id);
            _call('offerDone', {'id': offer.id, 'title': 'Received $what', 'body': 'From ${offer.from.name}'});
          },
        );
      }),
    );
  }

  /// [from] pinged this phone while Sidekick isn't on screen.
  static void showPing(String from) {
    if (!supported || WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed) return;
    _call('offerDone', {'id': 'ping', 'title': 'Ping from $from', 'body': 'Open Sidekick to stop the sound'});
  }

  /// [from] wants to see this phone's screen while Sidekick isn't on
  /// screen: opening Sidekick answers it ([ask]) or starts it.
  static void showMirror(String from, {required bool ask}) {
    if (!supported || WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed) return;
    _call('offerDone', {
      'id': 'mirror',
      'title': ask ? '$from wants to see your screen' : '$from wants to mirror your screen',
      'body': ask ? 'Open Sidekick to answer' : 'Open Sidekick to start Screen Mirroring',
      'timeout': 60000,
    });
  }

  static void cancelMirror() {
    if (supported) _call('cancelOffer', {'id': 'mirror'});
  }

  static void _call(String method, Map<String, Object?> args) =>
      unawaited(_channel.invokeMethod(method, args).catchError((Object e) => debugPrint('Sidekick: $method: $e')));
}

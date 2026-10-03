import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../app_state.dart';
import '../core/server.dart';

/// iPhone: a transfer's progress on the Lock Screen and in the Dynamic
/// Island (Live Activities, iOS 16.2+): `liveStart`, `liveUpdate` and
/// `liveEnd` on `sidekick/ios` (LiveTransfers in AppDelegate.swift), drawn
/// by the SidekickLive widget extension. Updates go at most once a second,
/// as iOS asks; a finished one stays for a few seconds.
abstract final class LiveTransfers {
  static bool get supported => Platform.isIOS;
  static const _channel = MethodChannel('sidekick/ios');
  static const _every = Duration(seconds: 1);

  static String _what(List<String> names) => names.length == 1 ? names.first : '${names.length} files';

  /// Files coming in once [offer] is accepted (here or from a notification).
  static void followIncoming(TransferOffer offer) {
    if (!supported) return;
    unawaited(
      offer.answer.then((answer) {
        if (answer != OfferAnswer.accepted) return;
        final total = offer.totalBytes;
        _call('liveStart', {
          'id': offer.id,
          'device': offer.from.name,
          'incoming': true,
          'title': _what([for (final f in offer.files) f.name]),
          'total': total,
          'status': 'Receiving',
        });
        var last = DateTime(0);
        offer.progress.listen((bytes) {
          final now = DateTime.now();
          if (now.difference(last) < _every) return;
          last = now;
          _call('liveUpdate', {'id': offer.id, 'done': bytes, 'total': total, 'status': 'Receiving'});
        }, onDone: () => _call('liveEnd', {'id': offer.id, 'done': total, 'total': total, 'status': 'Received'}));
      }),
    );
  }

  /// Files going out with Send, from the moment they start to go.
  static void followOutgoing(OutgoingSend send) {
    if (!supported) return;
    final id = 'send-${identityHashCode(send)}';
    var started = false;
    var last = DateTime(0);
    void changed() {
      if (!started && send.phase == SendPhase.sending) {
        started = true;
        _call('liveStart', {
          'id': id,
          'device': send.device.name,
          'incoming': false,
          'title': _what(send.names),
          'total': send.total,
          'status': 'Sending',
        });
      }
      if (!started) {
        if (send.finished) send.removeListener(changed);
        return;
      }
      if (send.finished) {
        send.removeListener(changed);
        final ok = send.phase == SendPhase.done;
        _call('liveEnd', {
          'id': id,
          'done': ok ? send.total : send.done,
          'total': send.total,
          'status': switch (send.phase) {
            SendPhase.done => 'Sent',
            SendPhase.declined => 'Declined',
            SendPhase.noAnswer => 'No answer',
            _ => "Didn't send",
          },
          'failed': !ok,
        });
        return;
      }
      final now = DateTime.now();
      if (now.difference(last) < _every) return;
      last = now;
      _call('liveUpdate', {'id': id, 'done': send.done, 'total': send.total, 'status': 'Sending'});
    }

    send.addListener(changed);
  }

  static void _call(String method, Map<String, Object?> args) => unawaited(
    _channel.invokeMethod<void>(method, args).catchError((Object e) => debugPrint('Sidekick: $method: $e')),
  );
}

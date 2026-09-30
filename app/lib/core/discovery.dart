import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'models.dart';

/// Finds other Sidekick devices on the local network with UDP multicast.
///
/// Every device announces itself on start-up and every few seconds, by
/// multicast and broadcast. Whoever hears an announcement answers the sender
/// directly by unicast: a PC with several network adapters (Hyper-V, WSL,
/// VPNs) often sends multicast out of the wrong one, but a direct reply is
/// routed correctly, so both sides still find each other.
class Discovery {
  Discovery({required this.self, this.port = sidekickPort, this.interval = const Duration(seconds: 5)});

  final DeviceInfo Function() self;
  final int port;
  final Duration interval;

  final _found = StreamController<DeviceInfo>.broadcast();

  /// Every announcement from another device, including repeats.
  Stream<DeviceInfo> get found => _found.stream;

  RawDatagramSocket? _socket;
  Timer? _timer;
  final _group = InternetAddress(multicastGroup);
  final _broadcast = InternetAddress('255.255.255.255');

  /// When we last answered each address directly, to keep replies rare.
  final Map<String, DateTime> _lastDirectReply = {};

  /// Starts listening and announcing. Calling it again restarts, which
  /// re-joins multicast on the current network interfaces (after a Wi-Fi
  /// switch or waking from sleep the old membership hears nothing).
  Future<void> start() async {
    await stop();
    final socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, port, reuseAddress: true);
    socket.multicastLoopback = false;
    try {
      socket.broadcastEnabled = true;
    } catch (_) {
      // Not allowed on this platform; multicast and direct replies remain.
    }
    // Join on every IPv4 interface so we hear peers on Wi-Fi *and* Ethernet.
    final interfaces = await NetworkInterface.list(type: InternetAddressType.IPv4);
    var joined = false;
    for (final nic in interfaces) {
      try {
        socket.joinMulticast(_group, nic);
        joined = true;
      } catch (_) {
        // Some virtual adapters refuse multicast; skip them.
      }
    }
    if (!joined) {
      try {
        socket.joinMulticast(_group);
      } catch (_) {
        // No multicast (e.g. iOS without Apple's multicast entitlement). We
        // can still announce; AppState.scanNetwork finds the rest.
      }
    }
    socket.listen(
      (event) {
        if (event == RawSocketEvent.read) _onRead(socket);
      },
      // The network went away; AppState restarts discovery when it's back.
      onError: (Object _) {},
    );
    _socket = socket;
    announce(askForReplies: true);
    _timer = Timer.periodic(interval, (_) => announce());
  }

  void _onRead(RawDatagramSocket socket) {
    final datagram = socket.receive();
    if (datagram == null || datagram.data.length > 8192) return;
    try {
      final msg = jsonDecode(utf8.decode(datagram.data));
      if (msg is! Map<String, dynamic> || msg['type'] != 'sidekick.announce') return;
      final device = DeviceInfo.fromJson(msg['device'] as Map<String, dynamic>, address: datagram.address.address);
      if (device.id == self().id) return;
      _found.add(device);
      final from = datagram.address.address;
      final last = _lastDirectReply[from];
      final now = DateTime.now();
      final due = last == null || now.difference(last) > const Duration(seconds: 10);
      final asked = msg['reply'] == true && (last == null || now.difference(last) > const Duration(seconds: 1));
      if (due || asked) {
        _lastDirectReply[from] = now;
        _send(_payload(), datagram.address);
      }
    } catch (_) {
      // Not ours, or malformed.
    }
  }

  List<int> _payload({bool askForReplies = false}) =>
      utf8.encode(jsonEncode({'type': 'sidekick.announce', 'reply': askForReplies, 'device': self().toJson()}));

  void _send(List<int> data, InternetAddress to) {
    try {
      _socket?.send(data, to, port);
    } catch (_) {
      // Network went away (sleep, Wi-Fi switch), or broadcast isn't allowed.
      // Next tick will retry.
    }
  }

  void announce({bool askForReplies = false}) {
    final data = _payload(askForReplies: askForReplies);
    _send(data, _group);
    _send(data, _broadcast);
  }

  Future<void> stop() async {
    _timer?.cancel();
    _timer = null;
    _socket?.close();
    _socket = null;
  }
}

/// This machine's LAN IPv4 addresses, for showing "reach me at" hints.
/// Never throws: some phones refuse to list interfaces now and then.
Future<List<String>> localAddresses() async {
  try {
    final interfaces = await NetworkInterface.list(type: InternetAddressType.IPv4);
    return [
      for (final nic in interfaces)
        for (final a in nic.addresses)
          if (!a.isLoopback && !a.isLinkLocal) a.address,
    ];
  } catch (_) {
    return const [];
  }
}

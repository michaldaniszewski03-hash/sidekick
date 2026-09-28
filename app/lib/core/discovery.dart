import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'models.dart';

/// Finds other Sidekick devices on the local network with UDP multicast.
///
/// Every device announces itself on start-up and every few seconds. A
/// start-up announcement asks others to answer right away, so new devices
/// show up in about a second instead of waiting for the next round.
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
  DateTime _lastReply = DateTime.fromMillisecondsSinceEpoch(0);
  final _group = InternetAddress(multicastGroup);

  Future<void> start() async {
    final socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, port, reuseAddress: true);
    socket.multicastLoopback = false;
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
    socket.listen((event) {
      if (event == RawSocketEvent.read) _onRead(socket);
    });
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
      if (msg['reply'] == true && DateTime.now().difference(_lastReply) > const Duration(seconds: 1)) {
        _lastReply = DateTime.now();
        announce();
      }
    } catch (_) {
      // Not ours, or malformed.
    }
  }

  void announce({bool askForReplies = false}) {
    final data = utf8.encode(
      jsonEncode({'type': 'sidekick.announce', 'reply': askForReplies, 'device': self().toJson()}),
    );
    try {
      _socket?.send(data, _group, port);
    } catch (_) {
      // Network went away (sleep, Wi-Fi switch). Next tick will retry.
    }
  }

  Future<void> stop() async {
    _timer?.cancel();
    _socket?.close();
    _socket = null;
  }
}

/// This machine's LAN IPv4 addresses, for showing "reach me at" hints.
Future<List<String>> localAddresses() async {
  final interfaces = await NetworkInterface.list(type: InternetAddressType.IPv4);
  return [
    for (final nic in interfaces)
      for (final a in nic.addresses)
        if (!a.isLoopback && !a.isLinkLocal) a.address,
  ];
}

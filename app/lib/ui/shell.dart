import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../app_state.dart';
import '../core/pairing_qr.dart';
import '../core/server.dart';
import '../core/trust.dart';
import '../platform/sound.dart';
import 'devices_page.dart';
import 'files_page.dart';
import 'qr_pairing.dart';
import 'remote_page.dart';
import 'settings_page.dart';
import 'transfer_screens.dart';

class Shell extends StatefulWidget {
  const Shell({super.key, required this.state});
  final AppState state;

  @override
  State<Shell> createState() => _ShellState();
}

class _ShellState extends State<Shell> {
  int _index = 0;
  late final List<StreamSubscription<Object>> _subs;
  // Picks up permissions granted in system settings while we were away.
  late final AppLifecycleListener _lifecycle;

  AppState get state => widget.state;

  static const _destinations = [
    (icon: Icons.devices_outlined, selected: Icons.devices, label: 'Devices'),
    (icon: Icons.folder_outlined, selected: Icons.folder, label: 'Files'),
    (icon: Icons.mouse_outlined, selected: Icons.mouse, label: 'Remote'),
    (icon: Icons.settings_outlined, selected: Icons.settings, label: 'Settings'),
  ];

  @override
  void initState() {
    super.initState();
    _subs = [
      state.pairRequests.listen(_showPin),
      state.notices.listen(_showNotice),
      state.transferOffers.listen(_showOffer),
      state.sends.listen(_showSend),
    ];
    _lifecycle = AppLifecycleListener(onResume: state.resumed);
  }

  @override
  void dispose() {
    for (final s in _subs) {
      s.cancel();
    }
    _lifecycle.dispose();
    super.dispose();
  }

  void _go(int index) => setState(() => _index = index);

  void _showOffer(TransferOffer offer) {
    if (!mounted) return;
    if (state.sound) unawaited(playRequestSound());
    showIncomingOffer(context, offer, sounds: state.sound);
  }

  void _showSend(OutgoingSend send) {
    if (mounted) showSendingScreen(context, send);
  }

  void _showNotice(Notice notice) {
    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(
      SnackBar(
        content: Row(
          children: [
            Icon(
              notice.revealPath != null ? Icons.download_done_rounded : Icons.info_outline_rounded,
              color: Theme.of(context).colorScheme.inversePrimary,
            ),
            const SizedBox(width: 12),
            Expanded(child: Text(notice.message)),
          ],
        ),
        action: notice.revealPath == null || !canRevealFiles
            ? null
            : SnackBarAction(label: 'Show in folder', onPressed: () => revealInFolder(notice.revealPath!)),
      ),
    );
  }

  Future<void> _showPin(PairingRequest request) async {
    // Close the dialog automatically once the other device enters the code.
    final done = state.pairedEvents.firstWhere((d) => d.id == request.device.id);
    final cancelled = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => _PinDialog(request: request, done: done, selfId: state.id),
    );
    if (cancelled ?? true) state.cancelPairing(request.device.id);
  }

  @override
  Widget build(BuildContext context) {
    final pages = [
      DevicesPage(state: state, onOpen: _go),
      FilesPage(state: state, onGoToDevices: () => _go(0)),
      RemotePage(state: state, onGoToDevices: () => _go(0)),
      SettingsPage(state: state),
    ];
    final wide = MediaQuery.sizeOf(context).width >= 700;
    final scheme = Theme.of(context).colorScheme;

    final body = ListenableBuilder(
      listenable: state,
      builder: (context, _) => Column(
        children: [
          if (state.activeRemoteSessions.isNotEmpty)
            MaterialBanner(
              backgroundColor: scheme.tertiaryContainer,
              leading: Icon(Icons.phonelink_ring_outlined, color: scheme.onTertiaryContainer),
              content: Text(
                '${state.activeRemoteSessions.values.map((p) => p.name).join(', ')} is controlling this computer',
                style: TextStyle(color: scheme.onTertiaryContainer),
              ),
              actions: [
                TextButton(
                  onPressed: () {
                    for (final id in state.activeRemoteSessions.keys.toList()) {
                      state.unpair(id);
                    }
                  },
                  child: const Text('Unpair and stop'),
                ),
              ],
            ),
          Expanded(
            // Material "fade through": the old tab fades out, the new one
            // fades in while rising slightly.
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 300),
              switchInCurve: Curves.easeOutCubic,
              switchOutCurve: Curves.easeInCubic,
              transitionBuilder: (child, animation) => FadeTransition(
                opacity: animation,
                child: SlideTransition(
                  position: Tween(begin: const Offset(0, 0.015), end: Offset.zero).animate(animation),
                  child: ScaleTransition(scale: Tween(begin: 0.985, end: 1.0).animate(animation), child: child),
                ),
              ),
              child: KeyedSubtree(key: ValueKey(_index), child: pages[_index]),
            ),
          ),
        ],
      ),
    );

    if (!wide) {
      return Scaffold(
        body: SafeArea(child: body),
        bottomNavigationBar: NavigationBar(
          selectedIndex: _index,
          onDestinationSelected: _go,
          destinations: [
            for (final d in _destinations)
              NavigationDestination(icon: Icon(d.icon), selectedIcon: Icon(d.selected), label: d.label),
          ],
        ),
      );
    }

    return Scaffold(
      backgroundColor: scheme.surfaceContainer,
      body: Row(
        children: [
          NavigationRail(
            backgroundColor: scheme.surfaceContainer,
            selectedIndex: _index,
            onDestinationSelected: _go,
            labelType: NavigationRailLabelType.all,
            groupAlignment: -0.85,
            leading: Padding(
              padding: const EdgeInsets.only(top: 22, bottom: 14),
              // The "sk" logo is white-on-transparent; tint it to the theme.
              child: Image.asset(
                'assets/logo/logo.png',
                height: 34,
                color: scheme.onSurface,
                semanticLabel: 'Sidekick',
              ),
            ),
            destinations: [
              for (final d in _destinations)
                NavigationRailDestination(icon: Icon(d.icon), selectedIcon: Icon(d.selected), label: Text(d.label)),
            ],
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(0, 8, 8, 8),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(28),
                child: ColoredBox(color: scheme.surface, child: body),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _PinDialog extends StatefulWidget {
  const _PinDialog({required this.request, required this.done, required this.selfId});
  final PairingRequest request;

  /// This device's id, in the QR code: the scanner checks it's ours.
  final String selfId;
  final Future<Object> done;

  @override
  State<_PinDialog> createState() => _PinDialogState();
}

class _PinDialogState extends State<_PinDialog> {
  Timer? _expiry;

  @override
  void initState() {
    super.initState();
    widget.done.then((_) {
      if (mounted) Navigator.of(context).pop(false);
    });
    _expiry = Timer(widget.request.expires.difference(DateTime.now()), () {
      if (mounted) Navigator.of(context).pop(true);
    });
  }

  @override
  void dispose() {
    _expiry?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final pin = widget.request.pin;
    final scheme = Theme.of(context).colorScheme;
    return AlertDialog(
      icon: const Icon(Icons.link_rounded),
      title: Text('Pair with ${widget.request.device.name}?'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text('Enter this code on the other device:', textAlign: TextAlign.center),
          const SizedBox(height: 20),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
            decoration: BoxDecoration(color: scheme.primaryContainer, borderRadius: BorderRadius.circular(20)),
            child: SelectableText(
              '${pin.substring(0, 3)} ${pin.substring(3)}',
              style: Theme.of(context).textTheme.displaySmall?.copyWith(
                color: scheme.onPrimaryContainer,
                fontWeight: FontWeight.w700,
                letterSpacing: 6,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
          // A phone or Mac can scan this instead of typing the digits.
          if (scansQr(widget.request.device.platform)) ...[
            const SizedBox(height: 16),
            Text('or scan it:', style: TextStyle(color: scheme.onSurfaceVariant)),
            const SizedBox(height: 12),
            PairingQrCode(
              data: PinQr(id: widget.selfId, pin: pin).encode(),
              size: 150,
            ),
          ],
          const SizedBox(height: 16),
          Text(
            'Only pair with devices you own. A paired device can send and browse files and use the mouse and keyboard.',
            textAlign: TextAlign.center,
            style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13),
          ),
        ],
      ),
      actions: [TextButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('Cancel'))],
    );
  }
}

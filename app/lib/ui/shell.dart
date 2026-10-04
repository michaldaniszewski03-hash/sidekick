import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../app_state.dart';
import '../core/models.dart';
import '../core/server.dart';
import '../core/trust.dart';
import '../platform/clipboard.dart';
import '../platform/desktop_window.dart';
import '../platform/gallery.dart';
import '../platform/live_activity.dart';
import '../platform/notifications.dart';
import '../platform/sound.dart';
import 'devices_page.dart';
import 'direct_wifi.dart';
import 'ping.dart';
import 'files_page.dart';
import 'qr_pairing.dart';
import 'remote_page.dart';
import 'settings_page.dart';
import 'transfer_screens.dart';
import 'widgets.dart';

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
      // Another device pinged this one: loud, and who.
      state.pings.listen((from) {
        if (mounted) unawaited(showPinged(context, state, from));
      }),
      // iPhone: a network to join by hand for a direct link.
      state.manualJoins.listen((join) {
        if (mounted) unawaited(showManualJoin(context, join));
      }),
    ];
    _lifecycle = AppLifecycleListener(onResume: state.resumed);
    // The first time this device pairs with an iPhone: it can't be controlled.
    _subs.add(
      state.pairedEvents.listen((d) {
        if (d.platform == DevicePlatform.ios && !state.iphoneRemoteNoticeSeen && mounted) {
          unawaited(showIphoneRemoteNotice(context, state, d.name));
        }
      }),
    );
    // Phones: requests while Sidekick is in the background become notifications.
    unawaited(OfferNotifications.init());
    // iPhone, once: how to stop iOS asking "Allow Paste?" for every copy.
    if (hostIsIOS && state.shareClipboard && !state.pasteTipSeen) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_showPasteTip());
      });
    }
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

  Future<void> _showPasteTip() async {
    state.markPasteTipSeen();
    final open = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        icon: const Icon(Icons.content_paste_go_rounded),
        title: const Text('Your clipboard, on every device'),
        content: const Text(
          'What you copy goes to your other devices by itself while Sidekick is open (iOS lets no app read the '
          'clipboard in the background).\n\niOS asks "Allow Paste?" each time, unless you set Sidekick → '
          'Paste from Other Apps → Allow in Settings.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Later')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Open Settings')),
        ],
      ),
    );
    if (open == true) await openIosAppSettings();
  }

  void _showOffer(TransferOffer offer) {
    // iPhone: the progress on the Lock Screen and in the Dynamic Island.
    LiveTransfers.followIncoming(offer);
    if (!mounted) return;
    if (state.sound) unawaited(playRequestSound());
    // Closed to the tray: the small corner window asks instead.
    if (DesktopWindow.supported && DesktopWindow.instance.show(offer)) return;
    // Phones in the background: a notification too; the card waits in the app.
    OfferNotifications.show(offer);
    showIncomingOffer(context, offer, sounds: state.sound);
  }

  void _showSend(OutgoingSend send) {
    LiveTransfers.followOutgoing(send);
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
        action: notice.inGallery
            ? SnackBarAction(label: 'Open', onPressed: () => Gallery.open(notice.galleryUri))
            : notice.revealPath == null || !canRevealFiles
            ? null
            : SnackBarAction(label: revealLabel, onPressed: () => revealInFolder(notice.revealPath!)),
      ),
    );
  }

  Future<void> _showPin(PairingRequest request) async {
    // Close the dialog automatically once the other device enters the code.
    final done = state.pairedEvents.firstWhere((d) => d.id == request.device.id);
    final cancelled = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => _PinDialog(request: request, done: done, state: state),
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
  const _PinDialog({required this.request, required this.done, required this.state});
  final PairingRequest request;
  final AppState state;
  final Future<Object> done;

  @override
  State<_PinDialog> createState() => _PinDialogState();
}

class _PinDialogState extends State<_PinDialog> {
  Timer? _expiry;

  /// The same QR code as Connect device → QR code: one code for every way
  /// of pairing. Only for phones (they scan); closed with the dialog.
  late final _invite = scansQr(widget.request.device.platform) ? widget.state.createInvite() : null;

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
    if (_invite case final code?) widget.state.cancelInvite(code.invite);
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
          // A phone can scan this instead of typing the digits.
          if (_invite case final code?) ...[
            const SizedBox(height: 16),
            Text('or scan the QR code:', style: TextStyle(color: scheme.onSurfaceVariant)),
            const SizedBox(height: 12),
            PairingQrCode(data: code.qr, size: 150),
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

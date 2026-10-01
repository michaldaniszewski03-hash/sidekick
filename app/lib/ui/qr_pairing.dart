import 'dart:async';
import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../app_state.dart';
import '../core/models.dart';
import '../core/pairing_qr.dart';
import '../core/trust.dart';
import 'widgets.dart';

/// Devices with a camera Sidekick can scan with. Windows only shows codes
/// (and types the 6-digit one).
bool get canScanQr => Platform.isIOS || Platform.isAndroid || Platform.isMacOS;

/// Whether a device on [platform] can scan a QR code shown here.
bool scansQr(DevicePlatform platform) =>
    const {DevicePlatform.ios, DevicePlatform.android, DevicePlatform.macos}.contains(platform);

/// A QR code, dark on white whatever the theme (cameras want contrast), with
/// the "sk" tile in the middle.
class PairingQrCode extends StatelessWidget {
  const PairingQrCode({super.key, required this.data, this.size = 220});
  final String data;
  final double size;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final tile = size * 0.2;
    return Container(
      padding: EdgeInsets.all(size * 0.06),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(24),
        boxShadow: [
          BoxShadow(color: scheme.shadow.withValues(alpha: 0.12), blurRadius: 18, offset: const Offset(0, 6)),
        ],
      ),
      child: Stack(
        alignment: Alignment.center,
        children: [
          // A fixed size: dialogs measure their content, and the QR view
          // can't be measured before layout.
          SizedBox.square(
            dimension: size,
            child: QrImageView(
              data: data,
              size: size,
              padding: EdgeInsets.zero,
              // Enough error correction for the tile covering the middle.
              errorCorrectionLevel: QrErrorCorrectLevel.Q,
              eyeStyle: const QrEyeStyle(eyeShape: QrEyeShape.square, color: Color(0xFF111111)),
              dataModuleStyle: const QrDataModuleStyle(
                dataModuleShape: QrDataModuleShape.square,
                color: Color(0xFF111111),
              ),
              semanticsLabel: 'Pairing QR code',
            ),
          ),
          Container(
            width: tile,
            height: tile,
            padding: EdgeInsets.all(tile * 0.2),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [scheme.primary, scheme.tertiary],
              ),
              borderRadius: BorderRadius.circular(tile * 0.28),
              border: Border.all(color: Colors.white, width: 3),
            ),
            child: Image.asset('assets/logo/logo.png', color: scheme.onPrimary),
          ),
        ],
      ),
    );
  }
}

/// "Connect device → QR code": shows this device's QR code. Another device
/// scans it and pairs, no code to type. On devices with a camera there's
/// also "Scan a code" for the other direction.
Future<void> showMyQrCode(BuildContext context, AppState state) async {
  final scan = await showDialog<bool>(
    context: context,
    builder: (context) => _MyQrDialog(state: state),
  );
  if (scan == true && context.mounted) await scanToPair(context, state);
}

class _MyQrDialog extends StatefulWidget {
  const _MyQrDialog({required this.state});
  final AppState state;

  @override
  State<_MyQrDialog> createState() => _MyQrDialogState();
}

class _MyQrDialogState extends State<_MyQrDialog> {
  late ({PairingInvite invite, String qr}) _code = widget.state.createInvite();
  late final List<StreamSubscription<Object>> _subs;
  Timer? _renew;

  /// The device that scanned the code and is pairing now.
  DeviceInfo? _pairing;

  @override
  void initState() {
    super.initState();
    _scheduleRenew();
    _subs = [
      widget.state.inviteScans.listen((d) {
        if (mounted) setState(() => _pairing = d);
      }),
      widget.state.pairedEvents.listen((d) {
        // The shell says "Paired with …"; the code's job is done.
        if (mounted && (_pairing == null || _pairing!.id == d.id)) Navigator.pop(context, false);
      }),
    ];
  }

  /// A code works for 5 minutes; a fresh one replaces it while it's shown.
  void _scheduleRenew() {
    _renew?.cancel();
    _renew = Timer(_code.invite.expires.difference(DateTime.now()), () {
      if (!mounted) return;
      widget.state.cancelInvite(_code.invite);
      setState(() {
        _code = widget.state.createInvite();
        _pairing = null;
      });
      _scheduleRenew();
    });
  }

  @override
  void dispose() {
    _renew?.cancel();
    for (final s in _subs) {
      unawaited(s.cancel());
    }
    widget.state.cancelInvite(_code.invite);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final pairing = _pairing;
    return AlertDialog(
      icon: const Icon(Icons.qr_code_2_rounded),
      title: const Text('Scan to connect'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text(
            'On your phone or Mac, open Sidekick, tap Connect device, then QR code, '
            'then Scan a code, and point it here.',
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 20),
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 350),
            switchInCurve: Curves.easeOutBack,
            transitionBuilder: (child, animation) => FadeTransition(
              opacity: animation,
              child: ScaleTransition(scale: Tween(begin: 0.9, end: 1.0).animate(animation), child: child),
            ),
            child: pairing == null
                ? PairingQrCode(key: ValueKey(_code.qr), data: _code.qr)
                : SizedBox(
                    key: const ValueKey('pairing'),
                    width: 260,
                    height: 260,
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        IconTile(platformIcon(pairing.platform), tone: TileTone.primary, size: 64),
                        const SizedBox(height: 16),
                        Text('Pairing with ${pairing.name}…', style: text.titleMedium, textAlign: TextAlign.center),
                        const SizedBox(height: 16),
                        const SizedBox(width: 160, child: LinearProgressIndicator()),
                      ],
                    ),
                  ),
          ),
          const SizedBox(height: 16),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.lock_rounded, size: 16, color: scheme.onSurfaceVariant),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  'Works once, for 5 minutes. Only show it to your own devices.',
                  style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                ),
              ),
            ],
          ),
        ],
      ),
      actions: [
        if (canScanQr)
          TextButton.icon(
            onPressed: () => Navigator.pop(context, true),
            icon: const Icon(Icons.qr_code_scanner_rounded),
            label: const Text('Scan a code'),
          ),
        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Close')),
      ],
    );
  }
}

/// Scans another device's QR code and pairs with it.
Future<void> scanToPair(BuildContext context, AppState state) async {
  final code = await scanPairingQr(context);
  if (code == null || !context.mounted) return;
  switch (code) {
    case PinQr():
      showError(context, 'That\'s a pairing code. On the other device, choose Connect device, then QR code.');
    case InviteQr():
      final paired = await showDialog<PairedDevice>(
        context: context,
        barrierDismissible: false,
        builder: (context) => _PairingProgress(state: state, code: code),
      );
      if (paired != null && context.mounted) showPaired(context, paired);
  }
}

/// "Paired with X" with a check mark.
void showPaired(BuildContext context, PairedDevice device) {
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Row(
        children: [
          Icon(Icons.check_circle_rounded, color: Theme.of(context).colorScheme.inversePrimary),
          const SizedBox(width: 12),
          Expanded(child: Text('Paired with ${device.name}')),
        ],
      ),
    ),
  );
}

class _PairingProgress extends StatefulWidget {
  const _PairingProgress({required this.state, required this.code});
  final AppState state;
  final InviteQr code;

  @override
  State<_PairingProgress> createState() => _PairingProgressState();
}

class _PairingProgressState extends State<_PairingProgress> {
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_pair());
  }

  Future<void> _pair() async {
    setState(() => _error = null);
    try {
      final paired = await widget.state.pairWithInvite(widget.code);
      if (mounted) Navigator.pop(context, paired);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final error = _error;
    final scheme = Theme.of(context).colorScheme;
    return AlertDialog(
      icon: Icon(platformIcon(widget.code.platform)),
      title: Text(error == null ? 'Pairing with ${widget.code.name}…' : "Couldn't pair"),
      content: error == null
          ? const SizedBox(width: 240, child: LinearProgressIndicator())
          : Text(
              error,
              textAlign: TextAlign.center,
              style: TextStyle(color: scheme.error),
            ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(error == null ? 'Hide' : 'Close')),
        if (error != null) FilledButton(onPressed: _pair, child: const Text('Try again')),
      ],
    );
  }
}

/// Opens the camera full screen until it sees a Sidekick QR code.
Future<PairingQr?> scanPairingQr(BuildContext context) =>
    Navigator.of(context).push<PairingQr>(MaterialPageRoute(fullscreenDialog: true, builder: (_) => const _Scanner()));

class _Scanner extends StatefulWidget {
  const _Scanner();

  @override
  State<_Scanner> createState() => _ScannerState();
}

class _ScannerState extends State<_Scanner> {
  final _controller = MobileScannerController(
    formats: const [BarcodeFormat.qrCode],
    detectionSpeed: DetectionSpeed.noDuplicates,
  );
  bool _done = false;
  bool _wrongCode = false;

  @override
  void dispose() {
    unawaited(_controller.dispose());
    super.dispose();
  }

  void _onDetect(BarcodeCapture capture) {
    if (_done) return;
    for (final barcode in capture.barcodes) {
      final code = PairingQr.parse(barcode.rawValue ?? '');
      if (code != null) {
        _done = true;
        Navigator.pop(context, code);
        return;
      }
    }
    if (!_wrongCode) setState(() => _wrongCode = true);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        foregroundColor: Colors.white,
        title: const Text('Scan a QR code'),
      ),
      extendBodyBehindAppBar: true,
      body: Stack(
        fit: StackFit.expand,
        children: [
          MobileScanner(
            controller: _controller,
            onDetect: _onDetect,
            errorBuilder: (context, error) => _CameraProblem(error),
          ),
          // The frame to aim with.
          IgnorePointer(
            child: Center(
              child: Container(
                width: 250,
                height: 250,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(32),
                  border: Border.all(color: Colors.white, width: 3),
                  boxShadow: const [BoxShadow(color: Color(0x88000000), spreadRadius: 2000)],
                ),
              ),
            ),
          ),
          Positioned(
            left: 24,
            right: 24,
            bottom: 48,
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 250),
              child: Container(
                key: ValueKey(_wrongCode),
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
                decoration: BoxDecoration(
                  color: _wrongCode ? scheme.errorContainer : Colors.black54,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  _wrongCode
                      ? "That's not a Sidekick code. Point at the code on the other device."
                      : 'Point at the QR code on the other device',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: _wrongCode ? scheme.onErrorContainer : Colors.white, fontSize: 15),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _CameraProblem extends StatelessWidget {
  const _CameraProblem(this.error);
  final MobileScannerException error;

  @override
  Widget build(BuildContext context) {
    final denied = error.errorCode == MobileScannerErrorCode.permissionDenied;
    return ColoredBox(
      color: Colors.black,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(denied ? Icons.no_photography_rounded : Icons.videocam_off_rounded, color: Colors.white, size: 48),
              const SizedBox(height: 16),
              Text(
                denied
                    ? 'Sidekick needs the camera to scan codes. Allow it in Settings, or type the 6-digit code instead.'
                    : "The camera didn't start (${error.errorCode.name}). Type the 6-digit code instead.",
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white, fontSize: 16),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../core/models.dart';
import 'android.dart';
import 'macos.dart';
import 'input.dart';

/// Reads and controls whatever is playing on *this* device.
abstract class MediaController {
  bool get supported;

  Future<MediaStatus> status();

  /// [position] is used by [MediaAction.seek], [volume] (0–1) by
  /// [MediaAction.setVolume].
  Future<void> perform(MediaAction action, {Duration? position, double? volume});

  Future<void> dispose();

  static MediaController forCurrentPlatform(InputInjector input) {
    if (Platform.isWindows) return WindowsMediaController(input);
    if (Platform.isAndroid) return AndroidMediaController();
    if (Platform.isMacOS) return MacMediaController();
    return UnsupportedMediaController();
  }
}

class UnsupportedMediaController implements MediaController {
  @override
  bool get supported => false;
  @override
  Future<MediaStatus> status() async => const MediaStatus();
  @override
  Future<void> perform(MediaAction action, {Duration? position, double? volume}) async {}
  @override
  Future<void> dispose() async {}
}

/// Turns a Windows AppUserModelID into something readable:
/// `Spotify.exe` → `Spotify`,
/// `Microsoft.ZuneMusic_8wekyb3d8bbwe!Microsoft.ZuneMusic` → `ZuneMusic`,
/// `308046B0AF4A39CB` (Firefox) → `308046B0AF4A39CB`.
String prettyAppName(String aumid) {
  var name = aumid.split('!').first;
  if (name.toLowerCase().endsWith('.exe')) name = name.substring(0, name.length - 4);
  final underscore = name.indexOf('_');
  if (underscore > 0) name = name.substring(0, underscore);
  if (name.contains('.')) name = name.split('.').last;
  if (name.isEmpty) return aumid;
  const known = {'chrome': 'Chrome', 'msedge': 'Edge', 'firefox': 'Firefox', 'vlc': 'VLC', 'ZuneMusic': 'Media Player'};
  return known[name] ?? name;
}

/// Windows media control.
///
/// Now-playing info, seeking and absolute volume come from a small
/// PowerShell helper that talks to the Global System Media Transport
/// Controls (the same API behind the Windows volume flyout) and the Core
/// Audio API. If the helper can't start, play/pause/next/previous and volume
/// still work by sending media keys.
class WindowsMediaController implements MediaController {
  WindowsMediaController(this._keys);

  final InputInjector _keys;
  final helper = PowerShellHelper();

  @override
  bool get supported => true;

  @override
  Future<MediaStatus> status() async {
    final r = await helper.call('status');
    if (r == null || r['ok'] == false) {
      // Keys still work; tell the user why there's no title.
      return MediaStatus(note: helper.lastError ?? "Couldn't start the media helper");
    }
    final json = Map<String, dynamic>.from(r);
    final app = json['app'];
    if (app is String) json['app'] = prettyAppName(app);
    return MediaStatus.fromJson(json);
  }

  @override
  Future<void> perform(MediaAction action, {Duration? position, double? volume}) async {
    switch (action) {
      case MediaAction.seek:
        if (position != null) await helper.call('seek ${position.inMilliseconds}');
        return;
      case MediaAction.setVolume:
        if (volume != null) await helper.call('setVolume ${volume.clamp(0.0, 1.0).toStringAsFixed(3)}');
        return;
      case MediaAction.volumeUp:
      case MediaAction.volumeDown:
        final current = (await status()).volume;
        if (current != null) {
          final next = current + (action == MediaAction.volumeUp ? 0.05 : -0.05);
          final ok = await helper.call('setVolume ${next.clamp(0.0, 1.0).toStringAsFixed(3)}');
          if (ok?['ok'] == true) return;
        }
        _keys.virtualKey(action == MediaAction.volumeUp ? MediaKeys.volumeUp : MediaKeys.volumeDown);
        return;
      default:
        final r = await helper.call(action.name);
        if (r?['ok'] == true) return;
        final vk = switch (action) {
          MediaAction.playPause || MediaAction.play || MediaAction.pause => MediaKeys.playPause,
          MediaAction.next => MediaKeys.next,
          MediaAction.previous => MediaKeys.previous,
          MediaAction.stop => MediaKeys.stop,
          MediaAction.toggleMute => MediaKeys.volumeMute,
          _ => null,
        };
        if (vk != null) _keys.virtualKey(vk);
    }
  }

  @override
  Future<void> dispose() => helper.dispose();
}

/// A long-running `powershell.exe` that answers one JSON line per command.
///
/// On start it prints `{"ready":true,"errors":[...]}` once its set-up is
/// done. Set-up compiles a little C# for the volume API, which can take a
/// while on the first run (or while antivirus scans it), so it gets its own
/// generous timeout.
class PowerShellHelper {
  Process? _process;
  StreamIterator<String>? _lines;
  Future<void> _lock = Future.value();
  int _failures = 0;
  DateTime? _retryAfter;
  final _stderr = <String>[];

  /// Why the last call failed, for the UI and for bug reports.
  String? lastError;

  /// Parts of the set-up that failed but didn't stop the helper, e.g.
  /// "volume: ..." on a PC without speakers.
  List<String> initErrors = const [];

  static const startTimeout = Duration(seconds: 45);
  static const callTimeout = Duration(seconds: 8);

  Future<Map<String, dynamic>?> call(String command) {
    final result = _lock.then((_) => _call(command));
    _lock = result.then((_) {}, onError: (_) {});
    return result;
  }

  Future<Map<String, dynamic>?> _call(String command) async {
    try {
      final lines = await _ensureStarted();
      if (lines == null) return null;
      _process!.stdin.writeln(command);
      await _process!.stdin.flush();
      final reply = jsonDecode(await _nextLine(lines, callTimeout)) as Map<String, dynamic>;
      _failures = 0;
      if (reply['ok'] == false) lastError = reply['error'] as String?;
      return reply;
    } catch (e) {
      lastError = _describe(e);
      await _kill();
      _failures++;
      // Back off if the helper keeps failing (e.g. PowerShell is blocked).
      if (_failures >= 3) _retryAfter = DateTime.now().add(const Duration(minutes: 1));
      return null;
    }
  }

  Future<String> _nextLine(StreamIterator<String> lines, Duration timeout) async {
    if (!await lines.moveNext().timeout(timeout)) throw StateError('the helper exited');
    return lines.current.replaceFirst('﻿', '').trim();
  }

  String _describe(Object e) {
    final detail = _stderr.where((l) => l.trim().isNotEmpty).take(6).join(' ');
    return detail.isEmpty ? '$e' : '$e: $detail';
  }

  Future<StreamIterator<String>?> _ensureStarted() async {
    if (_lines != null) return _lines;
    if (_retryAfter != null && DateTime.now().isBefore(_retryAfter!)) return null;
    _retryAfter = null;
    _stderr.clear();

    final script = File(p.join(Directory.systemTemp.path, 'sidekick_media_v2.ps1'));
    await script.writeAsString(_script);
    final process = await Process.start(
      'powershell.exe',
      ['-NoProfile', '-NonInteractive', '-WindowStyle', 'Hidden', '-ExecutionPolicy', 'Bypass', '-File', script.path],
      // Detached keeps a console window from popping up behind the app while
      // still giving us stdin/stdout.
      mode: ProcessStartMode.detachedWithStdio,
    );
    _process = process;
    process.stderr.transform(utf8.decoder).transform(const LineSplitter()).listen((line) {
      _stderr.add(line);
      if (_stderr.length > 30) _stderr.removeAt(0);
    }, onError: (_) {});
    final lines = StreamIterator(process.stdout.transform(utf8.decoder).transform(const LineSplitter()));

    // Wait for the ready line; anything else means set-up failed.
    final first = await _nextLine(lines, startTimeout);
    final Object? hello;
    try {
      hello = jsonDecode(first);
    } on FormatException {
      throw StateError('unexpected output from the helper: $first');
    }
    if (hello is! Map || hello['ready'] != true) throw StateError('the helper did not start: $first');
    initErrors = [for (final e in (hello['errors'] as List? ?? const [])) '$e'];
    _lines = lines;
    return lines;
  }

  Future<void> _kill() async {
    final lines = _lines;
    _lines = null;
    _process?.kill();
    _process = null;
    await lines?.cancel();
  }

  Future<void> dispose() => _kill();
}

const _script = r'''
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false
$inv = [Globalization.CultureInfo]::InvariantCulture
$initErrors = @()

# --- Media sessions (Windows.Media.Control, the API behind the volume flyout)
$mgr = $null
try {
  Add-Type -AssemblyName System.Runtime.WindowsRuntime
  $asTaskGeneric = ([System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
    $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and
    $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1'
  })[0]
  function Await($op, [Type]$type) {
    $task = $asTaskGeneric.MakeGenericMethod($type).Invoke($null, @($op))
    $null = $task.Wait(5000)
    $task.Result
  }
  $null = [Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager,Windows.Media.Control,ContentType=WindowsRuntime]
  $mgrType = [Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager]
  $propsType = [Windows.Media.Control.GlobalSystemMediaTransportControlsSessionMediaProperties]
  $mgr = Await ($mgrType::RequestAsync()) $mgrType
} catch {
  $mgr = $null
  $initErrors += "media: $($_.Exception.Message)"
}

# --- System volume (Core Audio via a little C#)
$hasVolume = $false
try {
  Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
[Guid("5CDF2C82-841E-4546-9722-0CF74078229A"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IAudioEndpointVolume {
  int f(); int g(); int h(); int i();
  int SetMasterVolumeLevelScalar(float fLevel, Guid pguidEventContext);
  int j();
  int GetMasterVolumeLevelScalar(out float pfLevel);
  int k(); int l(); int m(); int n();
  int SetMute([MarshalAs(UnmanagedType.Bool)] bool bMute, Guid pguidEventContext);
  int GetMute(out bool pbMute);
}
[Guid("D666063F-1587-4E43-81F1-B948E807363F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IMMDevice {
  int Activate(ref Guid id, int clsCtx, int activationParams, out IAudioEndpointVolume aev);
}
[Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IMMDeviceEnumerator {
  int f();
  int GetDefaultAudioEndpoint(int dataFlow, int role, out IMMDevice endpoint);
}
[ComImport, Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")] class MMDeviceEnumeratorComObject { }
public class SidekickAudio {
  static IAudioEndpointVolume Vol() {
    var enumerator = new MMDeviceEnumeratorComObject() as IMMDeviceEnumerator;
    IMMDevice dev = null;
    Marshal.ThrowExceptionForHR(enumerator.GetDefaultAudioEndpoint(0, 1, out dev));
    IAudioEndpointVolume epv = null;
    var epvid = typeof(IAudioEndpointVolume).GUID;
    Marshal.ThrowExceptionForHR(dev.Activate(ref epvid, 23, 0, out epv));
    return epv;
  }
  public static float Volume {
    get { float v = -1; Marshal.ThrowExceptionForHR(Vol().GetMasterVolumeLevelScalar(out v)); return v; }
    set { Marshal.ThrowExceptionForHR(Vol().SetMasterVolumeLevelScalar(value, Guid.Empty)); }
  }
  public static bool Mute {
    get { bool mute; Marshal.ThrowExceptionForHR(Vol().GetMute(out mute)); return mute; }
    set { Marshal.ThrowExceptionForHR(Vol().SetMute(value, Guid.Empty)); }
  }
}
"@
  $hasVolume = $true
} catch {
  $initErrors += "volume: $($_.Exception.Message)"
}

# Prefer the session that's actually playing; Windows' "current" session can
# be a paused app you used earlier.
function Get-Session {
  if ($mgr -eq $null) { throw 'Media sessions are not available on this PC' }
  foreach ($s in $mgr.GetSessions()) {
    if ($s.GetPlaybackInfo().PlaybackStatus.ToString() -eq 'Playing') { return $s }
  }
  $current = $mgr.GetCurrentSession()
  if ($current -eq $null) { throw 'Nothing is playing' }
  return $current
}

function Get-Status {
  $o = @{ ok = $true; available = $false; muted = $false }
  if ($initErrors.Count -gt 0) { $o.note = ($initErrors -join '; ') }
  if ($hasVolume) {
    try { $o.volume = [double][SidekickAudio]::Volume; $o.muted = [SidekickAudio]::Mute } catch {}
  }
  if ($mgr -eq $null) { return $o }
  try { $s = Get-Session } catch { return $o }
  $o.available = $true
  $o.app = $s.SourceAppUserModelId
  try {
    $props = Await ($s.TryGetMediaPropertiesAsync()) $propsType
    $o.title = $props.Title
    $o.artist = $props.Artist
  } catch {}
  $info = $s.GetPlaybackInfo()
  $o.status = switch ($info.PlaybackStatus.ToString()) {
    'Playing' { 'playing' } 'Paused' { 'paused' } 'Stopped' { 'stopped' } default { 'unknown' }
  }
  $o.canSeek = [bool]$info.Controls.IsPlaybackPositionEnabled
  $o.canNext = [bool]$info.Controls.IsNextEnabled
  $o.canPrevious = [bool]$info.Controls.IsPreviousEnabled
  $t = $s.GetTimelineProperties()
  $dur = $t.EndTime - $t.StartTime
  $pos = $t.Position
  if ($o.status -eq 'playing') { $pos = $pos + ([DateTimeOffset]::Now - $t.LastUpdatedTime) }
  if ($dur.TotalMilliseconds -gt 0 -and $pos -gt $dur) { $pos = $dur }
  $o.positionMs = [long]$pos.TotalMilliseconds
  $o.durationMs = [long]$dur.TotalMilliseconds
  return $o
}

function Ok($op) { if (-not (Await $op ([bool]))) { throw 'The app refused the command' } }

[Console]::Out.WriteLine((@{ ready = $true; errors = @($initErrors) } | ConvertTo-Json -Compress))
[Console]::Out.Flush()

while ($true) {
  $line = [Console]::In.ReadLine()
  if ($line -eq $null) { break }
  $parts = $line.Trim().Split(' ', 2)
  $arg = if ($parts.Length -gt 1) { $parts[1] } else { '' }
  $result = @{ ok = $true }
  try {
    switch ($parts[0]) {
      'status'     { $result = Get-Status }
      'playPause'  { Ok ((Get-Session).TryTogglePlayPauseAsync()) }
      'play'       { Ok ((Get-Session).TryPlayAsync()) }
      'pause'      { Ok ((Get-Session).TryPauseAsync()) }
      'next'       { Ok ((Get-Session).TrySkipNextAsync()) }
      'previous'   { Ok ((Get-Session).TrySkipPreviousAsync()) }
      'stop'       { Ok ((Get-Session).TryStopAsync()) }
      'seek'       { Ok ((Get-Session).TryChangePlaybackPositionAsync([long]([double]::Parse($arg, $inv) * 10000))) }
      'setVolume'  { [SidekickAudio]::Volume = [float][double]::Parse($arg, $inv) }
      'toggleMute' { [SidekickAudio]::Mute = -not [SidekickAudio]::Mute }
      default      { throw "Unknown command: $($parts[0])" }
    }
  } catch {
    $result = @{ ok = $false; error = $_.Exception.Message }
  }
  [Console]::Out.WriteLine(($result | ConvertTo-Json -Compress))
  [Console]::Out.Flush()
}
''';

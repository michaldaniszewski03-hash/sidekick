import 'dart:io';

import 'package:flutter/services.dart';
import 'package:mime/mime.dart';
import 'package:path/path.dart' as p;

/// Photos and videos a phone receives go straight to Photos (iPhone) or the
/// gallery (Android), like AirDrop: the native side moves them there
/// (`saveToGallery` on `sidekick/ios` and `sidekick/android`). Everything
/// else stays in the receive folder.
abstract final class Gallery {
  static bool get supported => Platform.isIOS || Platform.isAndroid;

  /// What the phone calls its library, for messages.
  static String get name => Platform.isIOS ? 'Photos' : 'the gallery';

  // What each library can show. iPhone Photos can't play WebM or MKV.
  static const _photos = {'.jpg', '.jpeg', '.png', '.gif', '.heic', '.heif', '.webp', '.dng'};
  static const _videos = {'.mp4', '.mov', '.m4v', '.3gp'};
  static const _androidVideos = {'.webm', '.mkv'};

  /// 'photo', 'video', or null when [path] isn't something the library takes.
  static String? kindOf(String path, {bool android = false}) {
    final ext = p.extension(path).toLowerCase();
    if (_photos.contains(ext)) return 'photo';
    if (_videos.contains(ext) || (android && _androidVideos.contains(ext))) return 'video';
    return null;
  }

  /// Moves [file] into the library. Returns null when it's there, otherwise
  /// why not (the file then stays where it is).
  static Future<String?> save(File file) async {
    final kind = kindOf(file.path, android: Platform.isAndroid);
    if (kind == null) return 'not a photo or video';
    final channel = MethodChannel(Platform.isIOS ? 'sidekick/ios' : 'sidekick/android');
    try {
      await channel.invokeMethod('saveToGallery', {
        'path': file.path,
        'video': kind == 'video',
        'mime': lookupMimeType(file.path) ?? (kind == 'video' ? 'video/mp4' : 'image/jpeg'),
      });
      return null;
    } on PlatformException catch (e) {
      return e.message ?? e.code;
    } on MissingPluginException {
      return 'not supported on this device';
    }
  }
}

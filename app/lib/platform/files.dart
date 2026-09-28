import 'dart:io';

import 'package:path/path.dart' as p;

import '../core/models.dart';

/// Local file-system access used to answer peers' browse requests.
class FileService {
  FileService({String? home}) : _home = home ?? _defaultHome();

  final String _home;

  static String _defaultHome() =>
      Platform.environment['USERPROFILE'] ?? Platform.environment['HOME'] ?? Directory.current.path;

  /// Starting points shown before the peer picks a folder: common user
  /// folders first, then every drive (Windows) or `/` (elsewhere).
  Future<List<RemoteEntry>> roots() async {
    final entries = <RemoteEntry>[];
    for (final name in ['Desktop', 'Documents', 'Downloads', 'Pictures', 'Music', 'Videos']) {
      final dir = Directory(p.join(_home, name));
      if (await dir.exists()) entries.add(RemoteEntry(name: name, path: dir.path, isDir: true));
    }
    entries.add(RemoteEntry(name: 'Home', path: _home, isDir: true));
    if (Platform.isWindows) {
      for (var c = 0x41; c <= 0x5A; c++) {
        final drive = '${String.fromCharCode(c)}:\\';
        if (await Directory(drive).exists()) {
          entries.add(RemoteEntry(name: drive.substring(0, 2), path: drive, isDir: true));
        }
      }
    } else {
      entries.add(const RemoteEntry(name: '/', path: '/', isDir: true));
    }
    return entries;
  }

  /// Lists [path]: folders first, then files, each sorted by name.
  /// Entries we can't stat (permissions, broken links) are skipped.
  Future<List<RemoteEntry>> list(String path) async {
    final dir = Directory(path);
    final entries = <RemoteEntry>[];
    await for (final entity in dir.list(followLinks: false).handleError((_) {})) {
      try {
        final stat = await entity.stat();
        final isDir = stat.type == FileSystemEntityType.directory;
        if (!isDir && stat.type != FileSystemEntityType.file) continue;
        entries.add(
          RemoteEntry(
            name: p.basename(entity.path),
            path: entity.path,
            isDir: isDir,
            size: isDir ? 0 : stat.size,
            modified: stat.modified,
          ),
        );
      } catch (_) {
        // Skip entries we can't read.
      }
    }
    entries.sort((a, b) {
      if (a.isDir != b.isDir) return a.isDir ? -1 : 1;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    return entries;
  }
}

/// Makes a peer-supplied file name safe to write on any OS: no directories,
/// no characters Windows forbids, no reserved device names.
String sanitizeFileName(String name) {
  var base = name.split(RegExp(r'[\\/]')).last;
  base = base.replaceAll(RegExp(r'[<>:"|?*\x00-\x1F]'), '_').trim();
  base = base.replaceAll(RegExp(r'[. ]+$'), '');
  if (base.isEmpty || base == '.' || base == '..') return 'file';
  final stem = base.split('.').first.toUpperCase();
  const reserved = {'CON', 'PRN', 'AUX', 'NUL', 'COM1', 'COM2', 'COM3', 'COM4', 'LPT1', 'LPT2', 'LPT3'};
  if (reserved.contains(stem)) base = '_$base';
  if (base.length > 200) {
    final ext = p.extension(base);
    base = base.substring(0, 200 - ext.length) + ext;
  }
  return base;
}

/// Returns a path in [dir] for [name] that doesn't exist yet, adding
/// " (1)", " (2)", … before the extension if needed.
Future<File> uniqueFile(String dir, String name) async {
  final ext = p.extension(name);
  final stem = p.basenameWithoutExtension(name);
  var candidate = File(p.join(dir, name));
  for (var i = 1; await candidate.exists(); i++) {
    candidate = File(p.join(dir, '$stem ($i)$ext'));
  }
  return candidate;
}

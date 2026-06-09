import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'models.dart';

class DeviceWatcher {
  DeviceWatcher({Duration pollInterval = const Duration(seconds: 2)})
    : _pollInterval = pollInterval;

  final Duration _pollInterval;
  Timer? _timer;

  final _controller = StreamController<List<DetectedVolume>>.broadcast();

  Stream<List<DetectedVolume>> get volumes => _controller.stream;

  void start() {
    _timer?.cancel();
    _scan();
    _timer = Timer.periodic(_pollInterval, (_) => _scan());
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  void dispose() {
    stop();
    _controller.close();
  }

  Future<List<DetectedVolume>> scanNow() => _readMountedVolumes();

  Future<void> _scan() async {
    try {
      _controller.add(await _readMountedVolumes());
    } catch (error, stackTrace) {
      _controller.addError(error, stackTrace);
    }
  }

  Future<List<DetectedVolume>> _readMountedVolumes() async {
    final mounts = await _readProcMounts();
    final byIdentity = <String, DetectedVolume>{};
    for (final volume in mounts) {
      if (volume.isBootloader || volume.isPicodisk) {
        byIdentity[volume.identity] = volume;
      }
    }

    for (final volume in await _readLsblkVolumes()) {
      byIdentity[volume.identity] = volume;
    }

    for (final root in _candidateRoots()) {
      final dir = Directory(root);
      if (!await dir.exists()) continue;
      try {
        await for (final entity in dir.list(followLinks: false)) {
          if (entity is! Directory) continue;
          final label = _basename(entity.path);
          final volume = DetectedVolume(
            source: entity.path,
            mountPath: entity.path,
            label: label,
          );
          if (!volume.isBootloader && !volume.isPicodisk) continue;
          if (byIdentity.values.any(
            (existing) => existing.mountPath == volume.mountPath,
          )) {
            continue;
          }
          byIdentity.putIfAbsent(volume.identity, () => volume);
        }
      } on FileSystemException {
        continue;
      }
    }

    return byIdentity.values.toList()
      ..sort((a, b) => a.location.compareTo(b.location));
  }

  Future<List<DetectedVolume>> _readProcMounts() async {
    final file = File('/proc/mounts');
    if (!await file.exists()) return const [];
    final lines = await file.readAsLines();
    return lines.map(_parseMountLine).whereType<DetectedVolume>().toList();
  }

  DetectedVolume? _parseMountLine(String line) {
    final fields = line.split(' ');
    if (fields.length < 2) return null;
    final source = _unescapeMountField(fields[0]);
    final mountPath = _unescapeMountField(fields[1]);
    final label = _basename(mountPath);
    return DetectedVolume(
      source: source,
      mountPath: mountPath,
      label: label,
      devicePath: source.startsWith('/dev/') ? source : null,
    );
  }

  Future<List<DetectedVolume>> _readLsblkVolumes() async {
    try {
      final result = await Process.run('lsblk', const [
        '-J',
        '-o',
        'NAME,PATH,LABEL,MOUNTPOINTS,FSTYPE,TRAN,RM,MODEL',
      ]);
      if (result.exitCode != 0) return const [];
      final decoded =
          jsonDecode(result.stdout as String) as Map<String, Object?>;
      final devices = decoded['blockdevices'] as List<dynamic>? ?? const [];
      return devices
          .whereType<Map<String, Object?>>()
          .expand(_volumesFromLsblkNode)
          .toList();
    } catch (_) {
      return const [];
    }
  }

  Iterable<DetectedVolume> _volumesFromLsblkNode(
    Map<String, Object?> node,
  ) sync* {
    final children = node['children'] as List<dynamic>? ?? const [];
    if (children.isNotEmpty) {
      for (final child in children.whereType<Map<String, Object?>>()) {
        yield* _volumesFromLsblkNode(child);
      }
      return;
    }

    final label = node['label'] as String?;
    final model = node['model'] as String?;
    final path = node['path'] as String?;
    final mountPath = _firstMountPath(node['mountpoints']);
    final effectiveLabel = _nonEmpty(label) ?? _nonEmpty(model);
    if (path != null && effectiveLabel != null) {
      final volume = DetectedVolume(
        source: path,
        mountPath: mountPath ?? '',
        label: effectiveLabel,
        devicePath: path,
      );
      if (volume.isBootloader || volume.isPicodisk) yield volume;
    }
  }

  String? _firstMountPath(Object? value) {
    if (value is String && value.isNotEmpty) return value;
    if (value is List) {
      for (final item in value) {
        if (item is String && item.isNotEmpty && !item.startsWith('[')) {
          return item;
        }
      }
    }
    return null;
  }

  String? _nonEmpty(String? value) {
    final trimmed = value?.trim();
    return trimmed == null || trimmed.isEmpty ? null : trimmed;
  }

  List<String> _candidateRoots() {
    final user = Platform.environment['USER'];
    return [
      if (user != null && user.isNotEmpty) '/media/$user',
      if (user != null && user.isNotEmpty) '/run/media/$user',
      '/media',
      '/run/media',
      '/mnt',
    ];
  }

  String _basename(String path) {
    final trimmed = path.endsWith('/') && path.length > 1
        ? path.substring(0, path.length - 1)
        : path;
    final index = trimmed.lastIndexOf('/');
    return index == -1 ? trimmed : trimmed.substring(index + 1);
  }

  String _unescapeMountField(String value) {
    return value
        .replaceAll(r'\040', ' ')
        .replaceAll(r'\011', '\t')
        .replaceAll(r'\012', '\n')
        .replaceAll(r'\134', r'\');
  }
}

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'models.dart';

class DeviceWatcher {
  DeviceWatcher({
    Duration pollInterval = const Duration(seconds: 2),
    void Function(String message)? onLog,
  }) : _pollInterval = pollInterval,
       _onLog = onLog;

  final Duration _pollInterval;
  final void Function(String message)? _onLog;
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

  Future<List<DetectedVolume>> scanNow({bool verbose = false}) =>
      _readMountedVolumes(verbose: verbose, deep: true);

  Future<void> _scan() async {
    try {
      _controller.add(await _readMountedVolumes());
    } catch (error, stackTrace) {
      _controller.addError(error, stackTrace);
    }
  }

  Future<List<DetectedVolume>> _readMountedVolumes({
    bool verbose = false,
    bool deep = false,
  }) async {
    _debug(verbose, 'Device scan started on ${Platform.operatingSystem}.');
    final mounts = await _readProcMounts(verbose: verbose);
    final byIdentity = <String, DetectedVolume>{};
    for (final volume in mounts) {
      _addIfXrp(byIdentity, volume, verbose: verbose);
    }

    for (final volume in await _readLsblkVolumes(verbose: verbose)) {
      _addIfXrp(byIdentity, volume, verbose: verbose);
    }

    if (Platform.isWindows) {
      if (deep) {
        for (final volume in await _readWindowsPowerShellVolumes(
          verbose: verbose,
        )) {
          _addIfXrp(byIdentity, volume, verbose: verbose);
        }
        for (final volume in await _readWindowsWmicVolumes(verbose: verbose)) {
          _addIfXrp(byIdentity, volume, verbose: verbose);
        }
      } else {
        _debug(
          verbose,
          'PowerShell and wmic scans skipped during lightweight polling.',
        );
      }
      for (final volume in await _probeWindowsDriveLetters(verbose: verbose)) {
        _addIfXrp(byIdentity, volume, verbose: verbose);
      }
    }

    for (final root in _candidateRoots()) {
      final dir = Directory(root);
      if (!await dir.exists()) {
        _debug(verbose, 'Mount-root scan skipped missing $root.');
        continue;
      }
      var scanned = 0;
      try {
        await for (final entity in dir.list(followLinks: false)) {
          if (entity is! Directory) continue;
          scanned++;
          final label = _basename(entity.path);
          final volume = await _volumeFromPath(
            source: entity.path,
            mountPath: entity.path,
            label: label,
            detectionMethod: 'mount-root:$root',
            verbose: verbose,
          );
          _addIfXrp(byIdentity, volume, verbose: verbose);
        }
      } on FileSystemException {
        _debug(verbose, 'Mount-root scan could not list $root.');
        continue;
      }
      _debug(verbose, 'Mount-root scan checked $scanned entries under $root.');
    }

    final volumes = byIdentity.values.toList()
      ..sort((a, b) => a.location.compareTo(b.location));
    _debug(
      verbose,
      volumes.isEmpty
          ? 'Device scan finished: no XRP volumes matched.'
          : 'Device scan finished: ${volumes.length} XRP volume(s): '
                '${volumes.map(_describeVolume).join('; ')}.',
    );
    return volumes;
  }

  Future<List<DetectedVolume>> _readProcMounts({bool verbose = false}) async {
    final file = File('/proc/mounts');
    if (!await file.exists()) {
      _debug(verbose, '/proc/mounts scan skipped; file is not present.');
      return const [];
    }
    final lines = await file.readAsLines();
    final volumes = lines
        .map(_parseMountLine)
        .whereType<DetectedVolume>()
        .toList();
    _debug(verbose, '/proc/mounts scan checked ${volumes.length} mounts.');
    return volumes;
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
      detectionMethod: '/proc/mounts',
    );
  }

  Future<List<DetectedVolume>> _readLsblkVolumes({bool verbose = false}) async {
    if (!Platform.isLinux) {
      _debug(verbose, 'lsblk scan skipped on ${Platform.operatingSystem}.');
      return const [];
    }
    try {
      final result = await Process.run('lsblk', const [
        '-J',
        '-o',
        'NAME,PATH,LABEL,MOUNTPOINTS,FSTYPE,TRAN,RM,MODEL',
      ]);
      if (result.exitCode != 0) {
        _debug(verbose, 'lsblk scan failed with exit ${result.exitCode}.');
        return const [];
      }
      final decoded =
          jsonDecode(result.stdout as String) as Map<String, Object?>;
      final devices = decoded['blockdevices'] as List<dynamic>? ?? const [];
      final volumes = devices
          .whereType<Map<String, Object?>>()
          .expand(_volumesFromLsblkNode)
          .toList();
      _debug(
        verbose,
        'lsblk scan found ${volumes.length} candidate volume(s).',
      );
      return volumes;
    } catch (_) {
      _debug(verbose, 'lsblk scan failed; command is unavailable or invalid.');
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
        detectionMethod: 'lsblk',
      );
      if (volume.isBootloader || volume.isPicodisk) yield volume;
    }
  }

  Future<List<DetectedVolume>> _readWindowsPowerShellVolumes({
    bool verbose = false,
  }) async {
    final command = [
      r'$volumes = Get-Volume | Where-Object { $_.DriveLetter -ne $null } |',
      r'Select-Object DriveLetter,FileSystemLabel,DriveType,FileSystemType;',
      r'$volumes | ConvertTo-Json -Compress',
    ].join(' ');
    ProcessResult result;
    try {
      result = await Process.run('powershell.exe', [
        '-NoProfile',
        '-ExecutionPolicy',
        'Bypass',
        '-Command',
        command,
      ]);
    } catch (_) {
      _debug(
        verbose,
        'PowerShell Get-Volume scan skipped; powershell.exe failed.',
      );
      return const [];
    }
    if (result.exitCode != 0) {
      _debug(
        verbose,
        'PowerShell Get-Volume scan failed with exit ${result.exitCode}.',
      );
      return const [];
    }
    final text = (result.stdout as String).trim();
    if (text.isEmpty) {
      _debug(verbose, 'PowerShell Get-Volume scan returned no volumes.');
      return const [];
    }
    try {
      final decoded = jsonDecode(text);
      final rows = decoded is List ? decoded : [decoded];
      final volumes = <DetectedVolume>[];
      for (final row in rows.whereType<Map>()) {
        final letter = '${row['DriveLetter'] ?? ''}'.trim();
        if (letter.isEmpty) continue;
        final root = '$letter:\\';
        final label = _nonEmpty('${row['FileSystemLabel'] ?? ''}') ?? letter;
        volumes.add(
          await _volumeFromPath(
            source: root,
            mountPath: root,
            label: label,
            detectionMethod: 'powershell:Get-Volume',
            verbose: verbose,
          ),
        );
      }
      _debug(
        verbose,
        'PowerShell Get-Volume scan checked ${volumes.length} drive(s).',
      );
      return volumes;
    } catch (_) {
      _debug(verbose, 'PowerShell Get-Volume scan returned invalid JSON.');
      return const [];
    }
  }

  Future<List<DetectedVolume>> _readWindowsWmicVolumes({
    bool verbose = false,
  }) async {
    ProcessResult result;
    try {
      result = await Process.run('wmic', const [
        'logicaldisk',
        'get',
        'DeviceID,DriveType,VolumeName',
        '/format:csv',
      ]);
    } catch (_) {
      _debug(verbose, 'wmic logicaldisk scan skipped; wmic failed.');
      return const [];
    }
    if (result.exitCode != 0) {
      _debug(
        verbose,
        'wmic logicaldisk scan failed with exit ${result.exitCode}.',
      );
      return const [];
    }
    final volumes = <DetectedVolume>[];
    for (final line in (result.stdout as String).split(RegExp(r'\r?\n'))) {
      final trimmed = line.trim();
      if (trimmed.isEmpty || trimmed.startsWith('Node,')) continue;
      final fields = trimmed.split(',');
      if (fields.length < 4) continue;
      final deviceId = fields[1].trim();
      final driveType = fields[2].trim();
      final label = fields.sublist(3).join(',').trim();
      if (deviceId.length < 2) continue;
      if (driveType != '2' && !_isXrpLabel(label)) continue;
      final root = '${deviceId[0]}:\\';
      volumes.add(
        await _volumeFromPath(
          source: root,
          mountPath: root,
          label: _nonEmpty(label) ?? deviceId[0],
          detectionMethod: 'wmic:logicaldisk',
          verbose: verbose,
        ),
      );
    }
    _debug(
      verbose,
      'wmic logicaldisk scan checked ${volumes.length} drive(s).',
    );
    return volumes;
  }

  Future<List<DetectedVolume>> _probeWindowsDriveLetters({
    bool verbose = false,
  }) async {
    final volumes = <DetectedVolume>[];
    for (var code = 'A'.codeUnitAt(0); code <= 'Z'.codeUnitAt(0); code++) {
      final letter = String.fromCharCode(code);
      final root = '$letter:\\';
      if (!await Directory(root).exists()) continue;
      final label = await _windowsVolumeLabel(root, verbose: verbose);
      volumes.add(
        await _volumeFromPath(
          source: root,
          mountPath: root,
          label: _nonEmpty(label) ?? letter,
          detectionMethod: 'drive-letter:vol',
          verbose: verbose,
        ),
      );
    }
    _debug(
      verbose,
      'Drive-letter probe checked ${volumes.length} existing drive root(s).',
    );
    return volumes;
  }

  Future<String?> _windowsVolumeLabel(
    String root, {
    bool verbose = false,
  }) async {
    try {
      final result = await Process.run('cmd.exe', ['/c', 'vol', root]);
      if (result.exitCode != 0) return null;
      final output = result.stdout as String;
      final match = RegExp(
        r'Volume in drive [A-Z] is (.+)',
        caseSensitive: false,
      ).firstMatch(output);
      final label = match?.group(1)?.trim();
      return label == null || label == 'has no label.' ? null : label;
    } catch (_) {
      _debug(verbose, 'vol label probe failed for $root.');
      return null;
    }
  }

  Future<DetectedVolume> _volumeFromPath({
    required String source,
    required String mountPath,
    required String label,
    String? devicePath,
    String? detectionMethod,
    bool verbose = false,
  }) async {
    await _diagnosePathAccess(mountPath, verbose: verbose);
    final markerLabel = await _markerLabel(mountPath);
    return DetectedVolume(
      source: source,
      mountPath: mountPath,
      label: markerLabel ?? label,
      devicePath: devicePath,
      detectionMethod: markerLabel == null
          ? detectionMethod
          : detectionMethod == null
          ? 'marker'
          : '$detectionMethod+marker',
    );
  }

  Future<String?> _markerLabel(String path) async {
    if (path.isEmpty) return null;
    if (await File(_joinPath(path, 'xrp-status.txt')).exists() ||
        await File(_joinPath(path, 'status.txt')).exists()) {
      return 'PICODISK';
    }
    final info = File(_joinPath(path, 'INFO_UF2.TXT'));
    if (!await info.exists()) return null;
    try {
      final text = await info.readAsString();
      final normalized = text.toUpperCase();
      if (normalized.contains('RP2350')) return 'RP2350';
      if (normalized.contains('RPI-RP2') ||
          normalized.contains('RP2040') ||
          normalized.contains('UF2 BOOTLOADER')) {
        return 'RPI-RP2';
      }
    } catch (_) {
      return 'RPI-RP2';
    }
    return 'RPI-RP2';
  }

  Future<void> _diagnosePathAccess(String path, {bool verbose = false}) async {
    if (!verbose || path.isEmpty) return;
    try {
      final dir = Directory(path);
      if (!await dir.exists()) {
        _debug(verbose, 'Access check: $path does not exist.');
        return;
      }
      final iterator = dir.list(followLinks: false);
      await iterator.take(1).drain<void>();
      _debug(
        verbose,
        'Access check passed for $path: app can list the volume root.',
      );
    } on FileSystemException catch (error) {
      _debug(
        verbose,
        'Access check failed for $path: ${error.message}. This can be a permission or disconnected-volume issue.',
      );
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

  void _addIfXrp(
    Map<String, DetectedVolume> byIdentity,
    DetectedVolume volume, {
    bool verbose = false,
  }) {
    if (!volume.isBootloader && !volume.isPicodisk) {
      _debug(
        verbose,
        'Ignored ${volume.location} label "${volume.label}" '
        'via ${volume.detectionMethod ?? 'unknown method'}.',
      );
      return;
    }
    if (byIdentity.values.any(
      (existing) =>
          existing.mountPath.isNotEmpty &&
          existing.mountPath == volume.mountPath,
    )) {
      _debug(
        verbose,
        'Duplicate ${volume.location} from ${volume.detectionMethod}; already recorded.',
      );
      return;
    }
    final existing = byIdentity[volume.identity];
    if (existing != null && existing.isMounted && !volume.isMounted) return;
    byIdentity[volume.identity] = volume;
    _debug(verbose, 'Matched XRP volume: ${_describeVolume(volume)}.');
  }

  bool _isXrpLabel(String label) {
    final volume = DetectedVolume(source: '', mountPath: '', label: label);
    return volume.isBootloader || volume.isPicodisk;
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
    final trimmed =
        (path.endsWith('/') || path.endsWith(r'\')) && path.length > 1
        ? path.substring(0, path.length - 1)
        : path;
    final index = trimmed.lastIndexOf(RegExp(r'[/\\]'));
    return index == -1 ? trimmed : trimmed.substring(index + 1);
  }

  String _joinPath(String directory, String name) {
    if (directory.endsWith('/') || directory.endsWith(r'\')) {
      return '$directory$name';
    }
    return '$directory${Platform.pathSeparator}$name';
  }

  String _describeVolume(DetectedVolume volume) {
    return '${volume.label} at ${volume.location}'
        '${volume.detectionMethod == null ? '' : ' via ${volume.detectionMethod}'}';
  }

  void _debug(bool verbose, String message) {
    if (verbose) _onLog?.call(message);
  }

  String _unescapeMountField(String value) {
    return value
        .replaceAll(r'\040', ' ')
        .replaceAll(r'\011', '\t')
        .replaceAll(r'\012', '\n')
        .replaceAll(r'\134', r'\');
  }
}

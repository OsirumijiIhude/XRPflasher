import 'dart:convert';
import 'dart:io';

import 'models.dart';
import 'status_parser.dart';

class FirmwareRelease {
  const FirmwareRelease({
    required this.tagName,
    required this.name,
    required this.assets,
  });

  final String tagName;
  final String name;
  final List<FirmwareAsset> assets;

  List<FirmwareAsset> get uf2Assets => assets
      .where((asset) => asset.name.toLowerCase().endsWith('.uf2'))
      .toList();
}

class FirmwareAsset {
  const FirmwareAsset({required this.name, required this.downloadUrl});

  final String name;
  final String downloadUrl;
}

class FirmwareManager {
  FirmwareManager({String? defaultFirmwarePath, HttpClient? httpClient})
    : defaultFirmwarePath = defaultFirmwarePath ?? _defaultFirmwarePath(),
      _httpClient = httpClient ?? HttpClient();

  static const bundledFirmwareName = 'xrp-wpilib-firmware-2.1.0-aa439f0.uf2';

  final String defaultFirmwarePath;
  final HttpClient _httpClient;

  static String _defaultFirmwarePath() {
    for (final candidate in _defaultFirmwareCandidates(bundledFirmwareName)) {
      if (File(candidate).existsSync()) return candidate;
    }
    return bundledFirmwareName;
  }

  static Iterable<String> _defaultFirmwareCandidates(String fileName) sync* {
    yield _join([Directory.current.path, fileName]);

    final executableDirectory = _executableDirectory();
    if (executableDirectory == null) return;

    yield _join([executableDirectory, fileName]);
    yield _join([executableDirectory, 'data', 'flutter_assets', fileName]);
    yield _join([
      executableDirectory,
      '..',
      'data',
      'flutter_assets',
      fileName,
    ]);
    yield _join([
      executableDirectory,
      '..',
      'Resources',
      'flutter_assets',
      fileName,
    ]);
  }

  static String? _executableDirectory() {
    final executable = Platform.resolvedExecutable;
    if (executable.isEmpty) return null;
    return File(executable).parent.path;
  }

  static String _join(Iterable<String> parts) =>
      parts.join(Platform.pathSeparator);

  Future<DetectedVolume> flash({
    required DetectedVolume bootloader,
    required String firmwarePath,
  }) async {
    final mountedBootloader = await ensureMounted(bootloader);
    final source = File(firmwarePath);
    if (!await source.exists()) {
      throw StateError('Firmware file not found: $firmwarePath');
    }
    final target = File(
      '${mountedBootloader.mountPath}/${_basename(firmwarePath)}',
    );
    await source.copy(target.path);
    await Process.run('sync', const []);
    return mountedBootloader;
  }

  Future<XrpStatus> readStatus(DetectedVolume picodisk) async {
    final mountedPicodisk = await ensureMounted(picodisk);
    final statusFile = await findStatusFile(mountedPicodisk);
    if (statusFile == null) {
      throw StateError(
        'No XRP status file found in ${mountedPicodisk.location}',
      );
    }
    return const XrpStatusParser().parse(await statusFile.readAsString());
  }

  Future<DetectedVolume> ensureMounted(DetectedVolume volume) async {
    if (volume.isMounted) return volume;
    final devicePath = volume.devicePath ?? volume.source;
    if (!devicePath.startsWith('/dev/')) {
      throw StateError('Cannot mount ${volume.label}: no block device path.');
    }

    final result = await Process.run('udisksctl', ['mount', '-b', devicePath]);
    if (result.exitCode != 0) {
      throw ProcessException(
        'udisksctl',
        ['mount', '-b', devicePath],
        '${result.stderr}\n${result.stdout}'.trim(),
        result.exitCode,
      );
    }

    final mountPath =
        _parseUdisksMountPath('${result.stdout}\n${result.stderr}') ??
        await _findMountedPathForDevice(devicePath) ??
        await _findMountedPathForLabel(volume.label);
    if (mountPath == null) {
      throw StateError('Mounted $devicePath, but no mount path was reported.');
    }
    return volume.copyWith(mountPath: mountPath, source: devicePath);
  }

  Future<File?> findStatusFile(DetectedVolume picodisk) async {
    final root = Directory(picodisk.mountPath);
    if (!await root.exists()) return null;
    await for (final entity in root.list(followLinks: false)) {
      if (entity is File && _isStatusName(_basename(entity.path))) {
        return entity;
      }
    }
    return null;
  }

  Future<String?> _findMountedPathForDevice(String devicePath) async {
    final file = File('/proc/mounts');
    if (!await file.exists()) return null;
    final lines = await file.readAsLines();
    for (final line in lines) {
      final fields = line.split(' ');
      if (fields.length < 2) continue;
      if (_unescapeMountField(fields[0]) == devicePath) {
        return _unescapeMountField(fields[1]);
      }
    }
    return null;
  }

  Future<String?> _findMountedPathForLabel(String label) async {
    final user = Platform.environment['USER'];
    final paths = [
      if (user != null && user.isNotEmpty) '/run/media/$user/$label',
      if (user != null && user.isNotEmpty) '/media/$user/$label',
      '/run/media/$label',
      '/media/$label',
      '/mnt/$label',
    ];
    for (final path in paths) {
      if (await Directory(path).exists()) return path;
    }
    return null;
  }

  Future<FirmwareRelease> fetchLatestRelease() async {
    final uri = Uri.parse(
      'https://api.github.com/repos/wpilibsuite/xrp-wpilib-firmware/releases/latest',
    );
    final request = await _httpClient.getUrl(uri);
    request.headers.set(HttpHeaders.userAgentHeader, 'xrp-flasher');
    final response = await request.close();
    final body = await response.transform(utf8.decoder).join();
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw HttpException(
        'GitHub release lookup failed: ${response.statusCode} $body',
      );
    }
    final json = jsonDecode(body) as Map<String, Object?>;
    final assets = (json['assets'] as List<dynamic>? ?? const [])
        .whereType<Map<String, Object?>>()
        .map(
          (asset) => FirmwareAsset(
            name: asset['name'] as String? ?? 'unknown.uf2',
            downloadUrl: asset['browser_download_url'] as String? ?? '',
          ),
        )
        .where((asset) => asset.downloadUrl.isNotEmpty)
        .toList();
    return FirmwareRelease(
      tagName: json['tag_name'] as String? ?? 'unknown',
      name: json['name'] as String? ?? 'unknown',
      assets: assets,
    );
  }

  bool _isStatusName(String name) {
    final normalized = name.toLowerCase();
    return normalized == 'xrp-status.txt' || normalized == 'status.txt';
  }

  String _basename(String path) {
    final index = path.lastIndexOf(Platform.pathSeparator);
    if (index == -1) return path;
    return path.substring(index + 1);
  }

  String? _parseUdisksMountPath(String output) {
    final match = RegExp(r'\bat\s+(.+?)[.\s]*$').firstMatch(output.trim());
    return match?.group(1)?.trim();
  }

  String _unescapeMountField(String value) {
    return value
        .replaceAll(r'\040', ' ')
        .replaceAll(r'\011', '\t')
        .replaceAll(r'\012', '\n')
        .replaceAll(r'\134', r'\');
  }
}

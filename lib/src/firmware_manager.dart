import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

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

class FirmwareDownloadProgress {
  const FirmwareDownloadProgress({
    required this.message,
    required this.receivedBytes,
    this.totalBytes,
    this.done = false,
  });

  final String message;
  final int receivedBytes;
  final int? totalBytes;
  final bool done;

  double? get fraction {
    final total = totalBytes;
    if (total == null || total <= 0) return null;
    return receivedBytes / total;
  }
}

class FirmwareDownloadResult {
  const FirmwareDownloadResult({
    required this.path,
    required this.bytes,
    required this.blockCount,
  });

  final String path;
  final int bytes;
  final int blockCount;
}

class FirmwareVerificationResult {
  const FirmwareVerificationResult({
    required this.bytes,
    required this.blockCount,
  });

  final int bytes;
  final int blockCount;
}

class FirmwareManager {
  FirmwareManager({
    String? defaultFirmwarePath,
    HttpClient? httpClient,
    void Function(String message)? onLog,
  }) : _onLog = onLog,
       defaultFirmwarePath = defaultFirmwarePath ?? _defaultFirmwarePath(),
       _httpClient = httpClient ?? HttpClient();

  static const bundledFirmwareName = 'xrp-wpilib-firmware-2.1.0-aa439f0.uf2';
  static const networkFirmwareUrl =
      'https://github.com/wpilibsuite/xrp-wpilib-firmware/releases/download/v2.1.0/xrp-wpilib-firmware-2.1.0-aa439f0.uf2';

  final String defaultFirmwarePath;
  final HttpClient _httpClient;
  final void Function(String message)? _onLog;

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
    await verifyUf2File(source.path);
    final target = File(
      _joinPath(mountedBootloader.mountPath, _basename(firmwarePath)),
    );
    _log('Copying firmware to ${target.path}.');
    try {
      await source.copy(target.path);
    } on FileSystemException catch (error) {
      throw FileSystemException(
        'Could not copy firmware. This can be a permission or read-only-volume issue; confirm the drive is writable and not blocked by OS policy. ${error.message}',
        error.path,
        error.osError,
      );
    }
    await _flushFileSystems();
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
    if (volume.isMounted) {
      _log('${volume.label} is already mounted at ${volume.mountPath}.');
      return volume;
    }
    if (Platform.isWindows) {
      throw StateError(
        'Cannot mount ${volume.label}: Windows detection did not report a drive letter.',
      );
    }
    final devicePath = volume.devicePath ?? volume.source;
    if (!devicePath.startsWith('/dev/')) {
      throw StateError('Cannot mount ${volume.label}: no block device path.');
    }

    _log('Mounting ${volume.label} from $devicePath with udisksctl.');
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
    try {
      await for (final entity in root.list(followLinks: false)) {
        if (entity is File && _isStatusName(_basename(entity.path))) {
          return entity;
        }
      }
    } on FileSystemException catch (error) {
      throw FileSystemException(
        'Could not list ${picodisk.location}. This can be a permission issue or a disconnected volume. ${error.message}',
        error.path,
        error.osError,
      );
    }
    return null;
  }

  Future<FirmwareDownloadResult> downloadNetworkFirmware({
    void Function(FirmwareDownloadProgress progress)? onProgress,
  }) async {
    final targetDirectory = await _defaultFirmwareDownloadDirectory();
    await targetDirectory.create(recursive: true);
    final target = File(_joinPath(targetDirectory.path, bundledFirmwareName));
    final partial = File('${target.path}.download');
    final uri = Uri.parse(networkFirmwareUrl);

    onProgress?.call(
      const FirmwareDownloadProgress(
        message: 'Starting firmware download...',
        receivedBytes: 0,
      ),
    );
    _log('Downloading firmware from $networkFirmwareUrl.');

    final request = await _httpClient.getUrl(uri);
    request.headers.set(HttpHeaders.userAgentHeader, 'xrp-flasher');
    final response = await request.close();
    if (response.statusCode < 200 || response.statusCode >= 300) {
      final body = await response.transform(utf8.decoder).join();
      throw HttpException(
        'Firmware download failed: HTTP ${response.statusCode} $body',
        uri: uri,
      );
    }

    final expectedLength = response.contentLength >= 0
        ? response.contentLength
        : null;
    var received = 0;
    final sink = partial.openWrite();
    try {
      await for (final chunk in response) {
        received += chunk.length;
        sink.add(chunk);
        onProgress?.call(
          FirmwareDownloadProgress(
            message: _downloadProgressMessage(received, expectedLength),
            receivedBytes: received,
            totalBytes: expectedLength,
          ),
        );
      }
    } finally {
      await sink.flush();
      await sink.close();
    }

    if (expectedLength != null && received != expectedLength) {
      throw StateError(
        'Firmware download incomplete: received $received of $expectedLength bytes.',
      );
    }

    final verification = await verifyUf2File(
      partial.path,
      expectedLength: expectedLength,
    );
    if (await target.exists()) await target.delete();
    await partial.rename(target.path);

    onProgress?.call(
      FirmwareDownloadProgress(
        message:
            'Firmware verified and ready: ${target.path} (${verification.blockCount} UF2 blocks).',
        receivedBytes: verification.bytes,
        totalBytes: verification.bytes,
        done: true,
      ),
    );
    _log(
      'Firmware verified on disk: ${target.path}, ${verification.bytes} bytes, ${verification.blockCount} UF2 blocks.',
    );
    return FirmwareDownloadResult(
      path: target.path,
      bytes: verification.bytes,
      blockCount: verification.blockCount,
    );
  }

  Future<FirmwareVerificationResult> verifyUf2File(
    String path, {
    int? expectedLength,
  }) async {
    final file = File(path);
    if (!await file.exists()) {
      throw StateError('Firmware file not found after download: $path');
    }
    final bytes = await file.readAsBytes();
    if (expectedLength != null && bytes.length != expectedLength) {
      throw StateError(
        'Firmware size mismatch: expected $expectedLength bytes but found ${bytes.length}.',
      );
    }
    if (bytes.isEmpty || bytes.length % 512 != 0) {
      throw StateError(
        'Firmware is not a valid UF2 file: size ${bytes.length} is not a nonzero multiple of 512.',
      );
    }

    final data = ByteData.sublistView(bytes);
    int? expectedBlocks;
    for (var offset = 0; offset < bytes.length; offset += 512) {
      final blockNumber = offset ~/ 512;
      final magic0 = data.getUint32(offset, Endian.little);
      final magic1 = data.getUint32(offset + 4, Endian.little);
      final payloadSize = data.getUint32(offset + 16, Endian.little);
      final blockNo = data.getUint32(offset + 20, Endian.little);
      final numBlocks = data.getUint32(offset + 24, Endian.little);
      final magicEnd = data.getUint32(offset + 508, Endian.little);
      if (magic0 != 0x0a324655 ||
          magic1 != 0x9e5d5157 ||
          magicEnd != 0x0ab16f30) {
        throw StateError(
          'Firmware UF2 validation failed at block $blockNumber: bad magic values.',
        );
      }
      if (payloadSize == 0 || payloadSize > 476) {
        throw StateError(
          'Firmware UF2 validation failed at block $blockNumber: invalid payload size $payloadSize.',
        );
      }
      expectedBlocks ??= numBlocks;
      if (numBlocks != expectedBlocks) {
        throw StateError(
          'Firmware UF2 validation failed at block $blockNumber: inconsistent block count.',
        );
      }
      if (blockNo >= numBlocks) {
        throw StateError(
          'Firmware UF2 validation failed at block $blockNumber: invalid block number $blockNo of $numBlocks.',
        );
      }
    }

    final blockCount = bytes.length ~/ 512;
    if (expectedBlocks != null && expectedBlocks > blockCount) {
      throw StateError(
        'Firmware UF2 validation failed: file has $blockCount blocks but declares $expectedBlocks.',
      );
    }
    return FirmwareVerificationResult(
      bytes: bytes.length,
      blockCount: blockCount,
    );
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

  Future<Directory> _defaultFirmwareDownloadDirectory() async {
    final home =
        Platform.environment['HOME'] ??
        Platform.environment['USERPROFILE'] ??
        Directory.current.path;
    return Directory(_joinPath(_joinPath(home, 'XRPFlasher'), 'firmware'));
  }

  String _downloadProgressMessage(int received, int? total) {
    if (total == null || total <= 0) {
      return 'Downloaded ${_formatBytes(received)}...';
    }
    final percent = (received / total * 100).clamp(0, 100).toStringAsFixed(0);
    return 'Downloaded $percent% (${_formatBytes(received)} of ${_formatBytes(total)}).';
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    final kib = bytes / 1024;
    if (kib < 1024) return '${kib.toStringAsFixed(1)} KiB';
    return '${(kib / 1024).toStringAsFixed(1)} MiB';
  }

  bool _isStatusName(String name) {
    final normalized = name.toLowerCase();
    return normalized == 'xrp-status.txt' || normalized == 'status.txt';
  }

  String _basename(String path) {
    final index = path.lastIndexOf(RegExp(r'[/\\]'));
    if (index == -1) return path;
    return path.substring(index + 1);
  }

  String _joinPath(String directory, String name) {
    if (directory.endsWith('/') || directory.endsWith(r'\')) {
      return '$directory$name';
    }
    return '$directory${Platform.pathSeparator}$name';
  }

  Future<void> _flushFileSystems() async {
    if (Platform.isWindows) {
      _log('Skipping Linux sync command on Windows; file copy completed.');
      return;
    }
    try {
      final result = await Process.run('sync', const []);
      if (result.exitCode == 0) {
        _log('Filesystem sync completed.');
      } else {
        _log('Filesystem sync exited with ${result.exitCode}; continuing.');
      }
    } catch (_) {
      _log('Filesystem sync command is unavailable; continuing after copy.');
    }
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

  void _log(String message) => _onLog?.call(message);
}

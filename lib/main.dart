import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'src/device_watcher.dart';
import 'src/firmware_manager.dart';
import 'src/models.dart';
import 'src/record_store.dart';
import 'src/xrp_config_service.dart';

void main() {
  runApp(const XrpFlasherApp());
}

class XrpFlasherApp extends StatelessWidget {
  const XrpFlasherApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'XRP Flasher',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xff197278),
          brightness: Brightness.light,
        ),
        scaffoldBackgroundColor: const Color(0xfff6f8f8),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: Colors.white,
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
        ),
        useMaterial3: true,
      ),
      home: const DashboardPage(),
    );
  }
}

class DashboardPage extends StatefulWidget {
  const DashboardPage({super.key});

  @override
  State<DashboardPage> createState() => _DashboardPageState();
}

class _DashboardPageState extends State<DashboardPage> {
  late final DeviceWatcher _watcher;
  late final FirmwareManager _firmware;
  final _records = const RecordStore();
  final _config = XrpConfigService();
  final _logs = <String>[];
  final _robots = <String, RobotRecord>{};
  final _numberControllers = <String, TextEditingController>{};
  final _apSsidControllers = <String, TextEditingController>{};
  final _apPassControllers = <String, TextEditingController>{};
  final _staSsidControllers = <String, TextEditingController>{};
  final _staPassControllers = <String, TextEditingController>{};
  final _configuredDeviceKeys = <String>{};

  StreamSubscription<List<DetectedVolume>>? _subscription;
  late final TextEditingController _firmwareController;
  late final TextEditingController _outputController;
  bool _autoFlash = false;
  bool _autoReadPicodisk = true;
  bool _autoSaveRecords = true;
  bool _connectWifiAutomatically = true;
  bool _showLog = true;
  bool _configurationInProgress = false;
  String? _latestReleaseSummary;
  String? _firmwareDownloadSummary;
  double? _firmwareDownloadProgress;
  bool _firmwareDownloading = false;
  int? _firmwareDownloadLogBucket;

  @override
  void initState() {
    super.initState();
    _watcher = DeviceWatcher(onLog: _log);
    _firmware = FirmwareManager(onLog: _log);
    _firmwareController = TextEditingController(
      text: _firmware.defaultFirmwarePath,
    );
    _outputController = TextEditingController(
      text: _records.defaultOutputDirectory(),
    );
    _subscription = _watcher.volumes.listen(_handleVolumes, onError: _log);
    _watcher.start();
    _log(
      'Running on ${Platform.operatingSystem} ${Platform.operatingSystemVersion}.',
    );
    _log(
      'Watching for RPI-RP2, RP2350*, and PICODISK volumes. Manual Scan runs verbose multi-method detection.',
    );
  }

  @override
  void dispose() {
    _watcher.dispose();
    _subscription?.cancel();
    _firmwareController.dispose();
    _outputController.dispose();
    for (final controller in [
      ..._numberControllers.values,
      ..._apSsidControllers.values,
      ..._apPassControllers.values,
      ..._staSsidControllers.values,
      ..._staPassControllers.values,
    ]) {
      controller.dispose();
    }
    super.dispose();
  }

  void _handleVolumes(List<DetectedVolume> volumes) {
    var changed = false;
    for (final volume in volumes) {
      if (volume.isBootloader) {
        final existing = _findRobotForVolume(volume);
        if (existing == null) {
          final key = volume.identity;
          _robots[key] = RobotRecord(
            id: key,
            stage: DeviceStage.bootloaderDetected,
            firstSeen: DateTime.now(),
            updatedAt: DateTime.now(),
            bootloaderVolume: volume,
          );
          _ensureControllers(key);
          _log('Bootloader detected: ${_describeVolume(volume)}.');
          changed = true;
          if (_autoFlash) unawaited(_flash(key));
        } else if (_volumeChanged(existing.bootloaderVolume, volume)) {
          _robots[existing.id] = existing.copyWith(bootloaderVolume: volume);
          _log('Bootloader location updated: ${_describeVolume(volume)}.');
          changed = true;
        }
      }
      if (volume.isPicodisk) {
        final existing =
            _findRobotForVolume(volume) ?? _findWaitingRobotWithoutPicodisk();
        final key = existing?.id ?? volume.identity;
        final record =
            existing ??
            RobotRecord(
              id: key,
              stage: DeviceStage.picodiskDetected,
              firstSeen: DateTime.now(),
              updatedAt: DateTime.now(),
            );

        final isNewPicodisk = _volumeChanged(record.picodiskVolume, volume);
        if (!isNewPicodisk && record.status != null) continue;

        _robots[key] = record.copyWith(
          stage: record.status == null ? DeviceStage.picodiskDetected : null,
          picodiskVolume: volume,
          clearError: record.status == null,
        );
        _ensureControllers(key);
        if (isNewPicodisk) {
          _log('PICODISK detected: ${_describeVolume(volume)}.');
        }
        changed = true;
        if (_autoReadPicodisk &&
            !_isConfigurationComplete(record) &&
            record.stage != DeviceStage.readingStatus) {
          unawaited(_readAndRecord(key));
        }
      }
    }
    if (_mergeDuplicateRobots()) changed = true;
    if (changed) setState(() {});
  }

  RobotRecord? _findWaitingRobotWithoutPicodisk() {
    for (final record in _robots.values) {
      if (record.stage == DeviceStage.waitingForPicodisk &&
          record.picodiskVolume == null) {
        return record;
      }
    }
    return null;
  }

  RobotRecord? _findRobotForVolume(DetectedVolume volume) {
    final byIdentity = _robots[volume.identity];
    if (byIdentity != null) return byIdentity;
    for (final record in _robots.values) {
      if (_sameVolume(record.bootloaderVolume, volume) ||
          _sameVolume(record.picodiskVolume, volume)) {
        return record;
      }
    }
    return null;
  }

  bool _sameVolume(DetectedVolume? current, DetectedVolume next) {
    if (current == null) return false;
    if (current.identity == next.identity) return true;
    if (_sameNonEmpty(current.devicePath, next.devicePath)) return true;
    if (_sameNonEmpty(current.mountPath, next.mountPath)) return true;
    if (current.source.startsWith('/dev/') &&
        next.source.startsWith('/dev/') &&
        current.source == next.source) {
      return true;
    }
    return false;
  }

  bool _volumeChanged(DetectedVolume? current, DetectedVolume next) {
    if (current == null) return true;
    return current.source != next.source ||
        current.mountPath != next.mountPath ||
        current.label != next.label ||
        current.devicePath != next.devicePath;
  }

  bool _sameNonEmpty(String? left, String? right) {
    return left != null && left.isNotEmpty && left == right;
  }

  bool _mergeDuplicateRobots() {
    var changed = false;
    var merged = true;
    while (merged) {
      merged = false;
      final ids = _robots.keys.toList();
      for (var i = 0; i < ids.length && !merged; i++) {
        for (var j = i + 1; j < ids.length; j++) {
          final left = _robots[ids[i]];
          final right = _robots[ids[j]];
          if (left == null || right == null) continue;
          if (!_shouldMergeRecords(left, right)) continue;
          final keepId = _preferredRecordId(left, right);
          final dropId = keepId == left.id ? right.id : left.id;
          _mergeRobotRecords(keepId, dropId);
          changed = true;
          merged = true;
          break;
        }
      }
    }
    return changed;
  }

  bool _shouldMergeRecords(RobotRecord left, RobotRecord right) {
    final leftChip = _nonEmpty(left.status?.chipId);
    final rightChip = _nonEmpty(right.status?.chipId);
    if (leftChip != null && rightChip != null && leftChip != rightChip) {
      return false;
    }

    final leftKeys = _recordMergeKeys(left);
    final rightKeys = _recordMergeKeys(right);
    return leftKeys.any(rightKeys.contains);
  }

  Set<String> _recordMergeKeys(RobotRecord record) {
    final keys = <String>{};
    void add(String prefix, String? value) {
      final normalized = _nonEmpty(value);
      if (normalized != null) keys.add('$prefix:$normalized');
    }

    add('chip', record.status?.chipId);
    add('ap', record.status?.apSsid);
    add('boot-id', record.bootloaderVolume?.identity);
    add('boot-mount', record.bootloaderVolume?.mountPath);
    add('boot-dev', record.bootloaderVolume?.devicePath);
    add('pico-id', record.picodiskVolume?.identity);
    add('pico-mount', record.picodiskVolume?.mountPath);
    add('pico-dev', record.picodiskVolume?.devicePath);
    return keys;
  }

  String _preferredRecordId(RobotRecord left, RobotRecord right) {
    final leftScore = _recordKeepScore(left);
    final rightScore = _recordKeepScore(right);
    if (leftScore != rightScore) {
      return leftScore > rightScore ? left.id : right.id;
    }
    return left.firstSeen.isBefore(right.firstSeen) ? left.id : right.id;
  }

  int _recordKeepScore(RobotRecord record) {
    var score = 0;
    if (record.credentials != null) score += 8;
    if (record.status != null) score += 4;
    if (record.stage == DeviceStage.error) score += 2;
    if (record.bootloaderVolume != null && record.picodiskVolume != null) {
      score += 1;
    }
    return score;
  }

  void _mergeRobotRecords(String keepId, String dropId) {
    final keep = _robots[keepId];
    final drop = _robots[dropId];
    if (keep == null || drop == null) return;

    final merged = RobotRecord(
      id: keep.id,
      stage: _mergedStage(keep, drop),
      firstSeen: keep.firstSeen.isBefore(drop.firstSeen)
          ? keep.firstSeen
          : drop.firstSeen,
      updatedAt: keep.updatedAt.isAfter(drop.updatedAt)
          ? keep.updatedAt
          : drop.updatedAt,
      bootloaderVolume: _preferredVolume(
        keep.bootloaderVolume,
        drop.bootloaderVolume,
      ),
      picodiskVolume: _preferredVolume(
        keep.picodiskVolume,
        drop.picodiskVolume,
      ),
      status: keep.status ?? drop.status,
      credentials: keep.credentials ?? drop.credentials,
      firmwarePath: keep.firmwarePath ?? drop.firmwarePath,
      error: keep.error ?? drop.error,
    );
    _robots[keepId] = merged;
    _robots.remove(dropId);
    _mergeControllers(keepId, dropId);
  }

  DeviceStage _mergedStage(RobotRecord keep, RobotRecord drop) {
    if (keep.stage == DeviceStage.error || drop.stage == DeviceStage.error) {
      return DeviceStage.error;
    }
    const priority = {
      DeviceStage.verifyingConfig: 12,
      DeviceStage.sendingConfig: 11,
      DeviceStage.wifiConnected: 10,
      DeviceStage.configuringWifi: 9,
      DeviceStage.flashing: 8,
      DeviceStage.readingStatus: 7,
      DeviceStage.needsRestart: 6,
      DeviceStage.configSaved: 6,
      DeviceStage.configured: 5,
      DeviceStage.recorded: 4,
      DeviceStage.picodiskDetected: 3,
      DeviceStage.waitingForPicodisk: 2,
      DeviceStage.bootloaderDetected: 1,
      DeviceStage.waitingForWifiConfig: 0,
      DeviceStage.connectingWifi: 0,
      DeviceStage.error: -1,
    };
    return priority[keep.stage]! >= priority[drop.stage]!
        ? keep.stage
        : drop.stage;
  }

  DetectedVolume? _preferredVolume(DetectedVolume? keep, DetectedVolume? drop) {
    if (keep == null) return drop;
    if (drop == null) return keep;
    if (!keep.isMounted && drop.isMounted) return drop;
    if (keep.devicePath == null && drop.devicePath != null) return drop;
    return keep;
  }

  void _mergeControllers(String keepId, String dropId) {
    _ensureControllers(keepId);
    void copyIfEmpty(
      Map<String, TextEditingController> controllers,
      String keepId,
      String dropId,
    ) {
      final keep = controllers[keepId];
      final drop = controllers.remove(dropId);
      if (keep != null && drop != null && keep.text.trim().isEmpty) {
        keep.text = drop.text;
      }
      drop?.dispose();
    }

    copyIfEmpty(_numberControllers, keepId, dropId);
    copyIfEmpty(_apSsidControllers, keepId, dropId);
    copyIfEmpty(_apPassControllers, keepId, dropId);
    copyIfEmpty(_staSsidControllers, keepId, dropId);
    copyIfEmpty(_staPassControllers, keepId, dropId);
  }

  Future<void> _flash(String id) async {
    final record = _robots[id];
    final volume = record?.bootloaderVolume;
    if (record == null || volume == null) return;
    _setRecord(
      id,
      record.copyWith(stage: DeviceStage.flashing, clearError: true),
    );
    try {
      final mountedBootloader = await _firmware.flash(
        bootloader: volume,
        firmwarePath: _firmwareController.text.trim(),
      );
      _setRecord(
        id,
        _robots[id]!.copyWith(
          stage: DeviceStage.waitingForPicodisk,
          bootloaderVolume: mountedBootloader,
          firmwarePath: _firmwareController.text.trim(),
        ),
      );
      _log('Flashed ${mountedBootloader.mountPath}; waiting for PICODISK.');
    } catch (error) {
      _fail(id, error);
    }
  }

  Future<void> _readAndRecord(String id) async {
    final record = _robots[id];
    final volume = record?.picodiskVolume;
    if (record == null || volume == null) return;
    _setRecord(
      id,
      record.copyWith(stage: DeviceStage.readingStatus, clearError: true),
    );
    try {
      final mountedPicodisk = await _firmware.ensureMounted(volume);
      final status = await _firmware.readStatus(mountedPicodisk);
      final wasConfigured = _configuredDeviceKeys.any(
        _statusConfigurationKeys(status).contains,
      );
      final next = _robots[id]!.copyWith(
        stage: wasConfigured ? DeviceStage.configSaved : DeviceStage.recorded,
        picodiskVolume: mountedPicodisk,
        status: status,
      );
      _setRecord(id, next);
      _log(
        'Recorded ${status.apSsid ?? 'unknown SSID'} from ${mountedPicodisk.mountPath}.',
      );
      if (_autoSaveRecords) await _saveRecords();
    } catch (error) {
      _fail(id, error);
    }
  }

  Future<void> _configure(String id) async {
    if (!_syncCredentials(id, requireNumber: true)) {
      final number = _numberControllers[id]?.text ?? '';
      _fail(id, RobotNumberRules.validate(number, required: true)!);
      return;
    }
    final record = _robots[id];
    final credentials = record?.credentials;
    final apSsid = record?.status?.apSsid;
    final apPass = record?.status?.apPass ?? 'xrp-wpilib';
    if (record == null || credentials == null || apSsid == null) {
      _fail(
        id,
        'Robot needs a number and a recorded AP SSID before configuration.',
      );
      return;
    }
    if (_isConfigurationComplete(record)) {
      _log('Skipped ${record.displayName}; configuration is already complete.');
      return;
    }
    if (_configurationInProgress) {
      _log(
        'Skipped ${record.displayName}; another XRP configuration is still in progress.',
      );
      return;
    }
    _configurationInProgress = true;
    _setRecord(
      id,
      record.copyWith(stage: DeviceStage.connectingWifi, clearError: true),
    );
    _log(
      'Configuring ${record.displayName}: original AP "$apSsid", '
      'target AP "${credentials.apSsid}", station "${credentials.staSsid}", '
      'automatic Wi-Fi ${_connectWifiAutomatically ? 'on' : 'off'}.',
    );
    try {
      await _config.configure(
        credentials: credentials,
        originalApSsid: apSsid,
        originalApPassword: apPass,
        connectWifi: _connectWifiAutomatically,
        onProgress: (progress) => _setConfigProgress(id, progress),
        onLog: _log,
      );
      _markConfigurationComplete(_robots[id]!);
      _setRecord(id, _robots[id]!.copyWith(stage: DeviceStage.configSaved));
      _log(
        'Verified saved config for ${record.displayName}; restart the XRP to apply it.',
      );
      if (_autoSaveRecords) await _saveRecords();
    } catch (error) {
      _fail(id, error);
    } finally {
      _configurationInProgress = false;
    }
  }

  Future<void> _checkLatestFirmware() async {
    setState(() => _latestReleaseSummary = 'Checking GitHub releases...');
    try {
      final release = await _firmware.fetchLatestRelease();
      setState(() {
        _latestReleaseSummary =
            '${release.tagName}: ${release.uf2Assets.map((a) => a.name).join(', ')}';
      });
    } catch (error) {
      setState(() => _latestReleaseSummary = 'Release lookup failed: $error');
    }
  }

  Future<void> _downloadFirmwareFromNetwork() async {
    if (_firmwareDownloading) return;
    setState(() {
      _firmwareDownloading = true;
      _firmwareDownloadProgress = null;
      _firmwareDownloadSummary = 'Starting firmware download...';
      _firmwareDownloadLogBucket = null;
    });
    _log('Firmware download requested.');
    try {
      final result = await _firmware.downloadNetworkFirmware(
        onProgress: (progress) {
          if (!mounted) return;
          setState(() {
            _firmwareDownloadSummary = progress.message;
            _firmwareDownloadProgress = progress.fraction;
          });
          if (_shouldLogFirmwareDownloadProgress(progress)) {
            _log(progress.message);
          }
        },
      );
      if (!mounted) return;
      setState(() {
        _firmwareController.text = result.path;
        _firmwareDownloadSummary =
            'Ready to flash: ${result.path} (${result.blockCount} UF2 blocks).';
        _firmwareDownloadProgress = 1;
      });
      _log(
        'Firmware download ready: ${result.path}; ${result.bytes} bytes verified.',
      );
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _firmwareDownloadSummary = 'Firmware download failed: $error';
        _firmwareDownloadProgress = null;
      });
      _log('Firmware download failed: $error');
    } finally {
      if (mounted) {
        setState(() => _firmwareDownloading = false);
      }
    }
  }

  bool _shouldLogFirmwareDownloadProgress(FirmwareDownloadProgress progress) {
    if (progress.done || progress.receivedBytes == 0) return true;
    final fraction = progress.fraction;
    if (fraction == null) return false;
    final bucket = (fraction * 10).floor();
    if (bucket == _firmwareDownloadLogBucket) return false;
    _firmwareDownloadLogBucket = bucket;
    return true;
  }

  Future<void> _scanNow() async {
    _log('Manual scan requested.');
    final volumes = await _watcher.scanNow(verbose: true);
    _handleVolumes(volumes);
    _log(
      'Manual scan found ${volumes.length} XRP ${_plural('volume', volumes.length)}.',
    );
    for (final volume in volumes) {
      _log('Manual scan result: ${_describeVolume(volume)}.');
    }
  }

  Future<void> _flashAll() async {
    final ids = _robots.values
        .where(
          (record) =>
              record.bootloaderVolume != null &&
              record.stage != DeviceStage.flashing,
        )
        .map((record) => record.id)
        .toList();
    if (ids.isEmpty) {
      _log('No bootloader volumes are ready to flash.');
      return;
    }
    for (final id in ids) {
      await _flash(id);
    }
  }

  Future<void> _readAll() async {
    final ids = _robots.values
        .where(
          (record) =>
              record.picodiskVolume != null &&
              record.stage != DeviceStage.readingStatus,
        )
        .map((record) => record.id)
        .toList();
    if (ids.isEmpty) {
      _log('No PICODISK volumes are ready to read.');
      return;
    }
    for (final id in ids) {
      await _readAndRecord(id);
    }
  }

  Future<void> _configureReady() async {
    final ids = _robots.values
        .where(_canConfigureRecord)
        .map((record) => record.id)
        .toList();
    if (ids.isEmpty) {
      _log('No recorded XRP status entries are ready to configure.');
      return;
    }
    for (final id in ids) {
      await _configure(id);
    }
  }

  bool _canConfigureRecord(RobotRecord record) {
    return record.status?.apSsid != null &&
        record.stage != DeviceStage.connectingWifi &&
        record.stage != DeviceStage.sendingConfig &&
        record.stage != DeviceStage.verifyingConfig &&
        record.stage != DeviceStage.configuringWifi &&
        !_isConfigurationComplete(record);
  }

  bool _isConfigurationComplete(RobotRecord record) {
    if (record.stage == DeviceStage.configSaved ||
        record.stage == DeviceStage.configured ||
        record.stage == DeviceStage.needsRestart) {
      return true;
    }
    return _configuredDeviceKeys.any(_recordConfigurationKeys(record).contains);
  }

  void _markConfigurationComplete(RobotRecord record) {
    _configuredDeviceKeys.addAll(_recordConfigurationKeys(record));
  }

  Set<String> _recordConfigurationKeys(RobotRecord record) {
    final keys = <String>{};
    keys.addAll(_statusConfigurationKeys(record.status));
    return keys;
  }

  void _setConfigProgress(String id, XrpConfigProgress progress) {
    final record = _robots[id];
    if (record == null) return;
    final stage = switch (progress) {
      XrpConfigProgress.connectingWifi => DeviceStage.connectingWifi,
      XrpConfigProgress.wifiConnected => DeviceStage.wifiConnected,
      XrpConfigProgress.readingConfig => DeviceStage.configuringWifi,
      XrpConfigProgress.sendingConfig => DeviceStage.sendingConfig,
      XrpConfigProgress.verifyingConfig => DeviceStage.verifyingConfig,
      XrpConfigProgress.configSaved => DeviceStage.configSaved,
    };
    _log('Config progress for ${record.displayName}: ${stage.label}.');
    _setRecord(id, record.copyWith(stage: stage, clearError: true));
  }

  Set<String> _statusConfigurationKeys(XrpStatus? status) {
    final keys = <String>{};
    final chipId = _nonEmpty(status?.chipId);
    if (chipId != null) keys.add('chip:$chipId');
    final apSsid = _nonEmpty(status?.apSsid);
    if (apSsid != null) keys.add('ap:$apSsid');
    return keys;
  }

  void _assignMissingNumbers() {
    final ids = _robots.values
        .where(
          (record) =>
              RobotNumberRules.validate(
                _numberControllers[record.id]?.text ?? '',
                required: true,
              ) !=
              null,
        )
        .map((record) => record.id)
        .toList();
    if (ids.isEmpty) {
      _log('All devices already have valid robot numbers.');
      return;
    }
    setState(() {
      for (final id in ids) {
        _numberControllers[id]?.text = _nextAvailableRobotNumber(
          excludingId: id,
        );
        _applyRobotNumberDefaults(id);
        _syncCredentials(id);
      }
    });
    _log(
      'Assigned robot numbers to ${ids.length} ${_plural('device', ids.length)}.',
    );
  }

  void _assignNextNumber(String id) {
    setState(() {
      _numberControllers[id]?.text = _nextAvailableRobotNumber(excludingId: id);
      _applyRobotNumberDefaults(id);
      _syncCredentials(id);
    });
  }

  String _nextAvailableRobotNumber({String? excludingId}) {
    final used = <String>{};
    for (final entry in _numberControllers.entries) {
      if (entry.key == excludingId) continue;
      final value = entry.value.text.trim();
      if (RobotNumberRules.validate(value, required: true) == null) {
        used.add(BigInt.parse(value).toString());
      }
    }

    var next = BigInt.one;
    while (used.contains(next.toString())) {
      next += BigInt.one;
    }
    return next.toString();
  }

  void _applyRobotNumberDefaults(String id) {
    final number = _numberControllers[id]?.text.trim() ?? '';
    if (RobotNumberRules.validate(number, required: true) != null) return;
    final defaults = RobotCredentials.defaults(number);
    _apSsidControllers[id]?.text = defaults.apSsid;
    _apPassControllers[id]?.text = defaults.apPassword;
  }

  void _forgetRobot(String id) {
    setState(() {
      _robots.remove(id);
      _numberControllers.remove(id)?.dispose();
      _apSsidControllers.remove(id)?.dispose();
      _apPassControllers.remove(id)?.dispose();
      _staSsidControllers.remove(id)?.dispose();
      _staPassControllers.remove(id)?.dispose();
    });
  }

  void _clearLog() {
    setState(_logs.clear);
  }

  String _plural(String word, int count) => count == 1 ? word : '${word}s';

  String _describeVolume(DetectedVolume volume) {
    final method = volume.detectionMethod;
    return '${volume.label} at ${volume.location}'
        '${method == null ? '' : ' via $method'}';
  }

  Future<void> _saveRecords() async {
    await _records.saveAll(_outputController.text.trim(), _robots.values);
  }

  void _setRecord(String id, RobotRecord record) {
    if (!mounted) return;
    setState(() => _robots[id] = record);
  }

  void _fail(String id, Object error) {
    final record = _robots[id];
    if (record == null) return;
    _setRecord(id, record.copyWith(stage: DeviceStage.error, error: '$error'));
    _log('Error on ${record.displayName}: $error');
  }

  void _log(Object message) {
    if (!mounted) return;
    setState(() {
      _logs.insert(0, '${DateTime.now().toIso8601String()}  $message');
      if (_logs.length > 600) _logs.removeLast();
    });
  }

  void _ensureControllers(String id) {
    _numberControllers.putIfAbsent(id, () => TextEditingController());
    _apSsidControllers.putIfAbsent(id, () => TextEditingController());
    _apPassControllers.putIfAbsent(id, () => TextEditingController());
    _staSsidControllers.putIfAbsent(
      id,
      () => TextEditingController(text: 'XRC-AP'),
    );
    _staPassControllers.putIfAbsent(
      id,
      () => TextEditingController(text: 'xrc-psc-ap'),
    );
  }

  bool _syncCredentials(String id, {bool requireNumber = false}) {
    final number = _numberControllers[id]?.text.trim() ?? '';
    final record = _robots[id];
    if (record == null) return false;
    final validationError = RobotNumberRules.validate(
      number,
      required: requireNumber,
    );
    if (validationError != null || number.isEmpty) {
      _robots[id] = record.copyWith(clearCredentials: true);
      return false;
    }
    final defaults = RobotCredentials.defaults(number);
    final credentials = defaults.copyWith(
      apSsid: _nonEmpty(_apSsidControllers[id]?.text) ?? defaults.apSsid,
      apPassword:
          _nonEmpty(_apPassControllers[id]?.text) ?? defaults.apPassword,
      staSsid: _nonEmpty(_staSsidControllers[id]?.text) ?? defaults.staSsid,
      staPassword:
          _nonEmpty(_staPassControllers[id]?.text) ?? defaults.staPassword,
    );
    _robots[id] = record.copyWith(credentials: credentials);
    return true;
  }

  String? _nonEmpty(String? value) {
    final trimmed = value?.trim();
    return trimmed == null || trimmed.isEmpty ? null : trimmed;
  }

  @override
  Widget build(BuildContext context) {
    final robots = _robots.values.toList()
      ..sort((a, b) => a.firstSeen.compareTo(b.firstSeen));
    final bootloaderCount = robots
        .where((record) => record.bootloaderVolume != null)
        .length;
    final picodiskCount = robots
        .where((record) => record.picodiskVolume != null)
        .length;
    final recordedCount = robots
        .where((record) => record.stage == DeviceStage.recorded)
        .length;
    final errorCount = robots
        .where((record) => record.stage == DeviceStage.error)
        .length;
    return Scaffold(
      appBar: AppBar(
        title: const Text('XRP Batch Flasher'),
        actions: [
          IconButton(
            tooltip: 'Scan now',
            onPressed: () => unawaited(_scanNow()),
            icon: const Icon(Icons.refresh),
          ),
          IconButton(
            tooltip: 'Save records',
            onPressed: () => unawaited(_saveRecords()),
            icon: const Icon(Icons.save),
          ),
          IconButton(
            tooltip: _showLog ? 'Hide log' : 'Show log',
            onPressed: () => setState(() => _showLog = !_showLog),
            icon: Icon(_showLog ? Icons.subject : Icons.subject_outlined),
          ),
        ],
      ),
      body: Column(
        children: [
          _Toolbar(
            firmwareController: _firmwareController,
            outputController: _outputController,
            deviceCount: robots.length,
            bootloaderCount: bootloaderCount,
            picodiskCount: picodiskCount,
            recordedCount: recordedCount,
            errorCount: errorCount,
            autoFlash: _autoFlash,
            autoReadPicodisk: _autoReadPicodisk,
            autoSaveRecords: _autoSaveRecords,
            connectWifiAutomatically: _connectWifiAutomatically,
            showLog: _showLog,
            latestReleaseSummary: _latestReleaseSummary,
            firmwareDownloadSummary: _firmwareDownloadSummary,
            firmwareDownloadProgress: _firmwareDownloadProgress,
            firmwareDownloading: _firmwareDownloading,
            onAutoFlashChanged: (value) => setState(() => _autoFlash = value),
            onAutoReadChanged: (value) =>
                setState(() => _autoReadPicodisk = value),
            onAutoSaveChanged: (value) =>
                setState(() => _autoSaveRecords = value),
            onAutoWifiChanged: (value) =>
                setState(() => _connectWifiAutomatically = value),
            onShowLogChanged: (value) => setState(() => _showLog = value),
            onScan: _scanNow,
            onFlashAll: _flashAll,
            onReadAll: _readAll,
            onConfigureReady: _configureReady,
            onAssignMissing: _assignMissingNumbers,
            onSaveRecords: _saveRecords,
            onClearLog: _clearLog,
            onCheckLatest: _checkLatestFirmware,
            onDownloadFirmware: _downloadFirmwareFromNetwork,
          ),
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final list = robots.isEmpty
                    ? _EmptyState(onScan: _scanNow)
                    : ListView.separated(
                        padding: const EdgeInsets.all(16),
                        itemCount: robots.length,
                        separatorBuilder: (_, _) => const SizedBox(height: 12),
                        itemBuilder: (context, index) {
                          final record = robots[index];
                          return _RobotTile(
                            record: record,
                            numberController: _numberControllers[record.id]!,
                            apSsidController: _apSsidControllers[record.id]!,
                            apPassController: _apPassControllers[record.id]!,
                            staSsidController: _staSsidControllers[record.id]!,
                            staPassController: _staPassControllers[record.id]!,
                            onNumberChanged: (_) {
                              final id = record.id;
                              final number =
                                  _numberControllers[id]?.text.trim() ?? '';
                              setState(() {
                                if (RobotNumberRules.validate(
                                      number,
                                      required: true,
                                    ) ==
                                    null) {
                                  _applyRobotNumberDefaults(id);
                                }
                                _syncCredentials(id);
                              });
                            },
                            onAssignNext: () => _assignNextNumber(record.id),
                            onFlash: () => unawaited(_flash(record.id)),
                            onReadStatus: () =>
                                unawaited(_readAndRecord(record.id)),
                            onConfigure: () => unawaited(_configure(record.id)),
                            onSave: () {
                              setState(() {
                                _syncCredentials(record.id);
                              });
                              unawaited(_saveRecords());
                            },
                            onForget: () => _forgetRobot(record.id),
                          );
                        },
                      );

                if (!_showLog) return list;

                final logPanel = _LogPanel(logs: _logs, onClear: _clearLog);
                if (constraints.maxWidth < 980) {
                  return Column(
                    children: [
                      Expanded(child: list),
                      SizedBox(height: 280, child: logPanel),
                    ],
                  );
                }
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(flex: 3, child: list),
                    logPanel,
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _Toolbar extends StatelessWidget {
  const _Toolbar({
    required this.firmwareController,
    required this.outputController,
    required this.deviceCount,
    required this.bootloaderCount,
    required this.picodiskCount,
    required this.recordedCount,
    required this.errorCount,
    required this.autoFlash,
    required this.autoReadPicodisk,
    required this.autoSaveRecords,
    required this.connectWifiAutomatically,
    required this.showLog,
    required this.latestReleaseSummary,
    required this.firmwareDownloadSummary,
    required this.firmwareDownloadProgress,
    required this.firmwareDownloading,
    required this.onAutoFlashChanged,
    required this.onAutoReadChanged,
    required this.onAutoSaveChanged,
    required this.onAutoWifiChanged,
    required this.onShowLogChanged,
    required this.onScan,
    required this.onFlashAll,
    required this.onReadAll,
    required this.onConfigureReady,
    required this.onAssignMissing,
    required this.onSaveRecords,
    required this.onClearLog,
    required this.onCheckLatest,
    required this.onDownloadFirmware,
  });

  final TextEditingController firmwareController;
  final TextEditingController outputController;
  final int deviceCount;
  final int bootloaderCount;
  final int picodiskCount;
  final int recordedCount;
  final int errorCount;
  final bool autoFlash;
  final bool autoReadPicodisk;
  final bool autoSaveRecords;
  final bool connectWifiAutomatically;
  final bool showLog;
  final String? latestReleaseSummary;
  final String? firmwareDownloadSummary;
  final double? firmwareDownloadProgress;
  final bool firmwareDownloading;
  final ValueChanged<bool> onAutoFlashChanged;
  final ValueChanged<bool> onAutoReadChanged;
  final ValueChanged<bool> onAutoSaveChanged;
  final ValueChanged<bool> onAutoWifiChanged;
  final ValueChanged<bool> onShowLogChanged;
  final Future<void> Function() onScan;
  final Future<void> Function() onFlashAll;
  final Future<void> Function() onReadAll;
  final Future<void> Function() onConfigureReady;
  final VoidCallback onAssignMissing;
  final Future<void> Function() onSaveRecords;
  final VoidCallback onClearLog;
  final Future<void> Function() onCheckLatest;
  final Future<void> Function() onDownloadFirmware;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        color: scheme.surface,
        border: Border(
          bottom: BorderSide(color: Theme.of(context).dividerColor),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _MetricChip(
                  icon: Icons.usb,
                  label: 'Devices',
                  value: '$deviceCount',
                ),
                _MetricChip(
                  icon: Icons.memory,
                  label: 'Bootloader',
                  value: '$bootloaderCount',
                ),
                _MetricChip(
                  icon: Icons.sd_storage,
                  label: 'PICODISK',
                  value: '$picodiskCount',
                ),
                _MetricChip(
                  icon: Icons.task_alt,
                  label: 'Recorded',
                  value: '$recordedCount',
                ),
                _MetricChip(
                  icon: Icons.error_outline,
                  label: 'Errors',
                  value: '$errorCount',
                  tone: errorCount == 0 ? null : scheme.errorContainer,
                ),
              ],
            ),
            const SizedBox(height: 12),
            LayoutBuilder(
              builder: (context, constraints) {
                final fieldWidth = constraints.maxWidth >= 900
                    ? (constraints.maxWidth - 12) / 2
                    : constraints.maxWidth;
                return Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  children: [
                    SizedBox(
                      width: fieldWidth,
                      child: TextField(
                        controller: firmwareController,
                        decoration: const InputDecoration(
                          labelText: 'UF2 firmware path',
                          prefixIcon: Icon(Icons.memory),
                        ),
                      ),
                    ),
                    SizedBox(
                      width: fieldWidth,
                      child: TextField(
                        controller: outputController,
                        decoration: const InputDecoration(
                          labelText: 'Record output folder',
                          prefixIcon: Icon(Icons.folder),
                        ),
                      ),
                    ),
                  ],
                );
              },
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                FilledButton.icon(
                  onPressed: () => unawaited(onScan()),
                  icon: const Icon(Icons.refresh),
                  label: const Text('Scan'),
                ),
                FilledButton.tonalIcon(
                  onPressed: bootloaderCount == 0
                      ? null
                      : () => unawaited(onFlashAll()),
                  icon: const Icon(Icons.flash_on),
                  label: const Text('Flash all'),
                ),
                OutlinedButton.icon(
                  onPressed: picodiskCount == 0
                      ? null
                      : () => unawaited(onReadAll()),
                  icon: const Icon(Icons.article),
                  label: const Text('Read all'),
                ),
                OutlinedButton.icon(
                  onPressed: recordedCount == 0
                      ? null
                      : () => unawaited(onConfigureReady()),
                  icon: const Icon(Icons.wifi),
                  label: const Text('Configure ready'),
                ),
                OutlinedButton.icon(
                  onPressed: deviceCount == 0 ? null : onAssignMissing,
                  icon: const Icon(Icons.format_list_numbered),
                  label: const Text('Assign missing'),
                ),
                TextButton.icon(
                  onPressed: () => unawaited(onSaveRecords()),
                  icon: const Icon(Icons.save),
                  label: const Text('Save records'),
                ),
                TextButton.icon(
                  onPressed: () => unawaited(onCheckLatest()),
                  icon: const Icon(Icons.cloud_download),
                  label: const Text('Latest'),
                ),
                TextButton.icon(
                  onPressed: firmwareDownloading
                      ? null
                      : () => unawaited(onDownloadFirmware()),
                  icon: const Icon(Icons.download),
                  label: Text(
                    firmwareDownloading ? 'Downloading' : 'Download UF2',
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 18,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                _OptionSwitch(
                  icon: Icons.flash_on,
                  label: 'Auto flash',
                  value: autoFlash,
                  onChanged: onAutoFlashChanged,
                ),
                _OptionSwitch(
                  icon: Icons.article,
                  label: 'Auto read',
                  value: autoReadPicodisk,
                  onChanged: onAutoReadChanged,
                ),
                _OptionSwitch(
                  icon: Icons.save,
                  label: 'Auto save',
                  value: autoSaveRecords,
                  onChanged: onAutoSaveChanged,
                ),
                _OptionSwitch(
                  icon: Icons.wifi,
                  label: 'Auto Wi-Fi',
                  value: connectWifiAutomatically,
                  onChanged: onAutoWifiChanged,
                ),
                _OptionSwitch(
                  icon: Icons.subject,
                  label: 'Log',
                  value: showLog,
                  onChanged: onShowLogChanged,
                ),
                TextButton.icon(
                  onPressed: onClearLog,
                  icon: const Icon(Icons.clear_all),
                  label: const Text('Clear log'),
                ),
              ],
            ),
            if (latestReleaseSummary != null) ...[
              const SizedBox(height: 8),
              Text(
                latestReleaseSummary!,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
            if (firmwareDownloadSummary != null) ...[
              const SizedBox(height: 8),
              if (firmwareDownloading || firmwareDownloadProgress != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: LinearProgressIndicator(
                    value: firmwareDownloadProgress,
                  ),
                ),
              Text(
                firmwareDownloadSummary!,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _MetricChip extends StatelessWidget {
  const _MetricChip({
    required this.icon,
    required this.label,
    required this.value,
    this.tone,
  });

  final IconData icon;
  final String label;
  final String value;
  final Color? tone;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: tone ?? scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 18),
            const SizedBox(width: 8),
            Text(label),
            const SizedBox(width: 6),
            Text(value, style: Theme.of(context).textTheme.labelLarge),
          ],
        ),
      ),
    );
  }
}

class _OptionSwitch extends StatelessWidget {
  const _OptionSwitch({
    required this.icon,
    required this.label,
    required this.value,
    required this.onChanged,
  });

  final IconData icon;
  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 18),
        const SizedBox(width: 6),
        Text(label),
        Switch(value: value, onChanged: onChanged),
      ],
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.onScan});

  final Future<void> Function() onScan;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: scheme.surface,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: Theme.of(context).dividerColor),
          ),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.usb, size: 42, color: scheme.primary),
                const SizedBox(height: 12),
                Text(
                  'No XRP volumes detected',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 8),
                Text(
                  'Supported bootloader labels include RPI-RP2, RP2350, and RP23501. PICODISK is detected after firmware boots.',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
                const SizedBox(height: 16),
                FilledButton.icon(
                  onPressed: () => unawaited(onScan()),
                  icon: const Icon(Icons.refresh),
                  label: const Text('Scan now'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _RobotTile extends StatelessWidget {
  const _RobotTile({
    required this.record,
    required this.numberController,
    required this.apSsidController,
    required this.apPassController,
    required this.staSsidController,
    required this.staPassController,
    required this.onNumberChanged,
    required this.onAssignNext,
    required this.onFlash,
    required this.onReadStatus,
    required this.onConfigure,
    required this.onSave,
    required this.onForget,
  });

  final RobotRecord record;
  final TextEditingController numberController;
  final TextEditingController apSsidController;
  final TextEditingController apPassController;
  final TextEditingController staSsidController;
  final TextEditingController staPassController;
  final ValueChanged<String> onNumberChanged;
  final VoidCallback onAssignNext;
  final VoidCallback onFlash;
  final VoidCallback onReadStatus;
  final VoidCallback onConfigure;
  final VoidCallback onSave;
  final VoidCallback onForget;

  @override
  Widget build(BuildContext context) {
    final robotNumberError = RobotNumberRules.validate(numberController.text);
    final excelRow = _excelRow();
    final canConfigure =
        record.status?.apSsid != null &&
        record.stage != DeviceStage.connectingWifi &&
        record.stage != DeviceStage.sendingConfig &&
        record.stage != DeviceStage.verifyingConfig &&
        record.stage != DeviceStage.configured &&
        record.stage != DeviceStage.configSaved &&
        record.stage != DeviceStage.needsRestart &&
        record.stage != DeviceStage.configuringWifi;
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(color: Theme.of(context).dividerColor),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    record.displayName,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                _StageChip(stage: record.stage),
              ],
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 16,
              runSpacing: 4,
              children: [
                _Fact('Default SSID', record.status?.apSsid ?? 'Unknown'),
                _Fact('Chip', record.status?.chipId ?? 'Unknown'),
                _Fact('Version', record.status?.version ?? 'Unknown'),
                _Fact('Mode', record.status?.wifiMode ?? 'Unknown'),
                _Fact('IP', record.status?.ipAddress ?? 'Unknown'),
                _Fact(
                  'Bootloader',
                  record.bootloaderVolume?.location ?? 'Not detected',
                ),
                _Fact(
                  'PICODISK',
                  record.picodiskVolume?.location ?? 'Not detected',
                ),
              ],
            ),
            const SizedBox(height: 12),
            LayoutBuilder(
              builder: (context, constraints) {
                final width = constraints.maxWidth > 760
                    ? (constraints.maxWidth - 48) / 5
                    : constraints.maxWidth;
                return Wrap(
                  spacing: 12,
                  runSpacing: 10,
                  children: [
                    _field(
                      width: width,
                      controller: numberController,
                      label: 'Robot number',
                      onChanged: onNumberChanged,
                      icon: Icons.tag,
                      helperText: 'Minimum 1; no fixed max',
                      errorText: robotNumberError,
                      keyboardType: TextInputType.number,
                      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                      suffixIcon: IconButton(
                        tooltip: 'Assign next number',
                        onPressed: onAssignNext,
                        icon: const Icon(Icons.add),
                      ),
                    ),
                    _field(
                      width: width,
                      controller: apSsidController,
                      label: 'AP SSID',
                      onChanged: (_) {},
                      icon: Icons.router,
                    ),
                    _field(
                      width: width,
                      controller: apPassController,
                      label: 'AP password',
                      onChanged: (_) {},
                      icon: Icons.password,
                    ),
                    _field(
                      width: width,
                      controller: staSsidController,
                      label: 'STA SSID',
                      onChanged: (_) {},
                      icon: Icons.wifi,
                    ),
                    _field(
                      width: width,
                      controller: staPassController,
                      label: 'STA password',
                      onChanged: (_) {},
                      icon: Icons.password,
                    ),
                  ],
                );
              },
            ),
            if (record.error != null) ...[
              const SizedBox(height: 8),
              SelectableText(
                record.error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              children: [
                OutlinedButton.icon(
                  onPressed: record.bootloaderVolume == null ? null : onFlash,
                  icon: const Icon(Icons.flash_on),
                  label: const Text('Flash'),
                ),
                OutlinedButton.icon(
                  onPressed: record.picodiskVolume == null
                      ? null
                      : onReadStatus,
                  icon: const Icon(Icons.article),
                  label: const Text('Read status'),
                ),
                FilledButton.icon(
                  onPressed: canConfigure ? onConfigure : null,
                  icon: const Icon(Icons.wifi),
                  label: const Text('Configure'),
                ),
                TextButton.icon(
                  onPressed: onSave,
                  icon: const Icon(Icons.save),
                  label: const Text('Save record'),
                ),
                TextButton.icon(
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: excelRow));
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Copied row for Excel')),
                    );
                  },
                  icon: const Icon(Icons.copy),
                  label: const Text('Copy row'),
                ),
                IconButton(
                  tooltip: 'Forget device',
                  onPressed: onForget,
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  String _excelRow() {
    return [
      _cell(record.credentials?.robotNumber ?? numberController.text),
      _cell(record.status?.apSsid),
      _cell(record.status?.chipId),
      _cell(record.status?.version),
      _cell(record.status?.wifiMode),
      _cell(record.status?.ipAddress),
      _cell(apSsidController.text),
      _cell(apPassController.text),
      _cell(staSsidController.text),
      _cell(staPassController.text),
      _cell(record.stage.label),
    ].join('\t');
  }

  String _cell(String? value) {
    return (value == null || value.trim().isEmpty) ? '' : value.trim();
  }

  Widget _field({
    required double width,
    required TextEditingController controller,
    required String label,
    required ValueChanged<String> onChanged,
    IconData? icon,
    String? helperText,
    String? errorText,
    TextInputType? keyboardType,
    List<TextInputFormatter>? inputFormatters,
    Widget? suffixIcon,
  }) {
    return SizedBox(
      width: width,
      child: TextField(
        controller: controller,
        onChanged: onChanged,
        keyboardType: keyboardType,
        inputFormatters: inputFormatters,
        decoration: InputDecoration(
          labelText: label,
          prefixIcon: icon == null ? null : Icon(icon),
          helperText: errorText == null ? helperText : null,
          errorText: errorText,
          suffixIcon: suffixIcon,
        ),
      ),
    );
  }
}

class _StageChip extends StatelessWidget {
  const _StageChip({required this.stage});

  final DeviceStage stage;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = switch (stage) {
      DeviceStage.error => scheme.errorContainer,
      DeviceStage.connectingWifi ||
      DeviceStage.wifiConnected ||
      DeviceStage.sendingConfig ||
      DeviceStage.verifyingConfig ||
      DeviceStage.flashing ||
      DeviceStage.readingStatus ||
      DeviceStage.configuringWifi => scheme.tertiaryContainer,
      DeviceStage.configSaved ||
      DeviceStage.recorded ||
      DeviceStage.configured ||
      DeviceStage.needsRestart => scheme.primaryContainer,
      _ => scheme.secondaryContainer,
    };
    final icon = switch (stage) {
      DeviceStage.error => Icons.error_outline,
      DeviceStage.flashing => Icons.flash_on,
      DeviceStage.readingStatus => Icons.article,
      DeviceStage.connectingWifi => Icons.wifi_find,
      DeviceStage.wifiConnected => Icons.wifi,
      DeviceStage.sendingConfig => Icons.upload,
      DeviceStage.verifyingConfig => Icons.fact_check,
      DeviceStage.configuringWifi => Icons.wifi,
      DeviceStage.configSaved => Icons.save,
      DeviceStage.recorded ||
      DeviceStage.configured ||
      DeviceStage.needsRestart => Icons.task_alt,
      _ => Icons.usb,
    };
    return Chip(
      avatar: Icon(icon, size: 18),
      label: Text(stage.label),
      backgroundColor: color,
    );
  }
}

class _Fact extends StatelessWidget {
  const _Fact(this.label, this.value);

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: value,
      child: SelectableText.rich(
        TextSpan(
          children: [
            TextSpan(
              text: '$label: ',
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            TextSpan(text: value),
          ],
        ),
        maxLines: 1,
      ),
    );
  }
}

class _LogPanel extends StatelessWidget {
  const _LogPanel({required this.logs, required this.onClear});

  final List<String> logs;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 340,
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        border: Border(left: BorderSide(color: Theme.of(context).dividerColor)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 8, 8),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    'Event Log',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                IconButton(
                  tooltip: 'Clear log',
                  onPressed: onClear,
                  icon: const Icon(Icons.clear_all),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.all(12),
              itemCount: logs.length,
              itemBuilder: (context, index) => Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: SelectableText(
                  logs[index],
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

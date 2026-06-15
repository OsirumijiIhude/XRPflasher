import 'dart:convert';

enum DeviceStage {
  bootloaderDetected,
  flashing,
  waitingForPicodisk,
  picodiskDetected,
  readingStatus,
  recorded,
  waitingForWifiConfig,
  connectingWifi,
  wifiConnected,
  sendingConfig,
  verifyingConfig,
  configuringWifi,
  configSaved,
  configured,
  needsRestart,
  error,
}

extension DeviceStageLabel on DeviceStage {
  String get label {
    switch (this) {
      case DeviceStage.bootloaderDetected:
        return 'Bootloader';
      case DeviceStage.flashing:
        return 'Flashing';
      case DeviceStage.waitingForPicodisk:
        return 'Waiting';
      case DeviceStage.picodiskDetected:
        return 'PICODISK';
      case DeviceStage.readingStatus:
        return 'Reading';
      case DeviceStage.recorded:
        return 'Recorded';
      case DeviceStage.waitingForWifiConfig:
        return 'Ready to configure';
      case DeviceStage.connectingWifi:
        return 'Connecting WiFi';
      case DeviceStage.wifiConnected:
        return 'WiFi connected';
      case DeviceStage.sendingConfig:
        return 'Sending config';
      case DeviceStage.verifyingConfig:
        return 'Verifying save';
      case DeviceStage.configuringWifi:
        return 'Configuring';
      case DeviceStage.configSaved:
        return 'Config saved';
      case DeviceStage.configured:
        return 'Configured';
      case DeviceStage.needsRestart:
        return 'Needs restart';
      case DeviceStage.error:
        return 'Error';
    }
  }
}

class DetectedVolume {
  const DetectedVolume({
    required this.source,
    required this.mountPath,
    required this.label,
    this.devicePath,
    this.detectionMethod,
  });

  final String source;
  final String mountPath;
  final String label;
  final String? devicePath;
  final String? detectionMethod;

  bool get isBootloader {
    final normalized = label.toUpperCase();
    return normalized == 'RPI-RP2' ||
        RegExp(r'^RP2350\d*$').hasMatch(normalized);
  }

  bool get isPicodisk => RegExp(r'^PICODISK\d*$').hasMatch(label.toUpperCase());

  bool get isMounted => mountPath.isNotEmpty;

  String get location => isMounted ? mountPath : devicePath ?? source;

  DetectedVolume copyWith({
    String? source,
    String? mountPath,
    String? label,
    String? devicePath,
    String? detectionMethod,
  }) {
    return DetectedVolume(
      source: source ?? this.source,
      mountPath: mountPath ?? this.mountPath,
      label: label ?? this.label,
      devicePath: devicePath ?? this.devicePath,
      detectionMethod: detectionMethod ?? this.detectionMethod,
    );
  }

  String get identity {
    final deviceIdentity =
        devicePath ?? (source.startsWith('/dev/') ? source : null);
    if (deviceIdentity != null) return deviceIdentity;
    return '$mountPath|$label';
  }
}

class XrpStatus {
  const XrpStatus({
    this.version,
    this.chipId,
    this.wifiMode,
    this.apSsid,
    this.apPass,
    this.ipAddress,
    required this.rawText,
  });

  final String? version;
  final String? chipId;
  final String? wifiMode;
  final String? apSsid;
  final String? apPass;
  final String? ipAddress;
  final String rawText;

  Map<String, Object?> toJson() => {
    'version': version,
    'chipId': chipId,
    'wifiMode': wifiMode,
    'apSsid': apSsid,
    'apPass': apPass,
    'ipAddress': ipAddress,
    'rawText': rawText,
  };
}

class RobotCredentials {
  const RobotCredentials({
    required this.robotNumber,
    required this.apSsid,
    required this.apPassword,
    required this.staSsid,
    required this.staPassword,
  });

  factory RobotCredentials.defaults(String robotNumber) {
    final value = RobotNumberRules.normalize(robotNumber);
    final error = RobotNumberRules.validate(value, required: true);
    if (error != null) {
      throw ArgumentError.value(robotNumber, 'robotNumber', error);
    }
    return RobotCredentials(
      robotNumber: value,
      apSsid: 'XR_$value',
      apPassword: 'XRP_Robot_$value',
      staSsid: 'XRC-AP',
      staPassword: 'xrc-psc-ap',
    );
  }

  final String robotNumber;
  final String apSsid;
  final String apPassword;
  final String staSsid;
  final String staPassword;

  RobotCredentials copyWith({
    String? robotNumber,
    String? apSsid,
    String? apPassword,
    String? staSsid,
    String? staPassword,
  }) {
    return RobotCredentials(
      robotNumber: robotNumber ?? this.robotNumber,
      apSsid: apSsid ?? this.apSsid,
      apPassword: apPassword ?? this.apPassword,
      staSsid: staSsid ?? this.staSsid,
      staPassword: staPassword ?? this.staPassword,
    );
  }

  Map<String, Object?> toJson() => {
    'robotNumber': robotNumber,
    'apSsid': apSsid,
    'apPassword': apPassword,
    'staSsid': staSsid,
    'staPassword': staPassword,
  };
}

class RobotNumberRules {
  static final RegExp _digitsOnly = RegExp(r'^\d+$');

  static String normalize(String value) => value.trim();

  static String? validate(String value, {bool required = false}) {
    final normalized = normalize(value);
    if (normalized.isEmpty) {
      return required ? 'Robot number is required.' : null;
    }
    if (!_digitsOnly.hasMatch(normalized)) return 'Use digits only.';
    final parsed = BigInt.tryParse(normalized);
    if (parsed == null || parsed < BigInt.one) {
      return 'Minimum robot number is 1.';
    }
    return null;
  }
}

class RobotRecord {
  const RobotRecord({
    required this.id,
    required this.stage,
    required this.firstSeen,
    required this.updatedAt,
    this.bootloaderVolume,
    this.picodiskVolume,
    this.status,
    this.credentials,
    this.firmwarePath,
    this.error,
  });

  final String id;
  final DeviceStage stage;
  final DateTime firstSeen;
  final DateTime updatedAt;
  final DetectedVolume? bootloaderVolume;
  final DetectedVolume? picodiskVolume;
  final XrpStatus? status;
  final RobotCredentials? credentials;
  final String? firmwarePath;
  final String? error;

  RobotRecord copyWith({
    DeviceStage? stage,
    DateTime? updatedAt,
    DetectedVolume? bootloaderVolume,
    DetectedVolume? picodiskVolume,
    XrpStatus? status,
    RobotCredentials? credentials,
    String? firmwarePath,
    String? error,
    bool clearError = false,
    bool clearCredentials = false,
  }) {
    return RobotRecord(
      id: id,
      stage: stage ?? this.stage,
      firstSeen: firstSeen,
      updatedAt: updatedAt ?? DateTime.now(),
      bootloaderVolume: bootloaderVolume ?? this.bootloaderVolume,
      picodiskVolume: picodiskVolume ?? this.picodiskVolume,
      status: status ?? this.status,
      credentials: clearCredentials ? null : credentials ?? this.credentials,
      firmwarePath: firmwarePath ?? this.firmwarePath,
      error: clearError ? null : error ?? this.error,
    );
  }

  String get displayName {
    if (credentials?.robotNumber.trim().isNotEmpty ?? false) {
      return 'XR_${credentials!.robotNumber}';
    }
    return status?.apSsid ??
        picodiskVolume?.label ??
        bootloaderVolume?.label ??
        id;
  }

  Map<String, Object?> toJson() => {
    'id': id,
    'stage': stage.name,
    'firstSeen': firstSeen.toIso8601String(),
    'updatedAt': updatedAt.toIso8601String(),
    'bootloaderVolume': _volumeJson(bootloaderVolume),
    'picodiskVolume': _volumeJson(picodiskVolume),
    'status': status?.toJson(),
    'credentials': credentials?.toJson(),
    'firmwarePath': firmwarePath,
    'error': error,
  };

  static Map<String, Object?>? _volumeJson(DetectedVolume? volume) {
    if (volume == null) return null;
    return {
      'source': volume.source,
      'mountPath': volume.mountPath,
      'label': volume.label,
      'devicePath': volume.devicePath,
      'detectionMethod': volume.detectionMethod,
    };
  }

  String toText() {
    final encoder = const JsonEncoder.withIndent('  ');
    return [
      'Robot: $displayName',
      'Stage: ${stage.label}',
      'First Seen: ${firstSeen.toIso8601String()}',
      'Updated At: ${updatedAt.toIso8601String()}',
      '',
      'Default XRP SSID: ${status?.apSsid ?? 'Unknown'}',
      'Chip ID: ${status?.chipId ?? 'Unknown'}',
      'Firmware Version: ${status?.version ?? 'Unknown'}',
      'WiFi Mode: ${status?.wifiMode ?? 'Unknown'}',
      'IP Address: ${status?.ipAddress ?? 'Unknown'}',
      '',
      'Target AP SSID: ${credentials?.apSsid ?? 'Unassigned'}',
      'Target AP Password: ${credentials?.apPassword ?? 'Unassigned'}',
      'STA SSID: ${credentials?.staSsid ?? 'Unassigned'}',
      'STA Password: ${credentials?.staPassword ?? 'Unassigned'}',
      '',
      'Firmware UF2: ${firmwarePath ?? 'Unknown'}',
      'Bootloader Mount: ${bootloaderVolume?.mountPath ?? 'Unknown'}',
      'PICODISK Mount: ${picodiskVolume?.mountPath ?? 'Unknown'}',
      if (error != null) 'Error: $error',
      '',
      'JSON:',
      encoder.convert(toJson()),
    ].join('\n');
  }
}

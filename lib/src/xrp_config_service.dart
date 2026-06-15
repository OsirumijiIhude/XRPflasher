import 'dart:convert';
import 'dart:io';

import 'models.dart';

class XrpConfigException implements Exception {
  const XrpConfigException(this.message);

  final String message;

  @override
  String toString() => message;
}

class _HttpResult {
  const _HttpResult({
    required this.uri,
    required this.method,
    required this.statusCode,
    required this.body,
  });

  final Uri uri;
  final String method;
  final int statusCode;
  final String body;

  bool get isSuccess => statusCode >= 200 && statusCode < 300;

  String describe() {
    final preview = body.trim().isEmpty ? '<empty>' : _preview(body);
    return '$method $uri -> HTTP $statusCode, body: $preview';
  }
}

enum XrpConfigProgress {
  connectingWifi,
  wifiConnected,
  readingConfig,
  sendingConfig,
  verifyingConfig,
  configSaved,
}

class XrpConfigService {
  XrpConfigService({
    HttpClient? httpClient,
    Future<ProcessResult> Function(String executable, List<String> arguments)?
    processRunner,
  }) : _httpClient = httpClient ?? HttpClient(),
       _processRunner =
           processRunner ??
           ((executable, arguments) => Process.run(executable, arguments));

  final HttpClient _httpClient;
  final Future<ProcessResult> Function(
    String executable,
    List<String> arguments,
  )
  _processRunner;

  Map<String, Object?> buildConfig(
    Map<String, Object?> current,
    RobotCredentials credentials,
  ) {
    final next = _deepCopy(current);
    final network = Map<String, Object?>.from(
      next['network'] as Map<String, Object?>? ?? const {},
    );
    network['defaultAP'] = {
      'ssid': credentials.apSsid,
      'password': credentials.apPassword,
      'channel': (network['defaultAP'] as Map?)?['channel'] ?? 1,
    };
    network['networkList'] = [
      {'ssid': credentials.staSsid, 'password': credentials.staPassword},
    ];
    network['mode'] = 'STA';
    next['network'] = network;
    return next;
  }

  Future<void> configure({
    required RobotCredentials credentials,
    required String originalApSsid,
    required String originalApPassword,
    String baseUrl = 'http://192.168.42.1:5000',
    bool connectWifi = true,
    void Function(XrpConfigProgress progress)? onProgress,
    void Function(String message)? onLog,
  }) async {
    _log(
      onLog,
      'Starting config for original AP "$originalApSsid" at $baseUrl; '
      'auto Wi-Fi ${connectWifi ? 'enabled' : 'disabled'}.',
    );
    Map<String, Object?>? current;
    if (connectWifi) {
      try {
        onProgress?.call(XrpConfigProgress.connectingWifi);
        await connectWithSystemWifi(
          originalApSsid,
          originalApPassword,
          onLog: onLog,
        );
        onProgress?.call(XrpConfigProgress.readingConfig);
        _log(onLog, 'Wi-Fi helper finished; probing XRP HTTP config.');
        current = await _getConfigOrFallback(
          baseUrl: baseUrl,
          originalApSsid: originalApSsid,
          originalApPassword: originalApPassword,
          onLog: onLog,
        );
        onProgress?.call(XrpConfigProgress.wifiConnected);
      } catch (error) {
        _log(
          onLog,
          'Automatic Wi-Fi path failed: $error. Probing XRP HTTP directly.',
        );
        try {
          onProgress?.call(XrpConfigProgress.readingConfig);
          current = await _getConfigOrFallback(
            baseUrl: baseUrl,
            originalApSsid: originalApSsid,
            originalApPassword: originalApPassword,
            onLog: onLog,
          );
          onProgress?.call(XrpConfigProgress.wifiConnected);
        } catch (_) {
          throw error;
        }
      }
    } else {
      _log(
        onLog,
        'Automatic Wi-Fi disabled; expecting the PC to already reach the XRP.',
      );
    }
    onProgress?.call(XrpConfigProgress.readingConfig);
    current ??= await _getConfigOrFallback(
      baseUrl: baseUrl,
      originalApSsid: originalApSsid,
      originalApPassword: originalApPassword,
      onLog: onLog,
    );
    final next = buildConfig(current, credentials);
    onProgress?.call(XrpConfigProgress.sendingConfig);
    await saveConfig(next, baseUrl: baseUrl, onLog: onLog);
    onProgress?.call(XrpConfigProgress.verifyingConfig);
    final saved = await getConfig(baseUrl: baseUrl, attempts: 5, onLog: onLog);
    verifySavedConfig(saved, credentials);
    _log(onLog, 'Verified XRP saved config matches requested credentials.');
    onProgress?.call(XrpConfigProgress.configSaved);
  }

  Future<Map<String, Object?>> _getConfigOrFallback({
    required String baseUrl,
    required String originalApSsid,
    required String originalApPassword,
    void Function(String message)? onLog,
  }) async {
    try {
      return await getConfig(baseUrl: baseUrl, attempts: 5, onLog: onLog);
    } on XrpConfigException catch (error) {
      _log(
        onLog,
        'Could not read current config; using repaired base config. ${error.message}',
      );
      return _repairBaseConfig(
        originalApSsid: originalApSsid,
        originalApPassword: originalApPassword,
      );
    }
  }

  Map<String, Object?> _repairBaseConfig({
    required String originalApSsid,
    required String originalApPassword,
  }) {
    return {
      'configVersion': 1,
      'network': {
        'defaultAP': {'ssid': originalApSsid, 'password': originalApPassword},
        'networkList': <Map<String, Object?>>[],
        'mode': 'AP',
      },
    };
  }

  Future<void> connectWithSystemWifi(
    String ssid,
    String password, {
    void Function(String message)? onLog,
  }) {
    if (Platform.isWindows) {
      return connectWithWindowsWifi(ssid, password, onLog: onLog);
    }
    if (Platform.isLinux) {
      return connectWithNmcli(ssid, password, onLog: onLog);
    }
    _log(
      onLog,
      'Automatic Wi-Fi is not implemented for ${Platform.operatingSystem}.',
    );
    throw UnsupportedError(
      'Automatic Wi-Fi is not implemented for ${Platform.operatingSystem}.',
    );
  }

  Future<void> connectWithNmcli(
    String ssid,
    String password, {
    void Function(String message)? onLog,
  }) async {
    _log(onLog, 'Linux Wi-Fi: rescanning for "$ssid" with nmcli.');
    await _tryNmcli(['device', 'wifi', 'rescan', 'ssid', ssid], onLog: onLog);
    await Future<void>.delayed(const Duration(seconds: 2));
    var result = await _runNmcli([
      'device',
      'wifi',
      'connect',
      ssid,
      'password',
      password,
    ], onLog: onLog);
    if (result.exitCode == 0 || _isNmcliActivationPending(result)) {
      _log(onLog, 'nmcli reported connection activation for "$ssid".');
      return;
    }

    _log(onLog, 'nmcli first connect failed; rescanning visible Wi-Fi list.');
    await _tryNmcli([
      'device',
      'wifi',
      'list',
      '--rescan',
      'yes',
    ], onLog: onLog);
    await Future<void>.delayed(const Duration(seconds: 2));
    result = await _runNmcli([
      'device',
      'wifi',
      'connect',
      ssid,
      'password',
      password,
    ], onLog: onLog);
    if (result.exitCode != 0 && !_isNmcliActivationPending(result)) {
      throw ProcessException(
        'nmcli',
        ['device', 'wifi', 'connect', ssid, 'password', '********'],
        '${result.stderr}\n${result.stdout}'.trim(),
        result.exitCode,
      );
    }
    _log(onLog, 'nmcli retry reported connection activation for "$ssid".');
  }

  Future<void> connectWithWindowsWifi(
    String ssid,
    String password, {
    void Function(String message)? onLog,
  }) async {
    _log(onLog, 'Windows Wi-Fi: scanning visible networks with netsh.');
    final visible = await _tryNetsh([
      'wlan',
      'show',
      'networks',
      'mode=bssid',
    ], onLog: onLog);
    if (visible != null) {
      final isVisible = _outputContainsSsid(visible, ssid);
      _log(
        onLog,
        'Windows Wi-Fi: "$ssid" ${isVisible ? 'is' : 'is not'} visible in the latest netsh scan.',
      );
    }

    final profile = await _writeWindowsWifiProfile(ssid, password);
    _log(onLog, 'Windows Wi-Fi: wrote temporary WLAN profile ${profile.path}.');
    ProcessResult? lastConnect;
    try {
      final addProfile = await _runNetsh([
        'wlan',
        'add',
        'profile',
        'filename=${profile.path}',
        'user=current',
      ], onLog: onLog);
      if (addProfile.exitCode != 0) {
        throw ProcessException(
          'netsh',
          ['wlan', 'add', 'profile', 'filename=<temp-profile>', 'user=current'],
          '${addProfile.stderr}\n${addProfile.stdout}'.trim(),
          addProfile.exitCode,
        );
      }

      for (var attempt = 1; attempt <= 2; attempt++) {
        _log(onLog, 'Windows Wi-Fi: connect attempt $attempt for "$ssid".');
        lastConnect = await _runNetsh([
          'wlan',
          'connect',
          'name=$ssid',
          'ssid=$ssid',
        ], onLog: onLog);
        if (await _waitForWindowsWifiConnection(ssid, onLog: onLog)) {
          return;
        }
        await _tryNetsh([
          'wlan',
          'show',
          'networks',
          'mode=bssid',
        ], onLog: onLog);
        await Future<void>.delayed(const Duration(seconds: 2));
      }
    } finally {
      try {
        if (await profile.exists()) await profile.delete();
      } catch (_) {
        _log(onLog, 'Windows Wi-Fi: could not delete ${profile.path}.');
      }
    }

    throw ProcessException(
      'netsh',
      ['wlan', 'connect', 'name=$ssid', 'ssid=$ssid'],
      lastConnect == null
          ? 'Windows did not report connection to $ssid.'
          : '${lastConnect.stderr}\n${lastConnect.stdout}'.trim(),
      lastConnect?.exitCode ?? -1,
    );
  }

  Future<ProcessResult> _runNmcli(
    List<String> arguments, {
    void Function(String message)? onLog,
  }) {
    _log(onLog, 'Running nmcli ${_maskArgs(arguments).join(' ')}.');
    return _processRunner('nmcli', arguments).then((result) {
      _logProcessResult(onLog, 'nmcli', result);
      return result;
    });
  }

  Future<void> _tryNmcli(
    List<String> arguments, {
    void Function(String message)? onLog,
  }) async {
    try {
      await _runNmcli(arguments, onLog: onLog);
    } catch (error) {
      _log(onLog, 'Best-effort nmcli command failed: $error.');
      // Best effort only; the actual connect command reports the real failure.
    }
  }

  Future<ProcessResult> _runNetsh(
    List<String> arguments, {
    void Function(String message)? onLog,
  }) {
    _log(onLog, 'Running netsh ${_maskArgs(arguments).join(' ')}.');
    return _processRunner('netsh', arguments).then((result) {
      _logProcessResult(onLog, 'netsh', result);
      return result;
    });
  }

  Future<ProcessResult?> _tryNetsh(
    List<String> arguments, {
    void Function(String message)? onLog,
  }) async {
    try {
      return await _runNetsh(arguments, onLog: onLog);
    } catch (error) {
      _log(onLog, 'Best-effort netsh command failed: $error.');
      return null;
    }
  }

  Future<File> _writeWindowsWifiProfile(String ssid, String password) async {
    final safeName = ssid.replaceAll(RegExp(r'[^A-Za-z0-9_.-]'), '_');
    final file = File(
      '${Directory.systemTemp.path}${Platform.pathSeparator}'
      'xrp-flasher-$safeName-${DateTime.now().microsecondsSinceEpoch}.xml',
    );
    await file.writeAsString(_windowsWifiProfileXml(ssid, password));
    return file;
  }

  String _windowsWifiProfileXml(String ssid, String password) {
    final escapedSsid = _escapeXml(ssid);
    final escapedPassword = _escapeXml(password);
    final security = password.trim().isEmpty
        ? '''
      <authEncryption>
        <authentication>open</authentication>
        <encryption>none</encryption>
        <useOneX>false</useOneX>
      </authEncryption>'''
        : '''
      <authEncryption>
        <authentication>WPA2PSK</authentication>
        <encryption>AES</encryption>
        <useOneX>false</useOneX>
      </authEncryption>
      <sharedKey>
        <keyType>passPhrase</keyType>
        <protected>false</protected>
        <keyMaterial>$escapedPassword</keyMaterial>
      </sharedKey>''';
    return '''
<?xml version="1.0"?>
<WLANProfile xmlns="http://www.microsoft.com/networking/WLAN/profile/v1">
  <name>$escapedSsid</name>
  <SSIDConfig>
    <SSID>
      <name>$escapedSsid</name>
    </SSID>
  </SSIDConfig>
  <connectionType>ESS</connectionType>
  <connectionMode>manual</connectionMode>
  <MSM>
    <security>
$security
    </security>
  </MSM>
</WLANProfile>
''';
  }

  Future<bool> _waitForWindowsWifiConnection(
    String ssid, {
    void Function(String message)? onLog,
  }) async {
    for (var attempt = 1; attempt <= 8; attempt++) {
      await Future<void>.delayed(const Duration(seconds: 2));
      final result = await _tryNetsh([
        'wlan',
        'show',
        'interfaces',
      ], onLog: onLog);
      if (result == null) continue;
      final output = '${result.stdout}\n${result.stderr}';
      if (_windowsInterfacesConnectedTo(output, ssid)) {
        _log(onLog, 'Windows Wi-Fi: interface reports connected to "$ssid".');
        return true;
      }
      _log(
        onLog,
        'Windows Wi-Fi: "$ssid" not connected yet '
        '(poll $attempt/8).',
      );
    }
    return false;
  }

  bool _windowsInterfacesConnectedTo(String output, String ssid) {
    final stateConnected = RegExp(
      r'^\s*State\s*:\s*connected\s*$',
      caseSensitive: false,
      multiLine: true,
    ).hasMatch(output);
    final ssidMatches = RegExp(
      r'^\s*SSID\s*:\s*(.+?)\s*$',
      caseSensitive: false,
      multiLine: true,
    ).allMatches(output).any((match) => match.group(1)?.trim() == ssid);
    return stateConnected && ssidMatches;
  }

  bool _outputContainsSsid(ProcessResult result, String ssid) {
    final output = '${result.stdout}\n${result.stderr}';
    return RegExp(
      r'^\s*SSID\s+\d+\s*:\s*(.+?)\s*$',
      caseSensitive: false,
      multiLine: true,
    ).allMatches(output).any((match) => match.group(1)?.trim() == ssid);
  }

  Future<Map<String, Object?>> getConfig({
    String baseUrl = 'http://192.168.42.1:5000',
    int attempts = 12,
    Duration retryDelay = const Duration(seconds: 1),
    void Function(String message)? onLog,
  }) async {
    final failures = <String>[];
    for (var attempt = 1; attempt <= attempts; attempt++) {
      failures.clear();
      _log(onLog, 'HTTP config read attempt $attempt/$attempts.');
      for (final path in ['/getconfig', '/']) {
        final uri = _uri(baseUrl, path);
        final _HttpResult result;
        try {
          result = await _request(uri);
        } catch (error) {
          failures.add('GET $uri failed: $error');
          _log(onLog, 'GET $uri failed: $error.');
          continue;
        }
        if (!result.isSuccess) {
          failures.add(result.describe());
          _log(onLog, result.describe());
          continue;
        }
        try {
          final config = _decodeConfig(result);
          _log(onLog, 'Read XRP config from $uri.');
          return config;
        } on XrpConfigException catch (error) {
          failures.add(error.message);
          _log(onLog, error.message);
        }
      }
      if (attempt < attempts) {
        await Future<void>.delayed(retryDelay);
      }
    }
    throw XrpConfigException(
      'Could not read XRP config:\n${failures.join('\n')}',
    );
  }

  Future<void> saveConfig(
    Map<String, Object?> config, {
    String baseUrl = 'http://192.168.42.1:5000',
    void Function(String message)? onLog,
  }) async {
    final body = const JsonEncoder.withIndent('  ').convert(config);
    final failures = <String>[];
    _log(onLog, 'Saving XRP config (${body.length} bytes).');
    for (final endpoint in const [
      ('POST', '/saveconfig', 'text/json'),
      ('POST', '/saveconfig', 'application/json'),
    ]) {
      final result = await _request(
        _uri(baseUrl, endpoint.$2),
        method: endpoint.$1,
        body: body,
        contentType: endpoint.$3,
      );
      _log(onLog, result.describe());
      if (result.isSuccess) return;
      failures.add(result.describe());
    }
    throw XrpConfigException(
      'Could not save XRP config:\n${failures.join('\n')}',
    );
  }

  void verifySavedConfig(
    Map<String, Object?> saved,
    RobotCredentials credentials,
  ) {
    final network = saved['network'];
    if (network is! Map) {
      throw const XrpConfigException(
        'Saved config verification failed: missing network object.',
      );
    }
    final defaultAp = network['defaultAP'];
    if (defaultAp is! Map) {
      throw const XrpConfigException(
        'Saved config verification failed: missing network.defaultAP object.',
      );
    }
    final networkList = network['networkList'];
    if (networkList is! List) {
      throw const XrpConfigException(
        'Saved config verification failed: missing network.networkList array.',
      );
    }

    final mismatches = <String>[];
    void expectValue(String label, Object? actual, Object? expected) {
      if (actual != expected) {
        mismatches.add('$label expected "$expected" but read "$actual"');
      }
    }

    expectValue('network.mode', network['mode'], 'STA');
    expectValue(
      'network.defaultAP.ssid',
      defaultAp['ssid'],
      credentials.apSsid,
    );
    expectValue(
      'network.defaultAP.password',
      defaultAp['password'],
      credentials.apPassword,
    );

    Map? firstNetwork;
    for (final item in networkList) {
      if (item is Map) {
        firstNetwork = item;
        break;
      }
    }
    if (firstNetwork == null) {
      mismatches.add('network.networkList[0] missing');
    } else {
      expectValue(
        'network.networkList[0].ssid',
        firstNetwork['ssid'],
        credentials.staSsid,
      );
      expectValue(
        'network.networkList[0].password',
        firstNetwork['password'],
        credentials.staPassword,
      );
    }

    if (mismatches.isNotEmpty) {
      throw XrpConfigException(
        'Saved config verification failed:\n${mismatches.join('\n')}',
      );
    }
  }

  Future<_HttpResult> _request(
    Uri uri, {
    String method = 'GET',
    String? body,
    String? contentType,
  }) async {
    final request = await _httpClient
        .openUrl(method, uri)
        .timeout(const Duration(seconds: 4));
    request.headers.set(HttpHeaders.userAgentHeader, 'xrp-flasher');
    request.headers.set(HttpHeaders.acceptHeader, 'application/json');
    if (contentType != null) {
      request.headers.set(HttpHeaders.contentTypeHeader, contentType);
    }
    if (body != null) {
      final bodyBytes = utf8.encode(body);
      request.contentLength = bodyBytes.length;
      request.add(bodyBytes);
    }
    final response = await request.close().timeout(const Duration(seconds: 6));
    final responseBody = await response
        .transform(utf8.decoder)
        .join()
        .timeout(const Duration(seconds: 6));
    return _HttpResult(
      uri: uri,
      method: method,
      statusCode: response.statusCode,
      body: responseBody,
    );
  }

  Map<String, Object?> _decodeConfig(_HttpResult result) {
    final body = result.body.trim();
    if (body.isEmpty) {
      throw XrpConfigException(
        '${result.method} ${result.uri} returned an empty config response.',
      );
    }
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map<String, Object?>) return decoded;
      if (decoded is Map) return Map<String, Object?>.from(decoded);
      throw XrpConfigException(
        '${result.method} ${result.uri} returned JSON ${decoded.runtimeType}, not an object: ${_preview(body)}',
      );
    } on FormatException catch (error) {
      throw XrpConfigException(
        '${result.method} ${result.uri} returned invalid JSON: ${error.message} at character ${error.offset ?? 'unknown'}. Body: ${_preview(body)}',
      );
    }
  }

  bool _isNmcliActivationPending(ProcessResult result) {
    final output = '${result.stderr}\n${result.stdout}'.toLowerCase();
    return output.contains('activation was enqueued') ||
        output.contains('connection activation was enqueued');
  }

  Uri _uri(String baseUrl, String path) {
    final trimmed = baseUrl.endsWith('/')
        ? baseUrl.substring(0, baseUrl.length - 1)
        : baseUrl;
    return Uri.parse('$trimmed$path');
  }

  Map<String, Object?> _deepCopy(Map<String, Object?> value) {
    return jsonDecode(jsonEncode(value)) as Map<String, Object?>;
  }

  List<String> _maskArgs(List<String> arguments) {
    final masked = <String>[];
    for (var i = 0; i < arguments.length; i++) {
      final previous = i > 0 ? arguments[i - 1].toLowerCase() : '';
      final current = arguments[i].toLowerCase();
      if (previous == 'password' ||
          current.startsWith('keymaterial=') ||
          current.startsWith('filename=')) {
        masked.add(
          current.startsWith('filename=')
              ? 'filename=<temp-profile>'
              : '********',
        );
      } else {
        masked.add(arguments[i]);
      }
    }
    return masked;
  }

  void _logProcessResult(
    void Function(String message)? onLog,
    String executable,
    ProcessResult result,
  ) {
    final output = '${result.stderr}\n${result.stdout}'.trim();
    final suffix = output.isEmpty
        ? ''
        : ': ${_preview(output, maxLength: 500)}';
    _log(onLog, '$executable exit ${result.exitCode}$suffix');
  }

  String _escapeXml(String value) {
    return value
        .replaceAll('&', '&amp;')
        .replaceAll('<', '&lt;')
        .replaceAll('>', '&gt;')
        .replaceAll('"', '&quot;')
        .replaceAll("'", '&apos;');
  }

  void _log(void Function(String message)? onLog, String message) {
    onLog?.call(message);
  }
}

String _preview(String value, {int maxLength = 300}) {
  final singleLine = value.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (singleLine.length <= maxLength) return singleLine;
  return '${singleLine.substring(0, maxLength)}...';
}

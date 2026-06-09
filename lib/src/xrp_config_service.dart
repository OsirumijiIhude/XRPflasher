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
  XrpConfigService({HttpClient? httpClient})
    : _httpClient = httpClient ?? HttpClient();

  final HttpClient _httpClient;

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
  }) async {
    Map<String, Object?>? current;
    if (connectWifi) {
      try {
        onProgress?.call(XrpConfigProgress.connectingWifi);
        await connectWithNmcli(originalApSsid, originalApPassword);
        onProgress?.call(XrpConfigProgress.readingConfig);
        current = await _getConfigOrFallback(
          baseUrl: baseUrl,
          originalApSsid: originalApSsid,
          originalApPassword: originalApPassword,
        );
        onProgress?.call(XrpConfigProgress.wifiConnected);
      } catch (error) {
        try {
          onProgress?.call(XrpConfigProgress.readingConfig);
          current = await _getConfigOrFallback(
            baseUrl: baseUrl,
            originalApSsid: originalApSsid,
            originalApPassword: originalApPassword,
          );
          onProgress?.call(XrpConfigProgress.wifiConnected);
        } catch (_) {
          throw error;
        }
      }
    }
    onProgress?.call(XrpConfigProgress.readingConfig);
    current ??= await _getConfigOrFallback(
      baseUrl: baseUrl,
      originalApSsid: originalApSsid,
      originalApPassword: originalApPassword,
    );
    final next = buildConfig(current, credentials);
    onProgress?.call(XrpConfigProgress.sendingConfig);
    await saveConfig(next, baseUrl: baseUrl);
    onProgress?.call(XrpConfigProgress.verifyingConfig);
    final saved = await getConfig(baseUrl: baseUrl, attempts: 5);
    verifySavedConfig(saved, credentials);
    onProgress?.call(XrpConfigProgress.configSaved);
  }

  Future<Map<String, Object?>> _getConfigOrFallback({
    required String baseUrl,
    required String originalApSsid,
    required String originalApPassword,
  }) async {
    try {
      return await getConfig(baseUrl: baseUrl, attempts: 5);
    } on XrpConfigException {
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

  Future<void> connectWithNmcli(String ssid, String password) async {
    await _tryNmcli(['device', 'wifi', 'rescan', 'ssid', ssid]);
    await Future<void>.delayed(const Duration(seconds: 2));
    var result = await _runNmcli([
      'device',
      'wifi',
      'connect',
      ssid,
      'password',
      password,
    ]);
    if (result.exitCode == 0 || _isNmcliActivationPending(result)) return;

    await _tryNmcli(['device', 'wifi', 'list', '--rescan', 'yes']);
    await Future<void>.delayed(const Duration(seconds: 2));
    result = await _runNmcli([
      'device',
      'wifi',
      'connect',
      ssid,
      'password',
      password,
    ]);
    if (result.exitCode != 0 && !_isNmcliActivationPending(result)) {
      throw ProcessException(
        'nmcli',
        ['device', 'wifi', 'connect', ssid, 'password', '********'],
        '${result.stderr}\n${result.stdout}'.trim(),
        result.exitCode,
      );
    }
  }

  Future<ProcessResult> _runNmcli(List<String> arguments) {
    return Process.run('nmcli', arguments);
  }

  Future<void> _tryNmcli(List<String> arguments) async {
    try {
      await _runNmcli(arguments);
    } catch (_) {
      // Best effort only; the actual connect command reports the real failure.
    }
  }

  Future<Map<String, Object?>> getConfig({
    String baseUrl = 'http://192.168.42.1:5000',
    int attempts = 12,
    Duration retryDelay = const Duration(seconds: 1),
  }) async {
    final failures = <String>[];
    for (var attempt = 1; attempt <= attempts; attempt++) {
      failures.clear();
      for (final path in ['/getconfig', '/']) {
        final uri = _uri(baseUrl, path);
        final _HttpResult result;
        try {
          result = await _request(uri);
        } catch (error) {
          failures.add('GET $uri failed: $error');
          continue;
        }
        if (!result.isSuccess) {
          failures.add(result.describe());
          continue;
        }
        try {
          return _decodeConfig(result);
        } on XrpConfigException catch (error) {
          failures.add(error.message);
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
  }) async {
    final body = const JsonEncoder.withIndent('  ').convert(config);
    final failures = <String>[];
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
}

String _preview(String value, {int maxLength = 300}) {
  final singleLine = value.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (singleLine.length <= maxLength) return singleLine;
  return '${singleLine.substring(0, maxLength)}...';
}

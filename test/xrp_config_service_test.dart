import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xrp_flasher/src/models.dart';
import 'package:xrp_flasher/src/xrp_config_service.dart';

void main() {
  test('merges AP and STA config while preserving unrelated keys', () {
    final current = <String, Object?>{
      'configVersion': 3,
      'network': {
        'defaultAP': {
          'ssid': 'XRP-1355-8775',
          'password': 'xrp-wpilib',
          'channel': 6,
        },
        'networkList': [
          {'ssid': 'Old', 'password': 'Password123'},
        ],
        'mode': 'AP',
      },
      'motors': {'left': 1},
    };

    final next = XrpConfigService().buildConfig(
      current,
      RobotCredentials.defaults('12'),
    );

    expect(next['configVersion'], 3);
    expect(next['motors'], {'left': 1});

    final network = next['network'] as Map<String, Object?>;
    expect(network['mode'], 'STA');
    expect(network['defaultAP'], {
      'ssid': 'XR_12',
      'password': 'XRP_Robot_12',
      'channel': 6,
    });
    expect(network['networkList'], [
      {'ssid': 'XRC-AP', 'password': 'xrc-psc-ap'},
    ]);
  });

  test(
    'reads, writes, and verifies config through firmware endpoints',
    () async {
      final requests = <String>[];
      Map<String, Object?>? savedConfig;
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final subscription = server.listen((request) async {
        requests.add('${request.method} ${request.uri.path}');
        if (request.method == 'GET' && request.uri.path == '/getconfig') {
          request.response.headers.contentType = ContentType.json;
          request.response.write(jsonEncode(savedConfig ?? _defaultConfig()));
        } else if (request.method == 'POST' &&
            request.uri.path == '/saveconfig') {
          savedConfig =
              jsonDecode(await utf8.decoder.bind(request).join())
                  as Map<String, Object?>;
          expect(request.headers.contentType?.mimeType, 'text/json');
          request.response.write('OK');
        } else {
          request.response.statusCode = HttpStatus.notFound;
        }
        await request.response.close();
      });
      addTearDown(() async {
        await subscription.cancel();
        await server.close(force: true);
      });

      await XrpConfigService().configure(
        credentials: RobotCredentials.defaults('7'),
        originalApSsid: 'XRP-a80a-0f16',
        originalApPassword: 'xrp-wpilib',
        baseUrl: 'http://${server.address.host}:${server.port}',
        connectWifi: false,
      );

      expect(requests, [
        'GET /getconfig',
        'POST /saveconfig',
        'GET /getconfig',
      ]);
      final network = savedConfig!['network'] as Map<String, Object?>;
      expect(network['mode'], 'STA');
      expect(network['defaultAP'], {
        'ssid': 'XR_7',
        'password': 'XRP_Robot_7',
        'channel': 1,
      });
    },
  );

  test('does not report saved when read-back config does not match', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final subscription = server.listen((request) async {
      if (request.method == 'GET' && request.uri.path == '/getconfig') {
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode(_defaultConfig()));
      } else if (request.method == 'POST' &&
          request.uri.path == '/saveconfig') {
        await utf8.decoder.bind(request).join();
        request.response.write('OK');
      } else {
        request.response.statusCode = HttpStatus.notFound;
      }
      await request.response.close();
    });
    addTearDown(() async {
      await subscription.cancel();
      await server.close(force: true);
    });

    await expectLater(
      XrpConfigService().configure(
        credentials: RobotCredentials.defaults('7'),
        originalApSsid: 'XRP-a80a-0f16',
        originalApPassword: 'xrp-wpilib',
        baseUrl: 'http://${server.address.host}:${server.port}',
        connectWifi: false,
      ),
      throwsA(
        isA<XrpConfigException>().having(
          (error) => error.message,
          'message',
          contains('Saved config verification failed'),
        ),
      ),
    );
  });

  test('retries empty config response before failing', () async {
    var reads = 0;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final subscription = server.listen((request) async {
      if (request.method == 'GET' && request.uri.path == '/getconfig') {
        reads++;
        if (reads == 1) {
          request.response.write('');
        } else {
          request.response.headers.contentType = ContentType.json;
          request.response.write(jsonEncode(_defaultConfig()));
        }
      } else {
        request.response.statusCode = HttpStatus.notFound;
      }
      await request.response.close();
    });
    addTearDown(() async {
      await subscription.cancel();
      await server.close(force: true);
    });

    final config = await XrpConfigService().getConfig(
      baseUrl: 'http://${server.address.host}:${server.port}',
      attempts: 2,
      retryDelay: Duration.zero,
    );

    expect(reads, 2);
    expect(config['configVersion'], 1);
  });

  test('repairs empty config by posting a fixed-length JSON body', () async {
    var reads = 0;
    var saveContentLength = -1;
    var transferEncoding = '';
    Map<String, Object?>? savedConfig;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final subscription = server.listen((request) async {
      if (request.method == 'GET' && request.uri.path == '/getconfig') {
        reads++;
        if (savedConfig == null) {
          request.response.write('');
        } else {
          request.response.headers.contentType = ContentType.json;
          request.response.write(jsonEncode(savedConfig));
        }
      } else if (request.method == 'POST' &&
          request.uri.path == '/saveconfig') {
        saveContentLength = request.contentLength;
        transferEncoding = request.headers.value('transfer-encoding') ?? '';
        savedConfig =
            jsonDecode(await utf8.decoder.bind(request).join())
                as Map<String, Object?>;
        request.response.write('OK');
      } else {
        request.response.statusCode = HttpStatus.notFound;
      }
      await request.response.close();
    });
    addTearDown(() async {
      await subscription.cancel();
      await server.close(force: true);
    });

    await XrpConfigService().configure(
      credentials: RobotCredentials.defaults('25'),
      originalApSsid: 'XRP-923c-8bea',
      originalApPassword: 'xrp-wpilib',
      baseUrl: 'http://${server.address.host}:${server.port}',
      connectWifi: false,
    );

    expect(reads, greaterThanOrEqualTo(2));
    expect(saveContentLength, greaterThan(0));
    expect(transferEncoding, isEmpty);
    final network = savedConfig!['network'] as Map<String, Object?>;
    expect(network['mode'], 'STA');
    expect(network['defaultAP'], {
      'ssid': 'XR_25',
      'password': 'XRP_Robot_25',
      'channel': 1,
    });
  });

  test(
    'reports invalid config response with endpoint and body preview',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final subscription = server.listen((request) async {
        request.response.write('not json');
        await request.response.close();
      });
      addTearDown(() async {
        await subscription.cancel();
        await server.close(force: true);
      });

      await expectLater(
        XrpConfigService().getConfig(
          baseUrl: 'http://${server.address.host}:${server.port}',
          attempts: 1,
          retryDelay: Duration.zero,
        ),
        throwsA(
          isA<XrpConfigException>().having(
            (error) => error.message,
            'message',
            allOf(contains('Could not read XRP config'), contains('not json')),
          ),
        ),
      );
    },
  );
}

Map<String, Object?> _defaultConfig() {
  return {
    'configVersion': 1,
    'network': {
      'defaultAP': {'ssid': 'XRP-a80a-0f16', 'password': 'xrp-wpilib'},
      'networkList': [
        {'ssid': 'Test Network', 'password': 'Test Password'},
      ],
      'mode': 'AP',
    },
  };
}

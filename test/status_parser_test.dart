import 'package:flutter_test/flutter_test.dart';
import 'package:xrp_flasher/src/status_parser.dart';

void main() {
  test('parses XRP status sample', () {
    const sample = '''
Version: 2.1.0

Chip ID: 1355-8775
WiFi Mode: AP
AP SSID: XRP-1355-8775
AP PASS: xrp-wpilib
IP Address: 192.168.42.1
''';

    final status = const XrpStatusParser().parse(sample);

    expect(status.version, '2.1.0');
    expect(status.chipId, '1355-8775');
    expect(status.wifiMode, 'AP');
    expect(status.apSsid, 'XRP-1355-8775');
    expect(status.apPass, 'xrp-wpilib');
    expect(status.ipAddress, '192.168.42.1');
  });

  test('keeps raw text and tolerates missing fields', () {
    const sample = 'Version: 2.1.0\n';

    final status = const XrpStatusParser().parse(sample);

    expect(status.version, '2.1.0');
    expect(status.apSsid, isNull);
    expect(status.rawText, sample);
  });
}

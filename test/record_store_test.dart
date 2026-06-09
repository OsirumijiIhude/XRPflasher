import 'package:flutter_test/flutter_test.dart';
import 'package:xrp_flasher/src/models.dart';

void main() {
  test('robot text includes default SSID and target credentials', () {
    final record = RobotRecord(
      id: 'id',
      stage: DeviceStage.recorded,
      firstSeen: DateTime.utc(2026, 1, 1),
      updatedAt: DateTime.utc(2026, 1, 1, 0, 1),
      status: const XrpStatus(
        version: '2.1.0',
        chipId: '1355-8775',
        wifiMode: 'AP',
        apSsid: 'XRP-1355-8775',
        apPass: 'xrp-wpilib',
        ipAddress: '192.168.42.1',
        rawText: 'raw',
      ),
      credentials: RobotCredentials.defaults('5'),
    );

    final text = record.toText();

    expect(text, contains('Default XRP SSID: XRP-1355-8775'));
    expect(text, contains('Target AP SSID: XR_5'));
    expect(text, contains('STA SSID: XRC-AP'));
  });
}

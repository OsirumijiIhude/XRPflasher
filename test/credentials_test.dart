import 'package:flutter_test/flutter_test.dart';
import 'package:xrp_flasher/src/models.dart';

void main() {
  test('generates default credentials from robot number', () {
    final credentials = RobotCredentials.defaults('007');

    expect(credentials.apSsid, 'XR_007');
    expect(credentials.apPassword, 'XRP_Robot_007');
    expect(credentials.staSsid, 'XRC-AP');
    expect(credentials.staPassword, 'xrc-psc-ap');
  });

  test('robot numbers start at one with no app-level maximum', () {
    expect(RobotNumberRules.validate('1', required: true), isNull);
    expect(RobotNumberRules.validate('999999999999999999999'), isNull);
    expect(RobotNumberRules.validate('0', required: true), isNotNull);
    expect(RobotNumberRules.validate('', required: true), isNotNull);
  });

  test('rejects invalid robot number defaults', () {
    expect(() => RobotCredentials.defaults('0'), throwsArgumentError);
  });
}

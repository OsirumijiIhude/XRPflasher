import 'package:flutter_test/flutter_test.dart';
import 'package:xrp_flasher/src/models.dart';

void main() {
  test('detects current and RP2350 bootloader labels', () {
    for (final label in ['RPI-RP2', 'RP2350', 'RP23501', 'rp23502']) {
      final volume = DetectedVolume(
        source: '/dev/test',
        mountPath: '/run/media/osi/$label',
        label: label,
      );

      expect(volume.isBootloader, isTrue, reason: label);
      expect(volume.isPicodisk, isFalse, reason: label);
    }
  });

  test('detects PICODISK separately from bootloader volumes', () {
    for (final label in ['PICODISK', 'PICODISK1']) {
      final volume = DetectedVolume(
        source: '/dev/test',
        mountPath: '/run/media/osi/$label',
        label: label,
      );

      expect(volume.isPicodisk, isTrue, reason: label);
      expect(volume.isBootloader, isFalse, reason: label);
    }
  });

  test('tracks unmounted block devices by device path', () {
    const volume = DetectedVolume(
      source: '/dev/sda1',
      mountPath: '',
      label: 'RP2350',
      devicePath: '/dev/sda1',
    );

    expect(volume.isMounted, isFalse);
    expect(volume.location, '/dev/sda1');
    expect(volume.identity, '/dev/sda1');
  });
}

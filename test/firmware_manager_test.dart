import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xrp_flasher/src/firmware_manager.dart';

void main() {
  test('verifies valid UF2 block structure', () async {
    final temp = await Directory.systemTemp.createTemp('xrp-uf2-test-');
    addTearDown(() => temp.delete(recursive: true));
    final file = File('${temp.path}/firmware.uf2');
    await file.writeAsBytes(_fakeUf2(blocks: 2));

    final result = await FirmwareManager().verifyUf2File(file.path);

    expect(result.bytes, 1024);
    expect(result.blockCount, 2);
  });

  test('rejects truncated UF2 file', () async {
    final temp = await Directory.systemTemp.createTemp('xrp-uf2-test-');
    addTearDown(() => temp.delete(recursive: true));
    final file = File('${temp.path}/firmware.uf2');
    await file.writeAsBytes(_fakeUf2(blocks: 1).sublist(0, 511));

    await expectLater(
      FirmwareManager().verifyUf2File(file.path),
      throwsA(isA<StateError>()),
    );
  });
}

Uint8List _fakeUf2({required int blocks}) {
  final bytes = Uint8List(blocks * 512);
  final data = ByteData.sublistView(bytes);
  for (var block = 0; block < blocks; block++) {
    final offset = block * 512;
    data.setUint32(offset, 0x0a324655, Endian.little);
    data.setUint32(offset + 4, 0x9e5d5157, Endian.little);
    data.setUint32(offset + 16, 256, Endian.little);
    data.setUint32(offset + 20, block, Endian.little);
    data.setUint32(offset + 24, blocks, Endian.little);
    data.setUint32(offset + 508, 0x0ab16f30, Endian.little);
  }
  return bytes;
}

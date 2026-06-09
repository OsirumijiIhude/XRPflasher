import 'dart:convert';
import 'dart:io';

import 'models.dart';

class RecordStore {
  const RecordStore();

  String defaultOutputDirectory() {
    final home = Platform.environment['HOME'] ?? Directory.current.path;
    return '$home/XRPFlasher/robots';
  }

  Future<void> saveAll(
    String outputDirectory,
    Iterable<RobotRecord> records,
  ) async {
    final directory = Directory(outputDirectory);
    await directory.create(recursive: true);
    final encoder = const JsonEncoder.withIndent('  ');
    final list = records.map((record) => record.toJson()).toList();
    await File(
      '${directory.path}/robots.json',
    ).writeAsString(encoder.convert(list));
    for (final record in records) {
      final credentials = record.credentials;
      if (credentials == null || credentials.robotNumber.trim().isEmpty) {
        continue;
      }
      await File(
        '${directory.path}/XR_${credentials.robotNumber}.txt',
      ).writeAsString(record.toText());
    }
  }
}

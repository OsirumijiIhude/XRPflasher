import 'models.dart';

class XrpStatusParser {
  const XrpStatusParser();

  XrpStatus parse(String text) {
    return XrpStatus(
      version: _field(text, 'Version'),
      chipId: _field(text, 'Chip ID'),
      wifiMode: _field(text, 'WiFi Mode'),
      apSsid: _field(text, 'AP SSID'),
      apPass: _field(text, 'AP PASS'),
      ipAddress: _field(text, 'IP Address'),
      rawText: text,
    );
  }

  String? _field(String text, String name) {
    final pattern = RegExp(
      '^\\s*${RegExp.escape(name)}\\s*:\\s*(.+?)\\s*\$',
      multiLine: true,
      caseSensitive: false,
    );
    final match = pattern.firstMatch(text);
    final value = match?.group(1)?.trim();
    return value == null || value.isEmpty ? null : value;
  }
}

import 'package:meta/meta.dart';

enum HidMouseButton { left, right, middle }

@immutable
class HidConnectionState {
  const HidConnectionState({required this.connected, this.deviceName});

  final bool connected;
  final String? deviceName;

  Map<String, Object?> toJson() => {
        'connected': connected,
        'device_name': deviceName,
      };
}

abstract class HidAdapter {
  Future<void> connect();
  Future<void> disconnect();

  /// Types literal text on the paired host.
  Future<void> sendKeyText(String text);

  /// Moves mouse cursor by a relative delta.
  Future<void> sendMouseMove({required int dx, required int dy});

  Future<void> sendClick(HidMouseButton button);

  Future<void> sendLongPress(HidMouseButton button, Duration duration);

  Future<HidConnectionState> getState();
}

class HidException implements Exception {
  HidException(this.code, this.message);

  final String code;
  final String message;

  @override
  String toString() => 'HidException($code): $message';
}

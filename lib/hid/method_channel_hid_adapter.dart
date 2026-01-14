import 'package:flutter/services.dart';

import 'hid_contract.dart';

class MethodChannelHidAdapter implements HidAdapter {
  static const MethodChannel _channel = MethodChannel('pvt/hid');

  @override
  Future<void> connect() async {
    await _invokeVoid('connect');
  }

  @override
  Future<void> disconnect() async {
    await _invokeVoid('disconnect');
  }

  @override
  Future<HidConnectionState> getState() async {
    final result = await _channel.invokeMethod<Object?>('getState');
    if (result is! Map) {
      throw HidException('BAD_STATE', 'Invalid state response from platform.');
    }

    final connected = result['connected'];
    final deviceName = result['deviceName'];
    if (connected is! bool) {
      throw HidException('BAD_STATE', 'Missing "connected" bool.');
    }

    return HidConnectionState(
      connected: connected,
      deviceName: deviceName is String ? deviceName : null,
    );
  }

  @override
  Future<void> sendClick(HidMouseButton button) async {
    // 1=Left, 2=Right, 3=Middle
    final id = button.index + 1;
    await _invokeVoid('sendClick', {'button': id});
  }

  @override
  Future<void> sendLongPress(HidMouseButton button, Duration duration) async {
    final id = button.index + 1;
    await _invokeVoid('sendLongPress', {
      'button': id,
      'duration': duration.inMilliseconds,
    });
  }

  @override
  Future<void> sendKeyText(String text) async {
    await _invokeVoid('sendKeyText', {'text': text});
  }

  @override
  Future<void> sendMouseMove({required int dx, required int dy}) async {
    await _invokeVoid('sendMouseMove', {'dx': dx, 'dy': dy});
  }

  Future<void> _invokeVoid(String method, [Map<String, Object?>? args]) async {
    try {
      await _channel.invokeMethod<void>(method, args);
    } on PlatformException catch (e) {
      throw HidException(e.code, e.message ?? 'Platform error');
    }
  }
}

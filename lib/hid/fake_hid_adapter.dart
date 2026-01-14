import 'hid_contract.dart';

class FakeHidAdapter implements HidAdapter {
  HidConnectionState _state = const HidConnectionState(connected: false);

  final List<Map<String, Object?>> log = [];

  @override
  Future<void> connect() async {
    _state = const HidConnectionState(connected: true, deviceName: 'FAKE');
    log.add({'op': 'connect'});
  }

  @override
  Future<void> disconnect() async {
    _state = const HidConnectionState(connected: false);
    log.add({'op': 'disconnect'});
  }

  @override
  Future<HidConnectionState> getState() async {
    return _state;
  }

  @override
  Future<void> sendClick(HidMouseButton button) async {
    log.add({'op': 'click', 'button': button.name});
  }

  @override
  Future<void> sendKeyText(String text) async {
    log.add({'op': 'type', 'text': text});
  }

  @override
  Future<void> sendMouseMove({required int dx, required int dy}) async {
    log.add({'op': 'move', 'dx': dx, 'dy': dy});
  }
}

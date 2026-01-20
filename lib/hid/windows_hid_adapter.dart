import 'dart:ffi';
import 'dart:io';
import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart';

import 'hid_contract.dart';

class WindowsNativeHidAdapter implements HidAdapter {
  
  @override
  Future<void> connect() async {
    // No-op for local execution
  }

  @override
  Future<void> disconnect() async {
    // No-op
  }

  @override
  Future<HidConnectionState> getState() async {
    return const HidConnectionState(connected: true, deviceName: 'Local Windows PC');
  }

  @override
  Future<void> sendClick(HidMouseButton button) async {
    final input = calloc<INPUT>();
    input.ref.type = INPUT_MOUSE;
    
    int downFlags = 0;
    int upFlags = 0;
    
    switch (button) {
      case HidMouseButton.left:
        downFlags = MOUSEEVENTF_LEFTDOWN;
        upFlags = MOUSEEVENTF_LEFTUP;
        break;
      case HidMouseButton.right:
        downFlags = MOUSEEVENTF_RIGHTDOWN;
        upFlags = MOUSEEVENTF_RIGHTUP;
        break;
      case HidMouseButton.middle:
        downFlags = MOUSEEVENTF_MIDDLEDOWN;
        upFlags = MOUSEEVENTF_MIDDLEUP;
        break;
    }

    // Down
    input.ref.mi.dwFlags = downFlags;
    SendInput(1, input, sizeOf<INPUT>());
    
    await Future.delayed(const Duration(milliseconds: 50));
    
    // Up
    input.ref.mi.dwFlags = upFlags;
    SendInput(1, input, sizeOf<INPUT>());
    
    free(input);
  }

  @override
  Future<void> sendLongPress(HidMouseButton button, Duration duration) async {
     // TODO: Implement precise timing if needed, for now just hold
     // ...
     await sendClick(button); 
  }

  @override
  Future<void> sendKeyText(String text) async {
    for (int i = 0; i < text.length; i++) {
      final char = text[i];
      if (char == '\n') {
          _sendVirtualKey(VK_RETURN);
      } else {
          // Simplified: send char as unicode
          await _sendUnicodeChar(char.codeUnitAt(0));
      }
      await Future.delayed(const Duration(milliseconds: 10));
    }
  }

  Future<void> sendKeyCombo(List<int> vks) async {
    for (final vk in vks) {
      _sendKeyDown(vk);
      await Future.delayed(const Duration(milliseconds: 10));
    }
    for (final vk in vks.reversed) {
      _sendKeyUp(vk);
      await Future.delayed(const Duration(milliseconds: 10));
    }
  }

  Future<void> sendWinR() async {
    const vkR = 0x52; // 'R'
    await sendKeyCombo([VK_LWIN, vkR]);
  }
  
  Future<void> _sendVirtualKey(int vk) async {
    final input = calloc<INPUT>();
    input.ref.type = INPUT_KEYBOARD;
    
    // Down
    input.ref.ki.wVk = vk;
    SendInput(1, input, sizeOf<INPUT>());
    
    // Up
    input.ref.ki.dwFlags = KEYEVENTF_KEYUP;
    SendInput(1, input, sizeOf<INPUT>());
    
    free(input);
  }

  Future<void> sendVirtualKey(int vk) async {
    await _sendVirtualKey(vk);
  }

  void _sendKeyDown(int vk) {
    final input = calloc<INPUT>();
    input.ref.type = INPUT_KEYBOARD;
    input.ref.ki.wVk = vk;
    SendInput(1, input, sizeOf<INPUT>());
    free(input);
  }

  void _sendKeyUp(int vk) {
    final input = calloc<INPUT>();
    input.ref.type = INPUT_KEYBOARD;
    input.ref.ki.wVk = vk;
    input.ref.ki.dwFlags = KEYEVENTF_KEYUP;
    SendInput(1, input, sizeOf<INPUT>());
    free(input);
  }

  Future<void> _sendUnicodeChar(int codeUnit) async {
    final input = calloc<INPUT>();
    input.ref.type = INPUT_KEYBOARD;
    
    // Down
    input.ref.ki.wScan = codeUnit;
    input.ref.ki.dwFlags = KEYEVENTF_UNICODE;
    SendInput(1, input, sizeOf<INPUT>());
    
    // Up
    input.ref.ki.wScan = codeUnit;
    input.ref.ki.dwFlags = KEYEVENTF_UNICODE | KEYEVENTF_KEYUP;
    SendInput(1, input, sizeOf<INPUT>());
    
    free(input);
  }

  @override
  Future<void> sendMouseMove({required int dx, required int dy}) async {
      // NOTE: Inputs are Absolute Coordinates (x, y) not Delta (dx, dy) locally
      // But the interface says dx/dy. 
      // If the mobile app logic sends absolute coordinates to 'sendMouseMove', I should respect that.
      // Checking RobotService: "groundedAction['x'] = centerX.toInt()" -> It sends ABSOLUTE coordinates.
      // So 'dx' is actually 'absolute x' and 'dy' is 'absolute y'.
      
      // Map to screen space (65535 unit space)
      final screenWidth = GetSystemMetrics(SM_CXSCREEN);
      final screenHeight = GetSystemMetrics(SM_CYSCREEN);
      
      final normalizedX = (dx * 65535) ~/ screenWidth;
      final normalizedY = (dy * 65535) ~/ screenHeight;
      
      final input = calloc<INPUT>();
      input.ref.type = INPUT_MOUSE;
      input.ref.mi.dx = normalizedX;
      input.ref.mi.dy = normalizedY;
      input.ref.mi.dwFlags = MOUSEEVENTF_MOVE | MOUSEEVENTF_ABSOLUTE;
      
      SendInput(1, input, sizeOf<INPUT>());
      free(input);
  }
}

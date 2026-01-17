import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../hid/hid_contract.dart';

class HidReconnectionDialog extends StatefulWidget {
  final HidAdapter hid;
  final String errorMessage;

  const HidReconnectionDialog({
    super.key,
    required this.hid,
    required this.errorMessage,
  });

  @override
  State<HidReconnectionDialog> createState() => _HidReconnectionDialogState();
}

class _HidReconnectionDialogState extends State<HidReconnectionDialog> {
  bool _isConnecting = false;
  String? _statusMessage;
  bool _isPermissionError = false;

  @override
  void initState() {
    super.initState();
    _isPermissionError = widget.errorMessage.contains('PERMISSION') || 
                         widget.errorMessage.contains('BLUETOOTH_CONNECT');
    _statusMessage = widget.errorMessage;
  }

  Future<void> _attemptReconnect() async {
    setState(() {
      _isConnecting = true;
      _statusMessage = 'Attempting to reconnect...';
    });

    try {
      await widget.hid.connect();
      setState(() {
        _statusMessage = '✅ Connected successfully!';
        _isConnecting = false;
      });
      
      // Auto-close after success
      await Future.delayed(const Duration(seconds: 1));
      if (mounted) Navigator.of(context).pop(true);
      
    } catch (e) {
      setState(() {
        _statusMessage = '❌ Failed: ${e.toString()}';
        _isConnecting = false;
        _isPermissionError = e.toString().contains('PERMISSION');
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Icon
            Icon(
              _isPermissionError ? Icons.lock_outline : Icons.bluetooth_disabled,
              size: 64,
              color: _isPermissionError ? Colors.orange : Colors.red,
            ),
            const SizedBox(height: 16),
            
            // Title
            Text(
              _isPermissionError ? 'Permission Required' : 'Bluetooth Disconnected',
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 16),
            
            // Status Message
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.grey[100],
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                _statusMessage ?? 'Unknown error',
                style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
                textAlign: TextAlign.center,
              ),
            ),
            const SizedBox(height: 24),
            
            // Instructions
            if (_isPermissionError) ...[
              const Text(
                '📱 Steps to Fix:',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              const Text(
                '1. Go to Android Settings\n'
                '2. Apps → Robot Tester → Permissions\n'
                '3. Enable "Nearby devices" (Bluetooth)\n'
                '4. Return here and tap Reconnect',
                style: TextStyle(fontSize: 13),
              ),
              const SizedBox(height: 16),
              ElevatedButton.icon(
                onPressed: () {
                  // Open app settings
                  const platform = MethodChannel('com.example.physical_visual_tester/settings');
                  platform.invokeMethod('openAppSettings');
                },
                icon: const Icon(Icons.settings),
                label: const Text('Open Settings'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.orange,
                  foregroundColor: Colors.white,
                ),
              ),
            ] else ...[
              const Text(
                '🔄 Reconnection Steps:',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              const Text(
                '1. Ensure Bluetooth is ON on both devices\n'
                '2. On your PC, go to Bluetooth settings\n'
                '3. Find "PVT HID" and click Connect\n'
                '4. Tap Reconnect below',
                style: TextStyle(fontSize: 13),
              ),
            ],
            const SizedBox(height: 24),
            
            // Action Buttons
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                TextButton(
                  onPressed: _isConnecting ? null : () => Navigator.of(context).pop(false),
                  child: const Text('Cancel'),
                ),
                ElevatedButton.icon(
                  onPressed: _isConnecting ? null : _attemptReconnect,
                  icon: _isConnecting 
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                      )
                    : const Icon(Icons.refresh),
                  label: Text(_isConnecting ? 'Connecting...' : 'Reconnect'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.blue,
                    foregroundColor: Colors.white,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../hid/hid_contract.dart';
import '../../hid/method_channel_hid_adapter.dart';

class HidSpikePage extends StatefulWidget {
  const HidSpikePage({super.key});

  @override
  State<HidSpikePage> createState() => _HidSpikePageState();
}

class _HidSpikePageState extends State<HidSpikePage> {
  final HidAdapter _hid = MethodChannelHidAdapter();
  static const MethodChannel _channel = MethodChannel('pvt/hid');

  bool _busy = false;
  String? _error;
  HidConnectionState? _state;
  Map<String, Object?>? _debug;
  List<Map<String, Object?>> _bonded = const [];
  List<String> _eventLog = const [];

  Future<void> _refresh() async {
    try {
      final st = await _hid.getState();
      final dbg = await _channel.invokeMethod<Object?>('getDebugState');
      final dbgMap = dbg is Map ? dbg.cast<String, Object?>() : null;
      final log = await _channel.invokeMethod<Object?>('getEventLog');
      final logList = log is List ? log.whereType<String>().toList(growable: false) : const <String>[];
      setState(() {
        _state = st;
        _debug = dbgMap;
        _eventLog = logList;
      });
    } catch (e) {
      setState(() {
        _error = e.toString();
      });
    }
  }

  Future<void> _refreshBonded() async {
    try {
      final res = await _channel.invokeMethod<Object?>('listBondedDevices');
      if (res is List) {
        setState(() {
          _bonded = res
              .whereType<Map>()
              .map((m) => m.cast<String, Object?>())
              .toList(growable: false);
        });
      }
    } on PlatformException catch (e) {
      setState(() {
        _error = '${e.code}: ${e.message ?? 'listBondedDevices failed'}';
      });
    }
  }

  Future<void> _setLocalName() async {
    setState(() {
      _error = null;
    });
    try {
      await _channel.invokeMethod<void>('setLocalName', {'name': 'PVT HID'});
      await _refresh();
    } on PlatformException catch (e) {
      setState(() {
        _error = '${e.code}: ${e.message ?? 'setLocalName failed'}';
      });
    }
  }

  Future<void> _requestPermissions() async {
    setState(() {
      _error = null;
    });

    try {
      await _channel.invokeMethod<void>('requestPermissions');
    } on PlatformException catch (e) {
      setState(() {
        _error = '${e.code}: ${e.message ?? 'permission request failed'}';
      });
    }
  }

  Future<void> _requestDiscoverable() async {
    setState(() {
      _error = null;
    });

    try {
      await _channel.invokeMethod<void>('requestDiscoverable');
    } on PlatformException catch (e) {
      setState(() {
        _error = '${e.code}: ${e.message ?? 'discoverable request failed'}';
      });
    }
  }

  Future<void> _connectHost(String address) async {
    await _run(() => _channel.invokeMethod<void>('connectHost', {'address': address}));
  }

  Future<void> _disconnectHost() async {
    await _run(() => _channel.invokeMethod<void>('disconnectHost'));
  }

  Future<void> _unbond(String address) async {
    await _run(() async {
      await _channel.invokeMethod<void>('unbondDevice', {'address': address});
      // Small delay to allow system to process unbond before refresh
      await Future<void>.delayed(const Duration(milliseconds: 500));
    });
    // Force refresh
    await _refreshBonded();
  }

  Future<void> _run(Future<void> Function() fn) async {
    if (_busy) return;

    setState(() {
      _busy = true;
      _error = null;
    });

    try {
      await fn();
      await _refresh();
    } catch (e) {
      setState(() {
        _error = e.toString();
      });
    } finally {
      setState(() {
        _busy = false;
      });
    }
  }

  @override
  void initState() {
    super.initState();
    // Best-effort initial refresh.
    _refresh();
    _refreshBonded();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('HID Spike'),
        actions: [
          IconButton(
            tooltip: 'Refresh state',
            onPressed: _busy ? null : _refresh,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text(
            'Goal: phone registers as a Bluetooth HID keyboard, pairs to Windows, and types “abc”.\n\n'
            'Flow (typical): Request permissions → Start/Connect → Pair on Windows Bluetooth settings → Send “abc”.',
          ),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: _busy ? null : _requestPermissions,
            icon: const Icon(Icons.shield),
            label: const Text('Request Bluetooth permissions'),
          ),
          const SizedBox(height: 10),
          OutlinedButton.icon(
            onPressed: _busy ? null : _requestDiscoverable,
            icon: const Icon(Icons.visibility),
            label: const Text('Make discoverable (300s prompt)'),
          ),
          const SizedBox(height: 10),
          OutlinedButton.icon(
            onPressed: _busy ? null : _setLocalName,
            icon: const Icon(Icons.drive_file_rename_outline),
            label: const Text('Set Bluetooth name to “PVT HID”'),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: FilledButton(
                  onPressed: _busy ? null : () => _run(_hid.connect),
                  child: const Text('Start HID'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: OutlinedButton(
                  onPressed: _busy ? null : () => _run(_hid.disconnect),
                  child: const Text('Stop HID'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: _busy ? null : () => _run(() => _hid.sendKeyText('abc')),
            icon: const Icon(Icons.keyboard),
            label: const Text('Send “abc”'),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
             onPressed: _busy ? null : () => _run(() => _hid.sendKeyText('\n')),
             icon: const Icon(Icons.keyboard_return),
             label: const Text('Send Return (Enter)'), 
          ),
          const SizedBox(height: 12),
          _Section(
            title: 'Mouse Control', 
            child: Column(
                children: [
                    Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                            IconButton(onPressed: _busy ? null : () => _run(() => _hid.sendMouseMove(dx: 0, dy: -50)), icon: const Icon(Icons.arrow_upward)),
                        ],
                    ),
                    Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                            IconButton(onPressed: _busy ? null : () => _run(() => _hid.sendMouseMove(dx: -50, dy: 0)), icon: const Icon(Icons.arrow_back)),
                             const SizedBox(width: 20),
                            IconButton(onPressed: _busy ? null : () => _run(() => _hid.sendMouseMove(dx: 50, dy: 0)), icon: const Icon(Icons.arrow_forward)),
                        ],
                    ),
                    Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                            IconButton(onPressed: _busy ? null : () => _run(() => _hid.sendMouseMove(dx: 0, dy: 50)), icon: const Icon(Icons.arrow_downward)),
                        ],
                    ),
                    const Divider(),
                    Row(
                        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                        children: [
                            FilledButton(
                                onPressed: _busy ? null : () => _run(() => _hid.sendClick(HidMouseButton.left)), 
                                child: const Text('Click Left')
                            ),
                            OutlinedButton(
                                onPressed: _busy ? null : () => _run(() => _hid.sendClick(HidMouseButton.right)), 
                                child: const Text('Click Right')
                            ),
                        ],
                    ),
                    const SizedBox(height: 8),
                            FilledButton.tonal(
                                onPressed: _busy ? null : () => _run(() => _hid.sendLongPress(HidMouseButton.left, const Duration(seconds: 2))), 
                                child: const Text('Long Press (2s)')
                            ),
                ],
            ),
          ),
          const SizedBox(height: 10),
          OutlinedButton(
            onPressed: _busy ? null : _disconnectHost,
            child: const Text('Disconnect host'),
          ),
          const SizedBox(height: 12),
          if (_error != null)
            Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          const SizedBox(height: 12),
          _Section(
            title: 'State',
            child: Text(
              const JsonEncoder.withIndent('  ').convert(_state?.toJson()),
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
            ),
          ),
          const SizedBox(height: 12),
          _Section(
            title: 'Debug (Android)',
            child: Text(
              const JsonEncoder.withIndent('  ').convert(_debug),
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
            ),
          ),
          const SizedBox(height: 12),
          _Section(
            title: 'Bonded devices (tap to connect)',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                OutlinedButton.icon(
                  onPressed: _busy ? null : _refreshBonded,
                  icon: const Icon(Icons.refresh),
                  label: const Text('Refresh bonded list'),
                ),
                const SizedBox(height: 8),
                if (_bonded.isEmpty)
                  const Text('No bonded devices (or permission missing).')
                else
                  ..._bonded.map((d) {
                    final name = d['name'] as String?;
                    final address = d['address'] as String?;
                    final conn = d['hidConnectionState'];
                    final bond = d['bondState'];
                    return Card(
                      child: ListTile(
                        title: Text(name ?? '(no name)'),
                        subtitle: Text(
                          '${address ?? '(no address)'}  •  bond=$bond  •  hidState=$conn',
                        ),
                      trailing: PopupMenuButton(
                        itemBuilder: (context) => [
                          const PopupMenuItem(
                            value: 'connect',
                            child: Text('Connect'),
                          ),
                          const PopupMenuItem(
                            value: 'forget',
                            child: Text('Forget/Unbond'),
                          ),
                        ],
                        onSelected: (value) {
                          if (address == null) return;
                          if (value == 'connect') {
                            _connectHost(address);
                          } else if (value == 'forget') {
                            _unbond(address);
                          }
                        },
                      ),
                      onTap: (_busy || address == null)
                          ? null
                          : () => _connectHost(address),
                      ),
                    );
                  }),
              ],
            ),
          ),
          const SizedBox(height: 12),
          _Section(
            title: 'Event log (latest first)',
            child: SizedBox(
              height: 140,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: Theme.of(context)
                      .colorScheme
                      .surface
                      .withValues(alpha: 0.6),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: ListView.builder(
                  padding: const EdgeInsets.all(10),
                  itemCount: _eventLog.length,
                  itemBuilder: (context, i) {
                    return Text(
                      _eventLog[i],
                      style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
                    );
                  },
                ),
              ),
            ),
          ),
          const SizedBox(height: 12),
          const _Section(
            title: 'Windows pairing notes',
            child: Text(
              '- Windows Settings → Bluetooth & devices → Add device → Bluetooth\n'
              '- Look for the Android device name (may appear as “PVT HID”)\n'
              '- Pair/Connect, then click into a text field and tap Send “abc”\n',
            ),
          ),
        ],
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(title, style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 8),
            child,
          ],
        ),
      ),
    );
  }
}

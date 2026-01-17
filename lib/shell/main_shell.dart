import 'dart:async';

import 'package:flutter/material.dart';

import '../hid/method_channel_hid_adapter.dart';
import '../hid/hid_reconnection_dialog.dart';
import 'dashboard_sheet.dart';
import 'eye_actions_log_view.dart';
import '../robot/robot_tester_page.dart';
import '../spikes/vision/vision_spike_page.dart';

class MainShell extends StatefulWidget {
  const MainShell({super.key});

  @override
  State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell> {
  final _hid = MethodChannelHidAdapter();
  bool _connecting = false;
  String? _connectError;

  @override
  void initState() {
    super.initState();
    _autoConnect();
  }

  Future<void> _autoConnect() async {
    setState(() {
      _connecting = true;
      _connectError = null;
    });

    try {
      // Small delay to ensure platform channel is ready and UI is up
      await Future.delayed(const Duration(milliseconds: 500));
      await _hid.connect();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('✅ HID Connected'),
            backgroundColor: Colors.green,
            duration: Duration(seconds: 2),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _connectError = e.toString();
        });
        
        // Show reconnection dialog instead of just a snackbar
        await showDialog(
          context: context,
          barrierDismissible: false,
          builder: (ctx) => HidReconnectionDialog(
            hid: _hid,
            errorMessage: e.toString(),
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _connecting = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Physical Visual Tester'),
        actions: [
          IconButton(
            tooltip: 'Robot Mode',
            icon: const Icon(Icons.smart_toy),
            onPressed: () {
               // Launch Robot Tester
               Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const RobotTesterPage()),
               );
            },
          ),
        ],
      ),
      body: Stack(
        children: [
          // 1. The "Eye" View (Background, always visible but covered by sheet when expanded)
          const Positioned.fill(
            child: EyeActionsLogView(),
          ),

          // 2. Collapsible Dashboard (The "Main Screen")
          DraggableScrollableSheet(
            initialChildSize: 0.15,
            minChildSize: 0.1,
            maxChildSize: 0.9,
            builder: (context, scrollController) {
              return DashboardSheet(controller: scrollController);
            },
          ),
        ],
      ),
    );
  }
}

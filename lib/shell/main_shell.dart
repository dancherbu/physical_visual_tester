import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../hid/method_channel_hid_adapter.dart';
import 'dashboard_sheet.dart';
import 'eye_actions_log_view.dart';

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
          const SnackBar(content: Text('HID: Auto-connect signal sent.')),
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _connectError = e.toString();
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('HID Auto-connect failed: ${e.toString()}'),
            backgroundColor: Colors.red,
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

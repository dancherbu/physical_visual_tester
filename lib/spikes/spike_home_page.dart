import 'package:flutter/material.dart';

import 'brain/decision_spike_page.dart';
import 'hid/hid_spike_page.dart';
import 'vision/vision_spike_page.dart';

class SpikeHomePage extends StatelessWidget {
  const SpikeHomePage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('PVT Spikes'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _NavTile(
            title: 'Vision Spike (Camera + OCR)',
            subtitle: 'Manual capture + ML Kit text blocks + bbox overlay',
            onTap: () {
              Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const VisionSpikePage()),
              );
            },
          ),
          _NavTile(
            title: 'Decision Spike (Ollama JSON)',
            subtitle: 'Strict JSON-only decision with allow-listed actions',
            onTap: () {
              Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const DecisionSpikePage()),
              );
            },
          ),
          _NavTile(
            title: 'HID Spike (Bluetooth Keyboard)',
            subtitle: 'Start HID + pair to Windows + send “abc”',
            onTap: () {
              Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const HidSpikePage()),
              );
            },
          ),
        ],
      ),
    );
  }
}

class _NavTile extends StatelessWidget {
  const _NavTile({
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: ListTile(
        title: Text(title),
        subtitle: Text(subtitle),
        trailing: const Icon(Icons.chevron_right),
        onTap: onTap,
      ),
    );
  }
}

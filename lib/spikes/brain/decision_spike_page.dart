import 'dart:convert';

import 'package:flutter/material.dart';

import '../../vision/ocr_models.dart';
import '../spike_store.dart';
import 'guarded_decider.dart';
import 'ollama_client.dart';
import 'pvt_actions.dart';

class DecisionSpikePage extends StatefulWidget {
  const DecisionSpikePage({super.key});

  @override
  State<DecisionSpikePage> createState() => _DecisionSpikePageState();
}

class _DecisionSpikePageState extends State<DecisionSpikePage> {
  final _baseUrlController = TextEditingController(text: 'http://localhost:11434');
  final _modelController = TextEditingController(text: 'llama3.2:1b');
  final _goalController = TextEditingController(text: 'Handle any error dialog safely');

  bool _busy = false;
  String? _error;

  PvtAction? _lastAction;
  String? _lastRaw;
  bool _retried = false;

  // A tiny built-in sample UIState so you can test without camera.
  late UIState _uiState = SpikeStore.lastUiState ?? _sampleUiState();
  bool _usingVision = SpikeStore.lastUiState != null;

  final List<Map<String, Object?>> _recentActions = [];

  @override
  void dispose() {
    _baseUrlController.dispose();
    _modelController.dispose();
    _goalController.dispose();
    super.dispose();
  }

  Future<void> _decide() async {
    if (_busy) return;

    setState(() {
      _busy = true;
      _error = null;
      _lastAction = null;
      _lastRaw = null;
      _retried = false;
    });

    OllamaClient? client;
    try {
      client = OllamaClient(
        baseUrl: Uri.parse(_baseUrlController.text.trim()),
        model: _modelController.text.trim(),
      );
      final decider = GuardedDecider(ollama: client);

      final result = await decider.decideNext(
        goal: _goalController.text,
        uiState: _uiState,
        recentActions: _recentActions.reversed.toList(growable: false),
      );

      setState(() {
        _lastAction = result.action;
        _lastRaw = result.raw;
        _retried = result.retried;
      });

      _recentActions.add({
        'ts': DateTime.now().toIso8601String(),
        'action': result.action.toJson(),
      });
    } catch (e) {
      setState(() {
        _error = e.toString();
      });
    } finally {
      client?.close();
      setState(() {
        _busy = false;
      });
    }
  }

  void _loadSampleDialog() {
    setState(() {
      _uiState = _sampleUiState();
      _usingVision = false;
      _error = null;
      _lastAction = null;
      _lastRaw = null;
      _retried = false;
    });
  }

  void _loadLastVision() {
    final last = SpikeStore.lastUiState;
    if (last == null) {
      setState(() {
        _error = 'No Vision UIState captured yet. Open Vision Spike and tap Capture + OCR.';
      });
      return;
    }

    setState(() {
      _uiState = last;
      _usingVision = true;
      _error = null;
      _lastAction = null;
      _lastRaw = null;
      _retried = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final lastAction = _lastAction;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Decision Spike (Ollama)'),
        actions: [
          IconButton(
            tooltip: 'Use last Vision UIState',
            onPressed: _busy ? null : _loadLastVision,
            icon: const Icon(Icons.visibility),
          ),
          IconButton(
            tooltip: 'Load sample dialog UIState',
            onPressed: _busy ? null : _loadSampleDialog,
            icon: const Icon(Icons.auto_fix_high),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text(
            'This spike calls Ollama only when you press Decide. '
            'It enforces a strict JSON-only allow-listed action schema.',
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _baseUrlController,
            decoration: const InputDecoration(
              labelText: 'Ollama base URL',
              hintText: 'http://localhost:11434',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _modelController,
            decoration: const InputDecoration(
              labelText: 'Model',
              hintText: 'llama3.2:1b',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _goalController,
            maxLines: 2,
            decoration: const InputDecoration(
              labelText: 'Goal',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: _busy ? null : _decide,
            icon: _busy
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.play_arrow),
            label: const Text('Decide'),
          ),
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ],
          const SizedBox(height: 12),
          _Section(
            title: _usingVision ? 'Current UIState (from Vision)' : 'Current UIState (sample)',
            child: Text(
              _uiState.toPrettyJson(),
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
            ),
          ),
          const SizedBox(height: 12),
          _Section(
            title: 'Last decision',
            trailing: lastAction == null
                ? null
                : Text(
                    _retried ? 'retried' : 'ok',
                    style: TextStyle(
                      color: _retried
                          ? Theme.of(context).colorScheme.tertiary
                          : Theme.of(context).colorScheme.primary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
            child: lastAction == null
                ? const Text('No decision yet.')
                : Text(
                    const JsonEncoder.withIndent('  ').convert(lastAction.toJson()),
                    style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                  ),
          ),
          const SizedBox(height: 12),
          _Section(
            title: 'Raw model output',
            child: Text(
              (_lastRaw ?? '').trim().isEmpty ? '(empty)' : _lastRaw!.trim(),
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
            ),
          ),
          const SizedBox(height: 12),
          _Section(
            title: 'Recent actions (last 5)',
            child: Text(
              const JsonEncoder.withIndent('  ').convert(
                _recentActions.reversed.take(5).toList(growable: false),
              ),
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }

  UIState _sampleUiState() {
    final blocks = <OcrBlock>[
      const OcrBlock(
        text: 'Error',
        boundingBox: BoundingBox(left: 140, top: 220, right: 280, bottom: 260),
        confidence: 0.9,
      ),
      const OcrBlock(
        text: 'Failed to connect',
        boundingBox: BoundingBox(left: 110, top: 270, right: 420, bottom: 310),
        confidence: 0.8,
      ),
      const OcrBlock(
        text: 'Retry',
        boundingBox: BoundingBox(left: 120, top: 360, right: 210, bottom: 410),
        confidence: 0.7,
      ),
      const OcrBlock(
        text: 'Cancel',
        boundingBox: BoundingBox(left: 280, top: 360, right: 390, bottom: 410),
        confidence: 0.7,
      ),
    ];

    final derived = const DerivedFlags(
      hasModalCandidate: true,
      hasErrorCandidate: true,
      modalKeywords: ['cancel', 'retry'],
    );

    return UIState(
      ocrBlocks: blocks,
      imageWidth: 540,
      imageHeight: 960,
      derived: derived,
      createdAt: DateTime.now(),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.child, this.trailing});

  final String title;
  final Widget child;
  final Widget? trailing;

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
            Row(
              children: [
                Expanded(
                  child: Text(
                    title,
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                ),
                if (trailing != null) trailing!,
              ],
            ),
            const SizedBox(height: 8),
            child,
          ],
        ),
      ),
    );
  }
}

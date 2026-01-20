import 'package:flutter/material.dart';
import 'robot_service.dart';
import '../vision/ocr_models.dart';

/// Page to view and execute saved Sequences (Task Chains).
class SequencesPage extends StatefulWidget {
  const SequencesPage({
    super.key, 
    required this.robot,
    this.onExecuteAction,
    this.onCaptureState,
  });

  final RobotService robot;
  
  /// Callback to execute an action via HID (click, type, etc.)
  /// If null, execution will be simulated.
  final Future<void> Function(Map<String, dynamic> action)? onExecuteAction;
  
  /// Callback to capture current screen state (for grounding actions).
  /// If null, grounding will be skipped.
  final Future<UIState?> Function()? onCaptureState;

  @override
  State<SequencesPage> createState() => _SequencesPageState();
}

class _SequencesPageState extends State<SequencesPage> {
  List<String> _sequences = [];
  bool _loading = true;
  String? _selectedSequence;
  List<SequenceStep> _steps = [];
  bool _loadingSteps = false;

  // Execution State
  bool _executing = false;
  int _currentStep = 0;
  int _totalSteps = 0;
  String _executionStatus = '';

  @override
  void initState() {
    super.initState();
    _loadSequences();
  }

  Future<void> _loadSequences() async {
    setState(() => _loading = true);
    try {
      final seqs = await widget.robot.listSequences();
      setState(() {
        _sequences = seqs;
        _loading = false;
      });
    } catch (e) {
      setState(() {
        _loading = false;
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to load sequences: $e')),
        );
      }
    }
  }

  Future<void> _selectSequence(String seqId) async {
    setState(() {
      _selectedSequence = seqId;
      _loadingSteps = true;
      _steps = [];
    });

    try {
      final steps = await widget.robot.getSequence(seqId);
      setState(() {
        _steps = steps;
        _loadingSteps = false;
      });
    } catch (e) {
      setState(() => _loadingSteps = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to load steps: $e')),
        );
      }
    }
  }

  Future<void> _executeSequence() async {
    if (_selectedSequence == null) return;

    setState(() {
      _executing = true;
      _currentStep = 0;
      _totalSteps = _steps.length;
      _executionStatus = 'Starting...';
    });

    // Show warning dialog
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Execute Sequence?'),
        content: Text(
          'This will execute "${_selectedSequence}" with ${_steps.length} steps.\n\n'
          '⚠️ The robot will take control of your mouse and keyboard!\n\n'
          'Make sure the target application is visible.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.green),
            child: const Text('Execute'),
          ),
        ],
      ),
    );

    if (confirmed != true) {
      setState(() => _executing = false);
      return;
    }

    // Use provided callbacks for real execution, or simulate
    final executeAction = widget.onExecuteAction ?? (action) async {
      debugPrint('[SEQUENCE EXEC - SIMULATED] Action: $action');
      await Future.delayed(const Duration(milliseconds: 500));
    };

    final captureState = widget.onCaptureState ?? () async => null;

    try {
      await for (final event in widget.robot.executeSequence(
        sequenceId: _selectedSequence!,
        executeAction: executeAction,
        captureState: captureState,
      )) {
        setState(() {
          _executionStatus = event.message;
          _currentStep = event.currentStep ?? _currentStep;
          _totalSteps = event.totalSteps ?? _totalSteps;
        });

        if (event.type == SequenceEventType.error) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('❌ ${event.message}'),
                backgroundColor: Colors.red,
              ),
            );
          }
          break;
        }

        if (event.type == SequenceEventType.completed) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('✅ ${event.message}'),
                backgroundColor: Colors.green,
              ),
            );
          }
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Execution failed: $e')),
        );
      }
    } finally {
      setState(() => _executing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('📋 Saved Sequences'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _loadSequences,
            tooltip: 'Refresh',
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Row(
              children: [
                // Left: Sequence List
                SizedBox(
                  width: 280,
                  child: Card(
                    margin: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Container(
                          padding: const EdgeInsets.all(12),
                          color: Theme.of(context).primaryColor.withValues(alpha: 0.1),
                          child: Text(
                            'Sequences (${_sequences.length})',
                            style: const TextStyle(fontWeight: FontWeight.bold),
                          ),
                        ),
                        Expanded(
                          child: _sequences.isEmpty
                              ? const Center(
                                  child: Padding(
                                    padding: EdgeInsets.all(16),
                                    child: Text(
                                      'No sequences saved yet.\n\n'
                                      'Sequences are created when you record a multi-step task.',
                                      textAlign: TextAlign.center,
                                      style: TextStyle(color: Colors.grey),
                                    ),
                                  ),
                                )
                              : ListView.builder(
                                  itemCount: _sequences.length,
                                  itemBuilder: (ctx, i) {
                                    final seq = _sequences[i];
                                    final isSelected = seq == _selectedSequence;
                                    return ListTile(
                                      leading: Icon(
                                        Icons.play_circle_outline,
                                        color: isSelected ? Colors.green : null,
                                      ),
                                      title: Text(seq),
                                      selected: isSelected,
                                      onTap: () => _selectSequence(seq),
                                    );
                                  },
                                ),
                        ),
                      ],
                    ),
                  ),
                ),

                // Right: Sequence Details
                Expanded(
                  child: Card(
                    margin: const EdgeInsets.fromLTRB(0, 12, 12, 12),
                    child: _selectedSequence == null
                        ? const Center(
                            child: Text(
                              'Select a sequence to view its steps.',
                              style: TextStyle(color: Colors.grey),
                            ),
                          )
                        : Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              // Header
                              Container(
                                padding: const EdgeInsets.all(16),
                                decoration: BoxDecoration(
                                  color: Colors.green.withValues(alpha: 0.1),
                                  border: const Border(
                                    bottom: BorderSide(color: Colors.green),
                                  ),
                                ),
                                child: Row(
                                  children: [
                                    const Icon(Icons.playlist_play, color: Colors.green),
                                    const SizedBox(width: 8),
                                    Expanded(
                                      child: Text(
                                        _selectedSequence!,
                                        style: const TextStyle(
                                          fontSize: 18,
                                          fontWeight: FontWeight.bold,
                                        ),
                                      ),
                                    ),
                                    if (!_executing)
                                      ElevatedButton.icon(
                                        onPressed: _steps.isEmpty ? null : _executeSequence,
                                        icon: const Icon(Icons.play_arrow),
                                        label: const Text('Execute'),
                                        style: ElevatedButton.styleFrom(
                                          backgroundColor: Colors.green,
                                          foregroundColor: Colors.white,
                                        ),
                                      ),
                                  ],
                                ),
                              ),

                              // Execution Progress
                              if (_executing)
                                Padding(
                                  padding: const EdgeInsets.all(16),
                                  child: Column(
                                    children: [
                                      LinearProgressIndicator(
                                        value: _totalSteps > 0
                                            ? _currentStep / _totalSteps
                                            : null,
                                      ),
                                      const SizedBox(height: 8),
                                      Text(
                                        _executionStatus,
                                        style: const TextStyle(
                                          fontStyle: FontStyle.italic,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),

                              // Steps List
                              Expanded(
                                child: _loadingSteps
                                    ? const Center(child: CircularProgressIndicator())
                                    : _steps.isEmpty
                                        ? const Center(
                                            child: Text('No steps in this sequence.'),
                                          )
                                        : ListView.builder(
                                            padding: const EdgeInsets.all(8),
                                            itemCount: _steps.length,
                                            itemBuilder: (ctx, i) {
                                              final step = _steps[i];
                                              final isCurrent = _executing && i == _currentStep;
                                              return Card(
                                                color: isCurrent
                                                    ? Colors.amber.withValues(alpha: 0.2)
                                                    : null,
                                                child: ListTile(
                                                  leading: CircleAvatar(
                                                    backgroundColor: isCurrent
                                                        ? Colors.amber
                                                        : Colors.grey[300],
                                                    child: Text(
                                                      '${step.stepOrder + 1}',
                                                      style: TextStyle(
                                                        color: isCurrent
                                                            ? Colors.white
                                                            : Colors.black,
                                                      ),
                                                    ),
                                                  ),
                                                  title: Text(step.goal),
                                                  subtitle: Text(
                                                    '${step.action['type'] ?? 'unknown'}'
                                                    '${step.targetText != null ? ' → "${step.targetText}"' : ''}',
                                                    style: const TextStyle(
                                                      fontFamily: 'monospace',
                                                      fontSize: 12,
                                                    ),
                                                  ),
                                                  trailing: isCurrent
                                                      ? const SizedBox(
                                                          width: 20,
                                                          height: 20,
                                                          child: CircularProgressIndicator(
                                                            strokeWidth: 2,
                                                          ),
                                                        )
                                                      : null,
                                                ),
                                              );
                                            },
                                          ),
                              ),
                            ],
                          ),
                  ),
                ),
              ],
            ),
    );
  }
}

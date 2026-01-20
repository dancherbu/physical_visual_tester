import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'robot_service.dart';

class BrainStatsPage extends StatefulWidget {
  final RobotService robot;

  const BrainStatsPage({super.key, required this.robot});

  @override
  State<BrainStatsPage> createState() => _BrainStatsPageState();
}

class _BrainStatsPageState extends State<BrainStatsPage> {
  bool _loading = true;
  String? _error;
  
  int _totalMemories = 0;
  int _vectorsCount = 0;
  DateTime? _lastUpdate;
  List<Map<String, dynamic>> _recentPoints = [];

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final info = await widget.robot.qdrant.getCollectionInfo();
      final points = await widget.robot.qdrant.getRecentPoints(limit: 50);

      setState(() {
        _totalMemories = info['points_count'] ?? 0;
        _vectorsCount = info['vectors_count'] ?? 0;
        _recentPoints = points;
        
        if (points.isNotEmpty) {
           final id = points.first['id'];
           if (id is int) {
               _lastUpdate = DateTime.fromMillisecondsSinceEpoch(id);
           }
        }
      });
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('🧠 Brain Statistics'),
        actions: [
          IconButton(icon: const Icon(Icons.refresh), onPressed: _refresh),
          PopupMenuButton<String>(
            onSelected: (val) {
                if (val == 'wipe') _wipeMemory();
                if (val == 'init') _forceInitHeal();
            },
            itemBuilder: (context) => [
                const PopupMenuItem(
                    value: 'wipe', 
                    child: Text('🔥 Wipe All Memory', style: TextStyle(color: Colors.red))
                ),
                const PopupMenuItem(
                    value: 'init', 
                    child: Text('🛠️ Force Init & Heal', style: TextStyle(color: Colors.blue))
                ),
            ],
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(child: Text("Error: $_error", style: const TextStyle(color: Colors.red)))
              : SingleChildScrollView(
                  child: Padding(
                    padding: const EdgeInsets.all(16.0),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _buildSummaryCard(),
                        const SizedBox(height: 20),
                        const Text("Recent Learnings", style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                        const SizedBox(height: 10),
                        _buildRecentList(),
                        const SizedBox(height: 30),
                        const Divider(),
                        Center(
                            child: FilledButton.icon(
                                style: FilledButton.styleFrom(
                                    backgroundColor: Colors.red.shade100, 
                                    foregroundColor: Colors.red
                                ),
                                icon: const Icon(Icons.delete_forever),
                                label: const Text("Reset Memory & Re-Initialize"),
                                onPressed: _forceInitHeal,
                            ),
                        ),
                        const SizedBox(height: 20),
                      ],
                    ),
                  ),
                ),
    );
  }

  Future<void> _wipeMemory() async {
      final confirm = await showDialog<bool>(
          context: context, 
          builder: (ctx) => AlertDialog(
              title: const Text("Delete All Memories?"),
              content: const Text("This cannot be undone. All 600+ items will be lost."),
              actions: [
                  TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text("Cancel")),
                  FilledButton(onPressed: () => Navigator.pop(ctx, true), style: FilledButton.styleFrom(backgroundColor: Colors.red), child: const Text("Wipe")),
              ],
          )
      );

      if (confirm != true) return;

      setState(() => _loading = true);
      try {
          await widget.robot.qdrant.deleteCollection();
          await Future.delayed(const Duration(seconds: 1)); // Wait for deletion
          _refresh();
          if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Memory Wiped.")));
      } catch (e) {
          setState(() => _error = e.toString());
      } finally {
          setState(() => _loading = false);
      }
  }

  Future<void> _forceInitHeal() async {
      // Prompt user because this acts like a Wipe if the schema is wrong
      final confirm = await showDialog<bool>(
          context: context, 
          builder: (ctx) => AlertDialog(
              title: const Text("Re-Initialize Brain?"),
              content: const Text("This will fix the '0 Vectors' issue by deleting the broken collection and recreating it with the correct schema (768 dimensions).\n\nExisting memories will be lost, but future learning will work."),
              actions: [
                  TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text("Cancel")),
                  FilledButton(onPressed: () => Navigator.pop(ctx, true), style: FilledButton.styleFrom(backgroundColor: Colors.blue), child: const Text("Fix & Re-Init")),
              ],
          )
      );

      if (confirm != true) return;

      setState(() => _loading = true);
      try {
          // 1. Delete existing (ignore 404)
          try { await widget.robot.qdrant.deleteCollection(); } catch (_) {}
          
          await Future.delayed(const Duration(seconds: 1)); 

          // 2. Create explicitly
          await widget.robot.qdrant.createCollection();
          
          await Future.delayed(const Duration(seconds: 1));
          _refresh();
          
          if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Brain Re-Initialized with 768-dim Vectors.")));
      } catch (e) {
          setState(() => _error = e.toString());
      } finally {
          setState(() => _loading = false);
      }
  }

  Widget _buildSummaryCard() {
    return Card(
      elevation: 4,
      color: Colors.deepPurple[50],
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                _statItem("Total Memories", "$_totalMemories", Icons.storage),
                _statItem("Vectors", "$_vectorsCount", Icons.memory),
              ],
            ),
            const Divider(height: 30),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.access_time, size: 20, color: Colors.grey),
                const SizedBox(width: 8),
                Flexible( // [FIX] Prevent Overflow
                  child: Text(
                    _lastUpdate != null 
                      ? "Last Learned: ${DateFormat('yyyy-MM-dd HH:mm:ss').format(_lastUpdate!)}" 
                      : "No memories yet",
                    style: const TextStyle(fontWeight: FontWeight.bold),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            )
          ],
        ),
      ),
    );
  }

  Widget _statItem(String label, String value, IconData icon) {
    return Column(
      children: [
        Icon(icon, size: 32, color: Colors.deepPurple),
        const SizedBox(height: 8),
        Text(value, style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
        Text(label, style: const TextStyle(color: Colors.grey)),
      ],
    );
  }

  Widget _buildRecentList() {
    if (_recentPoints.isEmpty) {
      return const Center(child: Text("No data found."));
    }

    return ListView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      itemCount: _recentPoints.length,
      itemBuilder: (context, index) {
        final point = _recentPoints[index];
        final payload = point['payload'] as Map<String, dynamic>? ?? {};
        final goal = payload['goal'] ?? 'Unknown Goal';
        final fact = payload['fact'] ?? payload['factual_description'] ?? 'No description';
        final action = payload['action'] ?? {};
        final type = action['type'] ?? 'unknown';
        final target = action['target_text'] ?? '';
        final id = point['id'];
        final ts = id is int ? DateTime.fromMillisecondsSinceEpoch(id) : null;

        return Card(
          margin: const EdgeInsets.only(bottom: 8),
          child: ListTile(
            leading: CircleAvatar(
              backgroundColor: _getColorForType(type),
              child: Icon(_getIconForType(type), color: Colors.white, size: 16),
            ),
            title: Text(goal, style: const TextStyle(fontWeight: FontWeight.bold)),
            subtitle: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(fact, maxLines: 2, overflow: TextOverflow.ellipsis),
                if (ts != null)
                   Text(DateFormat('MM/dd HH:mm').format(ts), style: const TextStyle(fontSize: 10, color: Colors.grey)),
              ],
            ),
            trailing: target.isNotEmpty 
                ? Chip(label: Text(target, style: const TextStyle(fontSize: 10))) 
                : null,
          ),
        );
      },
    );
  }
  
  Color _getColorForType(String type) {
      switch(type) {
          case 'click': return Colors.green;
          case 'type': return Colors.blue;
          case 'instruction': return Colors.orange;
          default: return Colors.grey;
      }
  }

  IconData _getIconForType(String type) {
      switch(type) {
          case 'click': return Icons.touch_app;
          case 'type': return Icons.keyboard;
          case 'instruction': return Icons.article;
          default: return Icons.help;
      }
  }
}

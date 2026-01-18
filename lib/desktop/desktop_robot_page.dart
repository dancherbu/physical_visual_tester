import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';
import 'package:image/image.dart' as img;
import 'package:screen_capturer/screen_capturer.dart';

import '../hid/hid_contract.dart';
import '../hid/windows_hid_adapter.dart';
import '../robot/robot_service.dart';
import '../spikes/brain/ollama_client.dart';
import '../spikes/brain/qdrant_service.dart';
import '../vision/ocr_models.dart';

class DesktopRobotPage extends StatefulWidget {
  const DesktopRobotPage({super.key});

  @override
  State<DesktopRobotPage> createState() => _DesktopRobotPageState();
}

class _DesktopRobotPageState extends State<DesktopRobotPage> {
  RobotService? _robot;
  HidAdapter? _hid; // [NEW] Windows HID Adapter
  
  final _ollamaController = TextEditingController(text: 'http://localhost:11434');
  final _qdrantController = TextEditingController(text: 'http://localhost:6333');
  final _chatController = TextEditingController();
  final _taskController = TextEditingController();

  final List<_DesktopChatMessage> _messages = [];
  final List<String> _statusLog = [];
  final List<String> _mockAssets = [];
  final List<String> _taskAssets = [];
  String? _currentMockAsset;
  String? _capturePath;
  Uint8List? _captureBytes;
  UIState? _currentUiState;
  String? _lastOcrText;
  int _imageWidth = 0;
  int _imageHeight = 0;
  Timer? _idleTimer;
  DateTime _lastInteractionTime = DateTime.now();
  DateTime _lastIdleAnalysisTime = DateTime.fromMillisecondsSinceEpoch(0);
  bool _isIdleAnalyzing = false;
  bool _idleEnabled = true;
  bool _awaitingUserResponse = false;
  String? _lastRobotQuestion;
  final Set<String> _answeredQuestions = {};

  bool _connecting = false;
  bool _connected = false;
  bool _useLiveScreen = false;
  bool _isCapturing = false;
  bool _isOcrRunning = false;
  bool _isTaskAnalyzing = false;
  bool _isRobotRunning = false; // [NEW] Active Mode

  @override
  void initState() {
    super.initState();
    _initAssets();
    _connectRobot();
    _startIdleLoop();
  }

  @override
  void dispose() {
    _ollamaController.dispose();
    _qdrantController.dispose();
    _chatController.dispose();
    _taskController.dispose();
    _idleTimer?.cancel();
    super.dispose();
  }

  Future<void> _initAssets() async {
    try {
      final manifestContent = await rootBundle.loadString('AssetManifest.json');
      final Map<String, dynamic> manifestMap = json.decode(manifestContent);

      _mockAssets
        ..clear()
        ..addAll(
          manifestMap.keys
              .where((key) => key.contains('assets/mock/') && key.toLowerCase().endsWith('.png'))
              .toList(),
        );

      _taskAssets
        ..clear()
        ..addAll(
          manifestMap.keys
              .where((key) => key.contains('assets/tasks/') && key.toLowerCase().endsWith('.txt'))
              .toList(),
        );

      setState(() {
        if (_mockAssets.isNotEmpty) {
          _currentMockAsset = _mockAssets.firstWhere(
            (m) => m.contains('desktop'),
            orElse: () => _mockAssets.first,
          );
        }
      });
    } catch (e) {
      _log('❌ Asset manifest load failed: $e');
    }
  }

  Future<void> _connectRobot() async {
    if (_connecting) return;
    setState(() {
      _connecting = true;
      _connected = false;
    });

    try {
      final ollama = OllamaClient(
        baseUrl: Uri.parse(_ollamaController.text.trim()),
        model: 'llama3.2:3b',
      );
      final embed = OllamaClient(
        baseUrl: Uri.parse(_ollamaController.text.trim()),
        model: 'nomic-embed-text',
      );
      final qdrant = QdrantService(
        baseUrl: Uri.parse(_qdrantController.text.trim()),
        collectionName: 'pvt_memory',
      );

      setState(() {
        _robot = RobotService(ollama: ollama, ollamaEmbed: embed, qdrant: qdrant);
        if (Platform.isWindows) {
            _hid = WindowsNativeHidAdapter(); // Native Windows Input
            _log('✅ Initialized Windows Mouse/Keyboard Adapter.');
        } else {
            _log('⚠️ Native Input not supported on ${Platform.operatingSystem}');
        }
        _connected = true;
      });
      _log('✅ Connected to Ollama & Qdrant.');
    } catch (e) {
      _log('❌ Connection failed: $e');
    } finally {
      if (mounted) {
        setState(() => _connecting = false);
      }
    }
  }

  void _log(String message) {
    setState(() {
      _statusLog.insert(0, message);
      if (_statusLog.length > 200) _statusLog.removeLast();
    });
  }

  void _resetIdleTimer() {
    _lastInteractionTime = DateTime.now();
  }

  void _startIdleLoop() {
    _idleTimer = Timer.periodic(const Duration(seconds: 5), (timer) async {
      if (!_idleEnabled || _isIdleAnalyzing || _isCapturing || _isOcrRunning || _awaitingUserResponse) return;
      final idleDuration = DateTime.now().difference(_lastInteractionTime);
      if (idleDuration.inSeconds < 10) return;
      final sinceLastAnalysis = DateTime.now().difference(_lastIdleAnalysisTime);
      if (sinceLastAnalysis.inSeconds < 30) return;
      await _runIdleAnalysis();
    });
  }

  Future<void> _captureScreen() async {
    if (_isCapturing) return;
    setState(() => _isCapturing = true);

    try {
      final captured = await ScreenCapturer.instance.capture(mode: CaptureMode.screen);
      if (captured == null || captured.imageBytes == null) {
        _log('⚠️ Screen capture failed.');
        return;
      }

      final bytes = captured.imageBytes!;
      final decoded = img.decodeImage(bytes);
      if (decoded == null) {
        _log('⚠️ Failed to decode captured image.');
        return;
      }

      final tempDir = Directory.systemTemp;
      final file = File(
        '${tempDir.path}/pvt_desktop_capture_${DateTime.now().millisecondsSinceEpoch}.png',
      );
      await file.writeAsBytes(bytes);

      setState(() {
        _captureBytes = bytes;
        _capturePath = file.path;
        _imageWidth = decoded.width;
        _imageHeight = decoded.height;
      });

      _log('🖥️ Screen captured (${decoded.width}x${decoded.height}).');
    } catch (e) {
      _log('❌ Screen capture error: $e');
    } finally {
      if (mounted) setState(() => _isCapturing = false);
    }
  }

  Future<String> _extractTextWithTesseract(String imagePath) async {
    try {
      final result = await Process.run(
        'tesseract',
        [imagePath, 'stdout', '-l', 'eng'],
      );
      if (result.exitCode != 0) {
        _log('⚠️ Tesseract failed: ${result.stderr}');
        return '';
      }
      return result.stdout.toString();
    } catch (e) {
      _log('❌ OCR error. Install Tesseract and ensure it is in PATH.');
      return '';
    }
  }

  Future<String?> _prepareImageForOcr() async {
    if (_useLiveScreen) {
      if (_capturePath == null) {
        await _captureScreen();
      }
      return _capturePath;
    }

    final mock = _currentMockAsset;
    if (mock == null) return null;

    Uint8List bytes;
    if (mock.startsWith('assets/')) {
      final data = await rootBundle.load(mock);
      bytes = data.buffer.asUint8List();
    } else {
      final file = File(mock);
      if (!await file.exists()) return null;
      bytes = await file.readAsBytes();
    }

    final decoded = img.decodeImage(bytes);
    if (decoded == null) return null;

    final tempDir = Directory.systemTemp;
    final file = File(
      '${tempDir.path}/pvt_desktop_mock_${DateTime.now().millisecondsSinceEpoch}.png',
    );
    await file.writeAsBytes(bytes);

    setState(() {
      _captureBytes = bytes;
      _capturePath = file.path;
      _imageWidth = decoded.width;
      _imageHeight = decoded.height;
    });

    return _capturePath;
  }

  Future<void> _runOcrOnCapture() async {
    if (_isOcrRunning) return;
    setState(() => _isOcrRunning = true);

    try {
      final path = await _prepareImageForOcr();
      if (path == null) {
        _log('⚠️ No capture available for OCR.');
        return;
      }

      final text = await _extractTextWithTesseract(path);
      final width = _imageWidth == 0 ? 1 : _imageWidth;
      final height = _imageHeight == 0 ? 1 : _imageHeight;

      final blocks = text.trim().isEmpty
          ? <OcrBlock>[]
          : [
              OcrBlock(
                text: text.trim(),
                boundingBox: BoundingBox(
                  left: 0,
                  top: 0,
                  right: width.toDouble(),
                  bottom: height.toDouble(),
                ),
              ),
            ];

      final state = UIState(
        ocrBlocks: blocks,
        imageWidth: width,
        imageHeight: height,
        derived: const DerivedFlags(
          hasModalCandidate: false,
          hasErrorCandidate: false,
          modalKeywords: [],
        ),
        createdAt: DateTime.now(),
      );

      setState(() {
        _currentUiState = state;
        _lastOcrText = text.trim();
      });

      if (text.trim().isEmpty) {
        _log('🔎 OCR complete. No text detected.');
      } else {
        _log('🔎 OCR complete. ${text.trim().split('\n').length} lines detected.');
      }
    } finally {
      if (mounted) setState(() => _isOcrRunning = false);
    }
  }

  Future<void> _runIdleAnalysis() async {
    final robot = _robot;
    if (robot == null) return;

    if (_currentUiState == null) {
      await _runOcrOnCapture();
    }

    final state = _currentUiState;
    if (state == null) return;

    setState(() => _isIdleAnalyzing = true);
    _lastIdleAnalysisTime = DateTime.now();
    _log('💤 Idle analysis running...');

    try {
      final result = await robot.analyzeIdlePage(state);
      if (DateTime.now().difference(_lastInteractionTime).inSeconds < 10) {
        _log('⚠️ Idle analysis discarded due to user activity.');
        return;
      }
      if (result.messages.isNotEmpty) {
        final newQuestions = result.messages
            .map((m) => m.trim())
            .where((m) => m.isNotEmpty)
            .where((m) => !_answeredQuestions.contains(m))
            .where((m) => m != _lastRobotQuestion)
            .toList();

        if (newQuestions.isNotEmpty) {
          setState(() {
            for (final message in newQuestions) {
              _messages.add(_DesktopChatMessage(sender: 'Robot', text: message));
              _lastRobotQuestion = message;
            }
            _awaitingUserResponse = true;
          });
        }
      }
      if (result.learnedItems.isNotEmpty) {
        _log('✅ Learned ${result.learnedItems.length} items during idle analysis.');
      }
    } finally {
      if (mounted) setState(() => _isIdleAnalyzing = false);
    }
  }

  Future<void> _sendChat() async {
    final text = _chatController.text.trim();
    if (text.isEmpty) return;
    _resetIdleTimer();

    if (_lastRobotQuestion != null) {
      _answeredQuestions.add(_lastRobotQuestion!);
      _lastRobotQuestion = null;
      _awaitingUserResponse = false;
    }

    setState(() {
      _messages.add(_DesktopChatMessage(sender: 'User', text: text));
      _messages.add(_DesktopChatMessage(sender: 'Robot', text: 'Thinking...', isLoading: true));
      _chatController.clear();
    });

    final robot = _robot;
    if (robot == null) {
      _replaceLastMessage('Robot', 'Robot brain is not connected yet.');
      return;
    }

    try {
      final reply = await robot.answerQuestion(text);
      _replaceLastMessage('Robot', reply);
    } catch (e) {
      _replaceLastMessage('Robot', 'I ran into an error: $e');
    }
  }

  void _replaceLastMessage(String sender, String text) {
    if (_messages.isEmpty) return;
    setState(() {
      _messages.removeLast();
      _messages.add(_DesktopChatMessage(sender: sender, text: text));
    });
  }

  Future<void> _loadTaskAsset(String assetPath) async {
    try {
      final content = await rootBundle.loadString(assetPath);
      setState(() => _taskController.text = content);
    } catch (e) {
      _log('❌ Failed to load task asset: $e');
    }
  }

  Future<void> _loadTaskFileFromDisk() async {
    _resetIdleTimer();
    final result = await FilePicker.platform.pickFiles(
      dialogTitle: 'Select task list',
      type: FileType.custom,
      allowedExtensions: ['txt'],
    );

    if (result == null || result.files.isEmpty) return;
    final path = result.files.single.path;
    if (path == null) return;

    try {
      final content = await File(path).readAsString();
      setState(() => _taskController.text = content);
      _log('📄 Loaded task list from disk.');
    } catch (e) {
      _log('❌ Failed to read task file: $e');
    }
  }

  Future<void> _showMockManagerDialog() async {
    final pathController = TextEditingController();
    String? selectedAsset = _mockAssets.contains(_currentMockAsset) ? _currentMockAsset : null;

    await showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Load Screen'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Mock Screens (assets/mock):', style: TextStyle(fontWeight: FontWeight.bold)),
                DropdownButton<String>(
                  isExpanded: true,
                  value: selectedAsset,
                  hint: const Text('Select mock asset...'),
                  items: _mockAssets
                      .map(
                        (asset) => DropdownMenuItem(
                          value: asset,
                          child: Text(asset.split('/').last, overflow: TextOverflow.ellipsis),
                        ),
                      )
                      .toList(),
                  onChanged: (val) {
                    if (val != null) {
                      setDialogState(() {
                        selectedAsset = val;
                        pathController.clear();
                      });
                    }
                  },
                ),
                const SizedBox(height: 12),
                const Text('Or choose image from disk:', style: TextStyle(fontWeight: FontWeight.bold)),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: pathController,
                        decoration: const InputDecoration(
                          hintText: 'C:\\path\\to\\screenshot.png',
                          isDense: true,
                        ),
                        onChanged: (val) {
                          if (val.isNotEmpty) {
                            setDialogState(() => selectedAsset = null);
                          }
                        },
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.folder_open, color: Colors.blue),
                      tooltip: 'Browse',
                      onPressed: () async {
                        final pick = await FilePicker.platform.pickFiles(
                          dialogTitle: 'Select screenshot',
                          type: FileType.image,
                        );
                        if (pick != null && pick.files.isNotEmpty) {
                          final p = pick.files.single.path;
                          if (p != null) {
                            setDialogState(() {
                              pathController.text = p;
                              selectedAsset = null;
                            });
                          }
                        }
                      },
                    )
                  ],
                ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
            ElevatedButton(
              onPressed: () {
                String? target;
                if (pathController.text.trim().isNotEmpty) {
                  target = pathController.text.trim();
                } else if (selectedAsset != null) {
                  target = selectedAsset;
                }

                if (target != null) {
                  setState(() {
                    _useLiveScreen = false;
                    _currentMockAsset = target;
                    _lastOcrText = null;
                    _currentUiState = null;
                  });
                  Navigator.pop(ctx);
                  _log('🖼️ Loaded screen: ${target.split('/').last}');
                }
              },
              child: const Text('Load Screen'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _analyzeAndLoadTasks() async {
    _resetIdleTimer();
    final text = _taskController.text.trim();
    if (text.isEmpty) return;

    final robot = _robot;
    if (robot == null) {
      _log('⚠️ Connect to Ollama/Qdrant first.');
      return;
    }

    await _analyzeTaskList(text, loadAfter: true);
  }

  Future<void> _analyzeTaskList(String rawText, {required bool loadAfter}) async {
    if (_isTaskAnalyzing) return;
    final robot = _robot;
    if (robot == null) {
      _log('⚠️ Connect to Ollama/Qdrant first.');
      return;
    }

    setState(() => _isTaskAnalyzing = true);
    _messages.add(_DesktopChatMessage(sender: 'Robot', text: 'Analyzing task list...', isLoading: true));

    final lines = rawText
        .split('\n')
        .map((l) => l.trim().replaceAll(RegExp(r'^[\d\-\.\s]+'), ''))
        .where((l) => l.isNotEmpty)
        .toList();

    final unknownTasks = <String>[];
    int total = 0;
    int known = 0;

    for (final task in lines) {
      final steps = await robot.decomposeAndVerify(task);
      bool taskKnown = true;
      for (final step in steps) {
        total++;
        if (step.confidence > 0.85) {
          known++;
        } else {
          taskKnown = false;
        }
      }
      if (!taskKnown) unknownTasks.add(task);
    }

    final percentage = total == 0 ? 100 : ((known / total) * 100).toInt();

    setState(() {
      _messages.removeLast();
      _messages.add(_DesktopChatMessage(
        sender: 'Robot',
        text: 'Task analysis complete.\n\nConfidence: $percentage% ($known/$total steps).\nTasks: ${lines.length}\nNeeds help: ${unknownTasks.length}',
      ));
      if (unknownTasks.isNotEmpty) {
        _messages.add(_DesktopChatMessage(
          sender: 'Robot',
          text: 'I need help with: ${unknownTasks.join('; ')}',
        ));
      }
    });

    if (loadAfter && unknownTasks.isEmpty) {
      robot.loadTasks(rawText);
      _log('✅ Tasks loaded (${lines.length}).');
    } else if (loadAfter) {
      _log('⚠️ Tasks not loaded until unknown steps are clarified.');
    }

    if (mounted) setState(() => _isTaskAnalyzing = false);
  }

  Future<void> _runScriptedTaskTest() async {
    if (_taskAssets.isEmpty) {
      _log('⚠️ No task assets found in assets/tasks.');
      return;
    }
    _resetIdleTimer();
    final asset = _taskAssets.first;
    try {
      final content = await rootBundle.loadString(asset);
      setState(() => _taskController.text = content);
      _messages.add(_DesktopChatMessage(
        sender: 'Robot',
        text: 'Running scripted task analysis on ${asset.split('/').last}...',
      ));
      await _analyzeTaskList(content, loadAfter: false);
    } catch (e) {
      _log('❌ Failed scripted task test: $e');
    }
  }

  Future<void> _startRobotLoop() async {
    if (_isRobotRunning) return;
    setState(() {
      _isRobotRunning = true;
      _isIdleAnalyzing = false; // Disable idle while active
    });
    _log("🚀 Robot Mode STARTED. I will act autonomously.");
    _runRobotLoop();
  }
  
  Future<void> _stopRobotLoop() async {
    if (!_isRobotRunning) return;
    setState(() => _isRobotRunning = false);
    _log("🛑 Robot Mode STOPPED.");
  }

  Future<void> _runRobotLoop() async {
     if (!_isRobotRunning) return;
     if (!mounted) return;

     _log("--- Active Cycle Start ---");
     
     // 1. See (Capture & OCR)
     if (_useLiveScreen) {
        await _captureScreen();
     } else {
        // Reuse current mock if not live, but typically 'Active Mode' implies live
        if (_currentUiState == null) {
           _log("⚠️ Using Mock for Active Mode. Ensure mock is loaded.");
        }
     }
     
     await _runOcrOnCapture();
     final state = _currentUiState;
     
     // 2. Think
     if (state != null) {
        final robot = _robot;
        if (robot != null) {
            // Get current goal from task controller if any, or chat? 
            // For now, let's use the task controller's first line as goal, or similar.
            // Or just 'Explore' if empty.
            String goal = _taskController.text.trim().split('\n').first;
            if (goal.isEmpty) goal = "Explore and analyze the screen";

            final decision = await robot.think(state: state, currentGoal: goal);
            
            _log("🤔 Decision: ${decision.reasoning}");
            
            // 3. Act
            if (decision.isConfident && decision.action != null && _hid != null) {
                // Execute
                await _executeAction(decision.action!);
            } else if (decision.isConfident && decision.action == null) {
                _log("✅ Analyzed: ${decision.reasoning} (No physical action needed)");
            }
        }
     }
     
     _log("--- Cycle End (Waiting 3s) ---");
     await Future.delayed(const Duration(seconds: 3));
     
     // Loop
     if (_isRobotRunning) {
         _runRobotLoop();
     }
  }

  Future<void> _executeAction(Map<String, dynamic> action) async {
    _resetIdleTimer();
    final hid = _hid;
    if (hid == null) {
        _log("⚠️ No HID Adapter available. Cannot execute action.");
        return;
    }

    final type = action['type'] as String? ?? 'click';
    
    try {
        if (type == 'click') {
            final x = action['x'] as int;
            final y = action['y'] as int;
            
            _log("🖱️ Moving Mouse to ($x, $y) (Native)...");
            
            // Native Window usually supports absolute positioning directly
            await hid.sendMouseMove(dx: x, dy: y);
            await Future.delayed(const Duration(milliseconds: 100));
            
            await hid.sendClick(HidMouseButton.left);
            _log("✅ Clicked Left Mouse Button.");
            
        } else if (type == 'keyboard_type') {
            final text = action['target_text'] as String;
            _log("⌨️ Typing: \"$text\"");
            await hid.sendKeyText(text);
            await hid.sendKeyText('\n'); 
            _log("✅ Typed text.");
            
        } else if (type == 'keyboard_key') {
            final key = (action['target_text'] as String).toLowerCase();
            String? toSend;
            if (key == 'enter' || key == 'return') toSend = '\n';
            else if (key == 'tab') toSend = '\t';
            else if (key == 'space') toSend = ' ';
            
            if (toSend != null) {
               _log("⌨️ Pressing Key: $key");
               await hid.sendKeyText(toSend);
            } else {
               _log("⚠️ HID: Key '$key' not mapped.");
            }

        } else if (type == 'keyboard_shortcut') {
            // Can be implemented in WindowsNativeHidAdapter later (modifier keys)
             _log("⚠️ Shortcut '$action' not fully implemented yet.");
             
        } else if (type == 'mouse_right_click') {
             // If coordinates provided, move first
             if (action.containsKey('x')) {
                 await hid.sendMouseMove(dx: action['x'], dy: action['y']);
             }
             await hid.sendClick(HidMouseButton.right);
             _log("✅ Right Clicked.");
        }
    } catch (e) {
        _log("❌ Execution Failed: $e");
    }
  }

  Widget _buildLeftPanel() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Switch(
              value: _useLiveScreen,
              onChanged: (val) => setState(() => _useLiveScreen = val),
            ),
            const Text('Live Screen'),
            const SizedBox(width: 12),
            Expanded(
              child: DropdownButton<String>(
                isExpanded: true,
                hint: const Text('Select Mock Screen'),
                value: _currentMockAsset,
                items: _mockAssets
                    .map(
                      (asset) => DropdownMenuItem(
                        value: asset,
                        child: Text(asset.split('/').last),
                      ),
                    )
                    .toList(),
                onChanged: _useLiveScreen
                    ? null
                    : (val) async {
                        setState(() => _currentMockAsset = val);
                        if (val != null) {
                          await _runOcrOnCapture();
                        }
                      },
              ),
            ),
            const SizedBox(width: 8),
            ElevatedButton.icon(
              onPressed: _useLiveScreen
                  ? null
                  : (_currentMockAsset == null
                      ? null
                      : () => _log('🖼️ Mock screen loaded.')),
              icon: const Icon(Icons.image),
              label: const Text('Use Mock'),
            ),
            const SizedBox(width: 8),
            ElevatedButton.icon(
              onPressed: _showMockManagerDialog,
              icon: const Icon(Icons.folder_open),
              label: const Text('Load Screen'),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: ElevatedButton.icon(
                onPressed: _useLiveScreen
                    ? (_isCapturing ? null : _captureScreen)
                    : null,
                icon: const Icon(Icons.camera),
                label: Text(_isCapturing ? 'Capturing...' : 'Capture Screen'),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: ElevatedButton.icon(
                onPressed: _isOcrRunning ? null : _runOcrOnCapture,
                icon: const Icon(Icons.text_snippet),
                label: Text(_isOcrRunning ? 'Running OCR...' : 'Run OCR'),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: ElevatedButton.icon(
                onPressed: _isIdleAnalyzing ? null : _runIdleAnalysis,
                icon: const Icon(Icons.psychology),
                label: Text(_isIdleAnalyzing ? 'Analyzing...' : 'Idle Analyze'),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Row(
           children: [
             Expanded(
               child: ElevatedButton.icon(
                 style: ElevatedButton.styleFrom(
                   backgroundColor: _isRobotRunning ? Colors.redAccent : Colors.green,
                   foregroundColor: Colors.white,
                 ),
                 onPressed: _isRobotRunning ? _stopRobotLoop : _startRobotLoop,
                 icon: Icon(_isRobotRunning ? Icons.stop : Icons.play_arrow),
                 label: Text(_isRobotRunning ? 'Stop Robot' : 'Start Active Mode'),
               ),
             ),
           ],
        ),
        const SizedBox(height: 8),
        Expanded(
          child: Container(
            decoration: BoxDecoration(
              color: Colors.black12,
              border: Border.all(color: Colors.black12),
              borderRadius: BorderRadius.circular(8),
            ),
            child: _useLiveScreen
                ? (_captureBytes == null
                    ? const Center(child: Text('No capture yet'))
                    : ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: Image.memory(
                          _captureBytes!,
                          fit: BoxFit.contain,
                        ),
                      ))
                : (_currentMockAsset == null
                    ? const Center(child: Text('No mock selected'))
                    : ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: _currentMockAsset!.startsWith('assets/')
                            ? Image.asset(
                                _currentMockAsset!,
                                fit: BoxFit.contain,
                              )
                            : Image.file(
                                File(_currentMockAsset!),
                                fit: BoxFit.contain,
                              ),
                      )),
          ),
        ),
        const SizedBox(height: 8),
        Container(
          height: 160,
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: Colors.black,
            borderRadius: BorderRadius.circular(8),
          ),
          child: ListView.builder(
            reverse: true,
            itemCount: _statusLog.length,
            itemBuilder: (ctx, i) => Text(
              _statusLog[i],
              style: const TextStyle(
                color: Colors.greenAccent,
                fontFamily: 'Courier',
                fontSize: 11,
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildRightPanel() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _ollamaController,
                decoration: const InputDecoration(
                  labelText: 'Ollama URL',
                  border: OutlineInputBorder(),
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: TextField(
                controller: _qdrantController,
                decoration: const InputDecoration(
                  labelText: 'Qdrant URL',
                  border: OutlineInputBorder(),
                ),
              ),
            ),
            const SizedBox(width: 8),
            ElevatedButton.icon(
              onPressed: _connecting ? null : _connectRobot,
              icon: Icon(_connected ? Icons.check_circle : Icons.link),
              label: Text(_connecting ? 'Connecting...' : 'Connect'),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Expanded(
          child: Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: Colors.grey[100],
              borderRadius: BorderRadius.circular(8),
            ),
            child: ListView.builder(
              reverse: true,
              itemCount: _messages.length,
              itemBuilder: (ctx, i) {
                final reversedIndex = _messages.length - 1 - i;
                final msg = _messages[reversedIndex];
                return Align(
                  alignment: msg.sender == 'User' ? Alignment.centerRight : Alignment.centerLeft,
                  child: Container(
                    margin: const EdgeInsets.symmetric(vertical: 4),
                    padding: const EdgeInsets.all(10),
                    constraints: const BoxConstraints(maxWidth: 420),
                    decoration: BoxDecoration(
                      color: msg.sender == 'User' ? Colors.blue[100] : Colors.white,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: Colors.black12),
                    ),
                    child: msg.isLoading
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : Text(msg.text),
                  ),
                );
              },
            ),
          ),
        ),
        const SizedBox(height: 8),
        if (_lastOcrText != null && _lastOcrText!.isNotEmpty)
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.black12),
            ),
            child: Text(
              _lastOcrText!,
              maxLines: 4,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12),
            ),
          ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _chatController,
                minLines: 1,
                maxLines: 4,
                decoration: const InputDecoration(
                  hintText: 'Ask the robot a question...',
                  border: OutlineInputBorder(),
                ),
                onSubmitted: (_) => _sendChat(),
              ),
            ),
            const SizedBox(width: 8),
            ElevatedButton.icon(
              onPressed: _sendChat,
              icon: const Icon(Icons.send),
              label: const Text('Send'),
            ),
          ],
        ),
        const SizedBox(height: 12),
        const Text('Task List', style: TextStyle(fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: DropdownButton<String>(
                isExpanded: true,
                hint: const Text('Load task asset'),
                items: _taskAssets
                    .map(
                      (asset) => DropdownMenuItem(
                        value: asset,
                        child: Text(asset.split('/').last.replaceAll('.txt', '')),
                      ),
                    )
                    .toList(),
                onChanged: (val) {
                  if (val != null) _loadTaskAsset(val);
                },
              ),
            ),
            const SizedBox(width: 8),
            ElevatedButton.icon(
              onPressed: _isTaskAnalyzing ? null : _analyzeAndLoadTasks,
              icon: const Icon(Icons.assignment_turned_in),
              label: const Text('Analyze & Load'),
            ),
            const SizedBox(width: 8),
            ElevatedButton.icon(
              onPressed: _loadTaskFileFromDisk,
              icon: const Icon(Icons.folder_open),
              label: const Text('Open File'),
            ),
            const SizedBox(width: 8),
            ElevatedButton.icon(
              onPressed: _isTaskAnalyzing ? null : _runScriptedTaskTest,
              icon: const Icon(Icons.science),
              label: const Text('Scripted Test'),
            ),
          ],
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _taskController,
          minLines: 3,
          maxLines: 6,
          decoration: const InputDecoration(
            hintText: '1. Open Chrome\n2. Go to google.com',
            border: OutlineInputBorder(),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('PVT Desktop Companion'),
      ),
      body: Padding(
        padding: const EdgeInsets.all(12.0),
        child: Row(
          children: [
            Expanded(flex: 6, child: _buildLeftPanel()),
            const SizedBox(width: 12),
            Expanded(flex: 5, child: _buildRightPanel()),
          ],
        ),
      ),
    );
  }
}

class _DesktopChatMessage {
  final String sender;
  final String text;
  final bool isLoading;

  _DesktopChatMessage({
    required this.sender,
    required this.text,
    this.isLoading = false,
  });
}

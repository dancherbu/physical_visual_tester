import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';

import '../vision/input_image_from_camera_image.dart';
import '../vision/ocr_models.dart';
import '../vision/vision_overlay_painter.dart';
import '../spikes/brain/ollama_client.dart';
import '../spikes/brain/qdrant_service.dart';
import 'robot_service.dart';
import 'training_model.dart';

// HID
import '../hid/hid_contract.dart';
import '../hid/method_channel_hid_adapter.dart';

class RobotTesterPage extends StatefulWidget {
  const RobotTesterPage({super.key});

  @override
  State<RobotTesterPage> createState() => _RobotTesterPageState();
}

class _RobotTesterPageState extends State<RobotTesterPage> {
  // Services
  CameraController? _controller;
  final _recognizer = TextRecognizer(script: TextRecognitionScript.latin);
  final HidAdapter _hid = MethodChannelHidAdapter();
  late RobotService _robot;

  // AI Config
  static const _hostIp = String.fromEnvironment('HOST_IP', defaultValue: '192.168.1.100');
  String _ollamaUrl = 'http://$_hostIp:11434';
  String _qdrantUrl = 'http://$_hostIp:6333';
  String _ollamaModel = 'nomic-embed-text';

  // State
  bool _isInit = false;
  bool _isRobotActive = false; // "Auto Run" mode
  bool _isTrainingMode = false; // "Training/Watch" mode
  bool _isRecording = false; // Actually recording frame
  bool _isThinking = false;
  
  String _statusLog = "Initializing Robot System...";
  
  // Vision Data
  CameraImage? _latestImage;
  List<OcrBlock> _blocks = [];
  UIState? _currentUiState;
  Uint8List? _lastImageBytes;
  String? _lastImagePath; // Keep track for training
  
  // Mock Mode
  bool _useMock = true; // Default to Mock Mode
  List<String> _mockAssets = [];
  final Set<String> _studiedMocks = {}; // [NEW] Track studied screens
  String? _currentMockAsset;
  int _imageWidth = 0;
  int _imageHeight = 0;
  
  // Chat State
  bool _isChatOpen = false;
  final List<ChatMessage> _messages = [];
  OcrBlock? _chatTargetBlock;
  TrainingSession? _reviewSession; // If reviewing a session
  int _reviewIndex = 0;
  final TextEditingController _chatController = TextEditingController(); // [NEW]
  int _taskFailureCount = 0;
  
  // Failure Review
  bool _isReviewingFailures = false;
  List<String> _failedTasksQueue = [];
  
  // IDLE CURIOSITY
  Timer? _idleTimer;
  DateTime _lastInteractionTime = DateTime.now();
  bool _isAnalyzingIdle = false;
  List<String> _pendingCuriosityQuestions = [];

  @override
  void initState() {
    super.initState();
    _initRobot();
    _initMocks();
    _initCamera();
    _startIdleLoop();
  }

  void _log(String message) {
    if (!mounted) return;
    setState(() {
      _statusLog = "$message\n$_statusLog"; 
      if (_statusLog.length > 2000) _statusLog = _statusLog.substring(0, 2000);
    });
    debugPrint("[ROBOT] $message");
  }

  Future<void> _initRobot() async {
    _robot = RobotService(
      ollama: OllamaClient(baseUrl: Uri.parse(_ollamaUrl), model: _ollamaModel),
      qdrant: QdrantService(baseUrl: Uri.parse(_qdrantUrl), collectionName: 'pvt_memory'),
    );
    _log("Robot Brain Connected.");
    setState(() => _isInit = true);
  }

  // [NEW] Dynamic Task List
  List<String> _taskAssets = [];

  Future<void> _initMocks() async {
    try {
       final manifestContent = await rootBundle.loadString('AssetManifest.json');
       final Map<String, dynamic> manifestMap = json.decode(manifestContent);
       
       // MOCKS
       _mockAssets = manifestMap.keys
          .where((key) => key.startsWith('assets/mock/') && key.endsWith('.png'))
          .toList();
       // TASKS
       _taskAssets = manifestMap.keys
          .where((key) => key.startsWith('assets/tasks/') && key.endsWith('.txt'))
          .toList();

    } catch (e) {
       debugPrint("Manifest Load Error: $e");
       // Fallbacks
       _mockAssets = ['assets/mock/screen_login.png'];
       _taskAssets = ['assets/tasks/login_tasks.txt'];
    }

    if (_mockAssets.isNotEmpty) {
       _currentMockAsset = _mockAssets.firstWhere((m) => m.contains('desktop'), orElse: () => _mockAssets.first);
    }
  }

  Future<void> _initCamera() async {
    try {
      final cameras = await availableCameras();
      if (cameras.isEmpty) throw StateError('No cameras');
      final preferred = cameras.firstWhere((c) => c.lensDirection == CameraLensDirection.back, orElse: () => cameras.first);

      final controller = CameraController(preferred, ResolutionPreset.high, enableAudio: false, imageFormatGroup: ImageFormatGroup.yuv420);
      await controller.initialize();
      if (mounted) {
        setState(() => _controller = controller);
        if (!_useMock) {
           controller.startImageStream((img) {
             _latestImage = img;
             _imageWidth = img.width;
             _imageHeight = img.height;
           });
        }
      }
      _log("Vision System Online.");
    } catch (e) {
      _log("Camera Error: $e");
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    _recognizer.close();
    _idleTimer?.cancel();
    _chatController.dispose();
    super.dispose();
  }
  
  DateTime _lastOptimizationTime = DateTime.now();

  // --- Idle Loop ---
  void _startIdleLoop() {
      // Check every 5 seconds
      _idleTimer = Timer.periodic(const Duration(seconds: 5), (timer) async {
          if (_isRecording || _isRobotActive || _isThinking || _isChatOpen || _isTrainingMode) {
              _lastInteractionTime = DateTime.now(); // Reset if busy
              return;
          }
          
          final idleDuration = DateTime.now().difference(_lastInteractionTime);
          
          // 1. Curiosity Analysis (>10s)
          if (idleDuration.inSeconds > 10 && !_isAnalyzingIdle) {
               
               // [NEW] Mock Learning Logic
               bool newMockLoaded = false;
               if (_useMock) {
                   newMockLoaded = await _switchToNextUnstudiedMock();
               }

               if (_currentUiState != null) {
                    _log("⏰ Idle Curiosity: Analyzing ${_useMock ? 'Mock Screen' : 'Screen'}...");
                    await _runIdleAnalysis();
                    
                    // Mark as studied if mock
                    if (_useMock && _currentMockAsset != null) {
                        _studiedMocks.add(_currentMockAsset!);
                    }
               }
          }
          
          // 2. Memory Optimization (>30s)
          final sinceLastOpt = DateTime.now().difference(_lastOptimizationTime);
          if (idleDuration.inSeconds > 30 && sinceLastOpt.inMinutes > 2) {
               _log("🧠 Deep Sleep: Optimizing Memory...");
               _lastOptimizationTime = DateTime.now();
               await _robot.optimizeMemory();
          }
      });
  }
  
  Future<bool> _switchToNextUnstudiedMock() async {
      for (final asset in _mockAssets) {
          if (!_studiedMocks.contains(asset)) {
              setState(() {
                  _currentMockAsset = asset;
                  _lastInteractionTime = DateTime.now(); // Briefly reset so we don't rapid-fire
              });
              _log("🖼️ Switched to Unstudied Mock: ${asset.split('/').last}");
              await _captureAndAnalyze(); // Capture the new screen
              return true;
          }
      }
      return false;
  }
  
  void _resetIdleTimer() {
      _lastInteractionTime = DateTime.now();
      // If we have pending questions and user "woke up", show them
      if (_pendingCuriosityQuestions.isNotEmpty && !_isChatOpen) {
           setState(() {
               _isChatOpen = true;
               _messages.add(ChatMessage(sender: 'Robot', text: "While you were idle, I studied the screen. I have a question:"));
               _messages.add(ChatMessage(sender: 'Robot', text: _pendingCuriosityQuestions.first));
               _pendingCuriosityQuestions.removeAt(0);
           });
           
           // If more questions, queue them? For now mostly 1.
           _pendingCuriosityQuestions.clear(); 
      }
  }
  
  Future<void> _runIdleAnalysis() async {
      if (_currentUiState == null) return;
      
      setState(() => _isAnalyzingIdle = true);
      _log("💤 Idle Mode: Analyzing Screen in Background...");
      
      try {
          final questions = await _robot.analyzeIdlePage(_currentUiState!);
          if (questions.isNotEmpty) {
               _pendingCuriosityQuestions.addAll(questions);
               _log("💡 Curiosity: Generated ${questions.length} questions.");
          }
      } catch (e) {
          debugPrint("Idle Err: $e");
      } finally {
          setState(() => _isAnalyzingIdle = false);
      }
  }

  // --- Robot Loop ---

  void _toggleRobot() {
    // Cannot act while rec
    if (_isRecording) return;
    
    setState(() => _isRobotActive = !_isRobotActive);
    if (_isRobotActive) {
      _log("🤖 ROBOT ACTIVATED.");
      _runRobotLoop();
    } else {
      _log("🛑 ROBOT STOPPED.");
    }
  }
  
  // --- Training Control ---
  
  void _toggleTraining() async {
      _resetIdleTimer();
      // Cannot train while acting
      if (_isRobotActive) return;
      
      if (!_isRecording) {
          // START RECORDING
          final nameController = TextEditingController();
          final name = await showDialog<String>(
             context: context,
             builder: (ctx) => AlertDialog(
                title: Text("Name this Training Session"),
                content: TextField(controller: nameController, decoration: InputDecoration(hintText: "e.g. Login Sequence")),
                actions: [
                   TextButton(onPressed: () => Navigator.pop(ctx), child: Text("Cancel")),
                   TextButton(onPressed: () => Navigator.pop(ctx, nameController.text), child: Text("Start")),
                ],
             )
          );
          
          if (name != null && name.isNotEmpty) {
               _robot.startRecording(name);
               setState(() => _isRecording = true);
               _log("🎥 RECORDING SESSION: $name");
               _runRecordingLoop();
          }
      } else {
          // STOP RECORDING
          final session = _robot.stopRecording();
          setState(() => _isRecording = false);
          _log("⏹️ Recording Stopped. Captured ${session?.frames.length ?? 0} frames.");
          
          if (session != null && session.frames.isNotEmpty) {
              _startSessionReview(session);
          }
      }
  }

  Future<void> _runRobotLoop() async {
    while (_isRobotActive && mounted) {
      _resetIdleTimer();
      
      if (_isThinking) {
        await Future.delayed(const Duration(milliseconds: 500));
        continue;
      }
      
      if (_isChatOpen) {
         await Future.delayed(const Duration(seconds: 1));
         continue;
      }
      
      setState(() => _isThinking = true);
      
      try {
        _log("Using Eyes (Robot Mode)...");
        await _captureAndAnalyze();
        
        if (!_isRobotActive) break;
        if (_currentUiState == null) {
          setState(() => _isThinking = false);
          await Future.delayed(const Duration(seconds: 1));
          continue;
        }

        _log("Thinking...");
        
        // Use Task text if available, otherwise just observe
        String? goal = _robot.getNextTask();
        if (goal != null) _log("🎯 Current Task: $goal");
        
        final decision = await _robot.think(state: _currentUiState!, currentGoal: goal);
        _log("Decision: ${decision.reasoning}");

        if (decision.isConfident && decision.action != null) {
          if (decision.reasoning.contains("Need to check")) {
             _log("⚠️ Prerequisite Check Failed: ${decision.reasoning}");
             _triggerChatConfusion(null, overrideMessage: decision.reasoning);
             setState(() => _isRobotActive = false);
          } else {
              _log("Executing Action...");
              await _executeAction(decision.action!);
              
              // If we were following a script, assume success for now (or verify later)
              // Ideally verifying the goal was met is better, but for MVP:
              if (goal != null) {
                   _log("✅ Completed Step: $goal");
                   _robot.completeTask();
                   if (!_robot.hasPendingTasks) {
                        _log("🎉 ALL TASKS COMPLETE.");
                        setState(() => _isRobotActive = false);
                   }
                   _taskFailureCount = 0; // Reset on success
              }
              
              await Future.delayed(const Duration(seconds: 2));
              if (_useMock) _simulateMockNavigation(decision.action!['target_text']);
          }
        } else {
          // LOW CONFIDENCE
          if (goal != null) {
              _taskFailureCount++;
              if (_taskFailureCount >= 3) {
                  _log("⚠️ Task Failed 3 times. Stopping to Review.");
                  setState(() => _isRobotActive = false);
                  
                  // Mark failed
                  _robot.markTaskFailed(goal);
                  
                  // Diagnose (Optional context)
                  // final diagnosis = await _robot.diagnoseFailure(_currentUiState!, goal);
                  
                  // Start Review Loop
                  _startFailureReview();
                  
                  _taskFailureCount = 0;
                  return; // Exit loop
              } else {
                  _log("⚠️ Retry $_taskFailureCount/3 for '$goal'...");
              }
          } else {
              _log("⚠️ CONFUSION. Opening Chat.");
              setState(() => _isRobotActive = false);
              _triggerChatConfusion(null);
          }
        }

      } catch (e) {
        _log("Error in Loop: $e");
        setState(() => _isRobotActive = false);
      } finally {
        if (mounted) setState(() => _isThinking = false);
      }
      
      await Future.delayed(const Duration(seconds: 1));
    }
  }
  
  Future<void> _runRecordingLoop() async {
      while (_isRecording && mounted) {
           _resetIdleTimer();
           try {
               await _captureAndAnalyze(); // Capture frame
               if (_currentUiState != null && _lastImagePath != null) {
                   _robot.captureTrainingFrame(state: _currentUiState!, imagePath: _lastImagePath!);
               }
           } catch (e) {
               _log("Record Error: $e");
           }
           // Sample rate 1Hz
           await Future.delayed(const Duration(seconds: 1));
      }
  }

  // --- Logic ---
  
  Future<void> _captureAndAnalyze() async {
     String? imagePath;
     Uint8List? imageBytes;
     int width = 0, height = 0;

     if (_useMock) {
       final asset = _currentMockAsset ?? _mockAssets.first;
       final data = await rootBundle.load(asset);
       imageBytes = data.buffer.asUint8List();
       final decoded = await decodeImageFromList(imageBytes);
       width = decoded.width;
       height = decoded.height;
       
       final temp = Directory.systemTemp;
       // Unique path for recording
       final timestamp = DateTime.now().millisecondsSinceEpoch;
       final file = File('${temp.path}/robot_eye_mock_$timestamp.png');
       await file.writeAsBytes(imageBytes);
       imagePath = file.path;
       
     } else if (_controller != null && _controller!.value.isInitialized) {
       final file = await _controller!.takePicture();
       imagePath = file.path;
       imageBytes = await file.readAsBytes();
       final decoded = await decodeImageFromList(imageBytes);
       width = decoded.width;
       height = decoded.height;
     }

     if (imagePath == null) return;

     final inputImage = InputImage.fromFilePath(imagePath);
     final recognized = await _recognizer.processImage(inputImage);
     
     final blocks = recognized.blocks.map((b) => OcrBlock(
       text: b.text,
       boundingBox: BoundingBox(
         left: b.boundingBox.left, top: b.boundingBox.top,
         right: b.boundingBox.right, bottom: b.boundingBox.bottom
       ),
     )).toList();

     final state = UIState(
       ocrBlocks: blocks,
       imageWidth: width,
       imageHeight: height,
       derived: const DerivedFlags(hasModalCandidate: false, hasErrorCandidate: false, modalKeywords: []),
       createdAt: DateTime.now(),
     );

     setState(() {
       _currentUiState = state;
       _blocks = blocks;
       _lastImageBytes = imageBytes;
       _lastImagePath = imagePath; // Save for recording
       _imageWidth = width;
       _imageHeight = height;
     });
     
     // Only delete if NOT recording (we need file for TrainingFrame)
     if (!_isRecording) {
         try { if (!_useMock) await File(imagePath).delete(); } catch (_) {} 
     }
  }

  Future<void> _executeAction(Map<String, dynamic> action) async {
      _resetIdleTimer();
      if (_useMock) {
         _log("(Mock) Clicked at ${action['x']}, ${action['y']}");
      }
  }

  void _simulateMockNavigation(String? targetText) {
     if (targetText == null) return;
     final t = targetText.toLowerCase();
     String? next;
     if (t.contains('new presentation')) next = 'ppt_editor_home';
     else if (t.contains('insert')) next = 'ppt_editor_insert';
     else if (t.contains('home')) next = 'ppt_home';
     
     if (next != null) {
        final asset = _mockAssets.firstWhere((a) => a.contains(next!), orElse: () => _currentMockAsset!);
        setState(() => _currentMockAsset = asset);
        _log("Simulated Screen Change to $next");
     }
  }

  // --- CHAT SYSTEM & REVIEW ---
  
  void _triggerChatConfusion(OcrBlock? block, {String? overrideMessage}) {
      setState(() {
         _isChatOpen = true;
         _chatTargetBlock = block;
         _resetIdleTimer();
         
         String text = overrideMessage ?? "I am confused. What should I do with this?";
         _messages.add(ChatMessage(sender: 'Robot', text: text, imageBytes: _lastImageBytes, highlightBlock: block));
      });
  }
  
  void _startFailureReview() {
      // Collect the current failed task + any remaining tasks in the queue (since we blocked)
      final failures = <String>{};
      failures.addAll(_robot.failedTasks);
      failures.addAll(_robot.remainingTasks);
      
      if (failures.isEmpty) return;
      
      setState(() {
          _isReviewingFailures = true;
          _failedTasksQueue = failures.toList();
          _isChatOpen = true;
          _messages.add(ChatMessage(sender: 'Robot', text: "I encountered issues with ${failures.length} tasks. Let's review them so I can learn."));
      });
      
      _nextFailureReviewStep();
  }
  
  void _nextFailureReviewStep() async {
      if (_failedTasksQueue.isEmpty) {
          setState(() {
             _isReviewingFailures = false;
             _messages.add(ChatMessage(sender: 'Robot', text: "Review complete! I've updated my memory with your instructions."));
          });
          return;
      }
      
      final task = _failedTasksQueue.first;
      setState(() {
          _messages.add(ChatMessage(sender: 'Robot', text: "Task: \"$task\"\n\nI don't know how to perform this. Please explain the steps (e.g. \"Open browser then type url\")."));
      });
  }
  
  void _startSessionReview(TrainingSession session) async {
      _resetIdleTimer();
      if (session.frames.isEmpty) return;
      setState(() {
         _isChatOpen = true;
         _reviewSession = session;
         _reviewIndex = 0;
         _messages.add(ChatMessage(sender: 'Robot', text: "Training Session '${session.name}' complete. I recorded ${session.frames.length} events."));
         _messages.add(ChatMessage(sender: 'Robot', text: "Analyzing session to generate hypotheses...", isLoading: true));
      });
      
      // RUN SMART ANALYSIS
      await _robot.analyzeSession(session);
      
      setState(() {
         _messages.removeLast(); // Remove loading
         _messages.add(ChatMessage(sender: 'Robot', text: "Analysis Complete. Let's verify my assumptions."));
         _presentReviewStep();
      });
  }
  
  void _presentReviewStep() async {
      if (_reviewSession == null) return;
      
      if (_reviewIndex >= _reviewSession!.frames.length) {
          _messages.add(ChatMessage(sender: 'Robot', text: "All steps reviewed! Shall I delete the raw recording data now to save space? (Yes/No)"));
           // We are in 'cleanup' mode now
           _reviewIndex = -1; // Flag for cleanup
           return;
      }
      
      final frame = _reviewSession!.frames[_reviewIndex];
      // Load frame image
      Uint8List? frameBytes;
      try {
          frameBytes = await File(frame.imagePath).readAsBytes();
      } catch (e) { debugPrint("Err reading frame: $e"); }
      
      String prompt = "Step ${_reviewIndex + 1} (${frame.eventType.toString().split('.').last}).";
      if (frame.hypothesis != null) {
          prompt += "\n\nI assumed: ${frame.hypothesis!.description}\n";
          if (frame.hypothesis!.prerequisites.isNotEmpty) {
             prompt += "Context/Prerequisites: ${frame.hypothesis!.prerequisites.join(', ')}\n";
          }
          prompt += "\nIs this correct? (Reply 'Yes' or explain the correction)";
      } else {
          prompt += " What happened here?";
      }
      
      _messages.add(ChatMessage(
          sender: 'Robot', 
          text: prompt,
          imageBytes: frameBytes
      ));
  }
  
  void _handleReviewResponse(String text) async {
       _resetIdleTimer();
       if (_reviewIndex == -1) {
           // Cleanup confirmation
           if (text.toLowerCase().contains('yes')) {
               if (_reviewSession != null) _robot.deleteSessionData(_reviewSession!);
               _messages.add(ChatMessage(sender: 'Robot', text: "Deleted raw data. Session Closed."));
           } else {
               _messages.add(ChatMessage(sender: 'Robot', text: "Kept raw data. Session Closed."));
           }
           _reviewSession = null;
           return;
       }
  
       // 1. Process User Resp for current frame
       setState(() => _messages.add(ChatMessage(sender: 'Robot', text: 'Processing...', isLoading: true)));
       
       final frame = _reviewSession!.frames[_reviewIndex];
       
       // Hybrid: If user says "Yes", use Hypothesis. Else use Text.
       if (text.toLowerCase().startsWith('yes') && frame.hypothesis != null) {
            // SAVE HYPOTHESIS
           if (frame.uiState != null) {
               await _robot.learn(
                  state: frame.uiState!, 
                  goal: frame.hypothesis!.goal, 
                  action: frame.hypothesis!.suggestedAction ?? {'type': 'observation'},
                  factualDescription: frame.hypothesis!.description,
                  prerequisites: frame.hypothesis!.prerequisites,
               );
           }
           setState(() {
                _messages.removeLast();
                _messages.add(ChatMessage(sender: 'Robot', text: "Confirmed. Memory verified."));
           });
       } else {
           // CORRECTION MODE
           // Call Parse logic with User Text + Block Text (if we knew it)
           // Since we don't have a targeted block, we pass "Unknown"
           final knowledge = await _robot.parseTeachingResponse(text, "Unknown Element");
           
           if (frame.uiState != null) {
               await _robot.learn(
                  state: frame.uiState!, 
                  goal: knowledge['goal'], 
                  action: {'type': 'click', 'target_text': knowledge['fact'], 'x': 0, 'y': 0},
                  factualDescription: knowledge['fact'],
                  prerequisites: (knowledge['prerequisites'] as List).cast<String>(),
               );
           }
           setState(() {
                _messages.removeLast();
                _messages.add(ChatMessage(sender: 'Robot', text: "Available Correction Saved."));
           });
       }
       
       setState(() {
           _reviewIndex++; 
           _presentReviewStep();
       });
  }

  // --- TASKS ---
  
  void _showTaskUploadDialog() {
      final textController = TextEditingController();
      final externalPathController = TextEditingController(); // [NEW]
      
      showDialog(
         context: context, 
         builder: (ctx) => StatefulBuilder(
           builder: (context, setDialogState) => AlertDialog(
            title: const Text("Document Driven Tasks"),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                    // DYNAMIC PRESETS
                    const Text("Load Preset (Assets):", style: TextStyle(fontWeight: FontWeight.bold)),
                    DropdownButton<String>(
                        isExpanded: true,
                        hint: const Text("Select a Task File..."),
                        items: _taskAssets.map((path) {
                            // Extract readable name
                            final name = path.split('/').last.replaceAll('.txt', '').replaceAll('_', ' ').toUpperCase();
                            return DropdownMenuItem(value: path, child: Text(name, style: const TextStyle(fontSize: 14)));
                        }).toList(),
                        onChanged: (val) async {
                            if (val != null) {
                                try {
                                  final content = await rootBundle.loadString(val);
                                  setDialogState(() {
                                      textController.text = content;
                                  });
                                } catch (e) {
                                  debugPrint("Error loading task asset: $e");
                                }
                            }
                        },
                    ),
                    const SizedBox(height: 8),
                    
                    // EXTERNAL FILE
                    const Text("Or Load from Device Path:", style: TextStyle(fontWeight: FontWeight.bold)),
                    Row(
                        children: [
                            Expanded(child: TextField(
                                controller: externalPathController, 
                                decoration: const InputDecoration(hintText: "/sdcard/Download/my_tasks.txt", isDense: true, contentPadding: EdgeInsets.all(8))
                            )),
                            IconButton(
                                icon: const Icon(Icons.file_open, color: Colors.blue),
                                onPressed: () async {
                                    final path = externalPathController.text.trim();
                                    if (path.isNotEmpty) {
                                        try {
                                            final f = File(path);
                                            if (await f.exists()) {
                                                final content = await f.readAsString();
                                                setDialogState(() => textController.text = content);
                                                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("File Loaded!")));
                                            } else {
                                                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("File does not exist.")));
                                            }
                                        } catch (e) {
                                            ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Error: $e")));
                                        }
                                    }
                                }
                            )
                        ],
                    ),
                    
                    const Divider(),
                    const Text("Task List Content:", style: TextStyle(fontWeight: FontWeight.bold)),
                    const SizedBox(height: 8),
                    TextField(
                        controller: textController,
                        maxLines: 6,
                        decoration: const InputDecoration(border: OutlineInputBorder(), hintText: "1. Open Chrome\n2. Go to google.com"),
                    ),
                ],
              ),
            ),
            actions: [
                TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("Cancel")),
                ElevatedButton(
                    onPressed: () {
                         if(textController.text.isNotEmpty) {
                             Navigator.pop(ctx);
                             _analyzeTaskList(textController.text);
                         }
                    }, 
                    child: const Text("Analyze & Load")
                ),
            ],
           ),
         )
      );
  }
  
  void _analyzeTaskList(String rawText) async {
       setState(() {
           _isChatOpen = true;
           _messages.add(ChatMessage(sender: 'Robot', text: "Analyzing Task List against my memory...", isLoading: true));
       });
       
       final lines = rawText.split('\n').map((l) => l.trim().replaceAll(RegExp(r'^[\d\-\.\s]+'), '')).where((l) => l.isNotEmpty).toList();
       final unknownTasks = <String>[];
       double totalSteps = 0;
       double knownSteps = 0;
       
       for (final task in lines) {
           final verification = await _robot.decomposeAndVerify(task);
           bool taskFullyKnown = true;
           
           for (final step in verification) {
               totalSteps++;
               if (step.confidence > 0.85) {
                   knownSteps++;
               } else {
                   taskFullyKnown = false;
               }
           }
           
           if (!taskFullyKnown) {
               unknownTasks.add(task);
           }
       }
       
       int percentage = totalSteps == 0 ? 100 : ((knownSteps / totalSteps) * 100).toInt();
       
       setState(() {
           _messages.removeLast(); // Remove loading
           _messages.add(ChatMessage(
               sender: 'Robot', 
               text: "Analysis Complete.\n\n"
                     "My Confidence: $percentage%\n"
                     "Tasks: ${lines.length}\n"
                     "Tasks requiring clarification: ${unknownTasks.length}"
           ));
       });
       
       if (unknownTasks.isNotEmpty) {
           _messages.add(ChatMessage(sender: 'Robot', text: "I need help with ${unknownTasks.length} tasks before we start. Let's clarify them."));
           // Queue them up for the existing review loop
           setState(() {
               _failedTasksQueue = unknownTasks; 
               _isReviewingFailures = true;
           });
           
           // If we complete the review, we should then LOAD the original list.
           // We can store the pending list in a variable?
           // For now, let's just clarify. The user can press 'Load' again or we can auto-load.
           // To keep it simple: We clarify, save to memory. Then User re-uploads or we assume memory is now good.
           // Let's just start the review.
           _nextFailureReviewStep();
           
       } else {
           // All Good!
           _robot.loadTasks(rawText);
           _messages.add(ChatMessage(sender: 'Robot', text: "I am ready! Press 'START RUN' to begin execution."));
           ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Tasks Loaded & Verified!")));
       }
  }

  void _handleUserChat(String text) async {
       _resetIdleTimer();
       setState(() {
          _messages.add(ChatMessage(sender: 'User', text: text));
       });
       
       // Priority 1: Reviewing Failed Tasks
       if (_isReviewingFailures && _failedTasksQueue.isNotEmpty) {
           final currentTask = _failedTasksQueue.first;
           
           setState(() => _messages.add(ChatMessage(sender: 'Robot', text: 'Analyzing instructions...', isLoading: true)));
           
           // 1. Decompose & Verify
           final verification = await _robot.decomposeAndVerify(text);
           
           // 2. Check if we know everything
           // We relax the threshold slightly for "Yellow" (partly known) to be acceptable if user insists, 
           // but requirement says "only respond if able to perform". 
           // Let's stick to Green (>0.85) for "Able", maybe allow Yellow if we trust instructions? 
           // Strict mode: Only Green.
           final isFullyCapable = verification.every((s) => s.confidence > 0.85);

           setState(() {
              _messages.removeLast(); // Remove loading
              
              // Show the Checklist
              _messages.add(ChatMessage(
                  sender: 'Robot', 
                  text: isFullyCapable ? "I understand all steps:" : "I have analyzed your instructions:",
                  verificationSteps: verification
              ));
           });
           
           if (isFullyCapable) {
               // 3. Save & Proceed
               if (_currentUiState != null) {
                  await _robot.learn(
                      state: _currentUiState!,
                      goal: currentTask,
                      action: {'type': 'instruction', 'text': text},
                      factualDescription: text
                  );
               }
               setState(() => _failedTasksQueue.removeAt(0));
               _messages.add(ChatMessage(sender: 'Robot', text: "I am able to perform this task. Saved to memory."));
               _nextFailureReviewStep();
           } else {
               // 4. Ask for Clarification (Don't advance)
               // Identify unknown steps
               final unknowns = verification.where((s) => s.confidence <= 0.85).map((s) => s.stepDescription).toList();
               _messages.add(ChatMessage(
                   sender: 'Robot', 
                   text: "I am not confident about: ${unknowns.join(', ')}. Please explain these steps in more detail or simplify."
               ));
           }

           return;
       }
       
       // Priority 2: Reviewing Session
       if (_reviewSession != null) {
           _handleReviewResponse(text);
           return;
       }
       
       // Process
       if (_chatTargetBlock != null) {
           // Teaching Mode (One-off)
           setState(() => _messages.add(ChatMessage(sender: 'Robot', text: 'Thinking...', isLoading: true)));
           final knowledge = await _robot.parseTeachingResponse(text, _chatTargetBlock!.text);
           
           final action = {
              'type': 'click', 
              'target_text': _chatTargetBlock!.text,
              'x': _chatTargetBlock!.boundingBox.width / 2,
              'y': _chatTargetBlock!.boundingBox.height / 2,
           };
           
           await _robot.learn(
              state: _currentUiState!, 
              goal: knowledge['goal'], 
              action: action,
              factualDescription: knowledge['fact'],
              prerequisites: (knowledge['prerequisites'] as List).cast<String>(),
           );
           
           setState(() {
              _messages.removeLast(); // Remove loading
              _messages.add(ChatMessage(sender: 'Robot', text: "Thanks! I've learned that '${_chatTargetBlock!.text}' is for '${knowledge['goal']}' (Fact: ${knowledge['fact']})."));
              _chatTargetBlock = null; // Reset confusion
          });
          
       } else {
          // Q&A Mode (RAG)
           setState(() => _messages.add(ChatMessage(sender: 'Robot', text: 'Searching Memory...', isLoading: true)));
           final answer = await _robot.answerQuestion(text);
           setState(() {
              _messages.removeLast();
              _messages.add(ChatMessage(sender: 'Robot', text: answer));
           });
       }
  }

  Widget _buildLogView() {
    return Container(
      color: Colors.black87,
      width: double.infinity,
      padding: const EdgeInsets.all(8.0),
      child: SingleChildScrollView(
        reverse: true,
        child: Text(
          _statusLog,
          style: const TextStyle(color: Colors.greenAccent, fontFamily: 'Courier', fontSize: 12),
        ),
      ),
    );
  }

  void _showMockManagerDialog() {
       final pathController = TextEditingController();
       showDialog(context: context, builder: (ctx) => AlertDialog(
           title: const Text("Select Mock Screen"),
           content: SingleChildScrollView(
             child: Column(
               mainAxisSize: MainAxisSize.min,
               crossAxisAlignment: CrossAxisAlignment.start,
               children: [
                   const Text("Asset Library:", style: TextStyle(fontWeight: FontWeight.bold)),
                   DropdownButton<String>(
                       isExpanded: true,
                       value: _mockAssets.contains(_currentMockAsset) ? _currentMockAsset : null,
                       hint: const Text("Select Asset..."),
                       items: _mockAssets.map((m) => DropdownMenuItem(value: m, child: Text(m.split('/').last, overflow: TextOverflow.ellipsis))).toList(),
                       onChanged: (val) {
                           if(val!=null) {
                               setState(() {
                                   _currentMockAsset = val;
                                   _useMock = true; // Force mock mode
                               });
                               Navigator.pop(ctx);
                           }
                       }
                   ),
                   const Divider(),
                   const Text("External File:", style: TextStyle(fontWeight: FontWeight.bold)),
                   TextField(
                       controller: pathController, 
                       decoration: const InputDecoration(
                           hintText: "/sdcard/images/screen.png", 
                           suffixIcon: Icon(Icons.image)
                       )
                   ),
               ],
             ),
           ),
           actions: [
               TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("Cancel")),
               ElevatedButton(onPressed: () {
                   if (pathController.text.isNotEmpty) {
                       setState(() {
                           _currentMockAsset = pathController.text.trim();
                           _useMock = true;
                       });
                       Navigator.pop(ctx);
                   }
               }, child: const Text("Load File"))
           ]
       ));
  }

  @override
  Widget build(BuildContext context) {
    if (!_isInit) return const Scaffold(body: Center(child: CircularProgressIndicator()));
    final size = MediaQuery.of(context).size;
    final fit = _useMock ? BoxFit.contain : BoxFit.cover;

    return Scaffold(
      appBar: AppBar(
        title: const Text('🤖 Robot Tester', style: TextStyle(fontWeight: FontWeight.bold)),
        actions: [
           if (_isAnalyzingIdle)
               const Padding(
                 padding: EdgeInsets.all(8.0),
                 child: Icon(Icons.psychology, color: Colors.blueAccent),
               ),
           
           // Mock Manager [NEW]
           IconButton(
             icon: const Icon(Icons.collections),
             tooltip: "Select Mock Screen",
             onPressed: _showMockManagerDialog,
           ),

           // Task Upload
           IconButton(
             icon: const Icon(Icons.assignment),
             tooltip: "Load Task List",
             onPressed: _showTaskUploadDialog,
           ),

           // Training Toggle
           Switch(
             value: _isTrainingMode, 
             onChanged: (val) => setState(() => _isTrainingMode = val),
             activeColor: Colors.orange,
           ),
           const Text("Train ", style: TextStyle(fontSize: 12)),
           
           IconButton(
             icon: Icon(_useMock ? Icons.image : Icons.camera_alt),
             onPressed: () => setState(() => _useMock = !_useMock),
           ),
        ],
      ),
      body: Stack(
        children: [
          // 1. MAIN CONTENT
          Column(
            children: [
              Expanded(
                flex: 3,
                child: Container(
                  decoration: _isRecording ? BoxDecoration(border: Border.all(color: Colors.red, width: 4)) : null,
                  child: Stack(
                      fit: StackFit.expand,
                      children: [
                          if (_useMock && _currentMockAsset != null)
                             // Support both Assets and Files
                             (_currentMockAsset!.startsWith('assets/') 
                                ? Image.asset(_currentMockAsset!, fit: fit, key: ValueKey(_currentMockAsset))
                                : Image.file(File(_currentMockAsset!), fit: fit, key: ValueKey(_currentMockAsset)))
                          else if (_controller != null && _controller!.value.isInitialized)
                             CameraPreview(_controller!)
                          else
                             const Center(child: Text('Blind')),
  
                          if (_currentUiState != null)
                             CustomPaint(painter: VisionOverlayPainter(
                                 blocks: _blocks, imageSize: Size(_imageWidth.toDouble(), _imageHeight.toDouble()),
                                 previewSize: size, rotation: InputImageRotation.rotation0deg, cameraLensDirection: CameraLensDirection.back,
                                 highlightedBlock: _chatTargetBlock,
                             )),
                             
                          if (_isThinking) const Center(child: CircularProgressIndicator(color: Colors.red)),
                      ],
                  ),
                ),
              ),
              Expanded(flex: 1, child: _buildLogView()),
              Padding(
                padding: const EdgeInsets.all(16.0),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    if (_isTrainingMode)
                        FloatingActionButton.extended(
                          onPressed: _toggleTraining,
                          backgroundColor: _isRecording ? Colors.redAccent : Colors.orange,
                          icon: Icon(_isRecording ? Icons.stop : Icons.fiber_manual_record),
                          label: Text(_isRecording ? 'STOP REC' : 'RECORD SESSION'),
                        )
                    else 
                        FloatingActionButton.extended(
                          onPressed: _toggleRobot,
                          backgroundColor: _isRobotActive ? Colors.red : Colors.green,
                          icon: Icon(_isRobotActive ? Icons.stop : Icons.play_arrow),
                          label: Text(_isRobotActive ? 'STOP RUN' : 'START RUN'),
                        ),
                  ],
                ),
              ),
            ],
          ),
          
          // 2. CHAT OVERLAY
          if (_isChatOpen)
             DraggableScrollableSheet(
               initialChildSize: 0.5,
               minChildSize: 0.2,
               maxChildSize: 0.9,
               builder: (ctx, scrollController) {
                  return Container(
                    decoration: const BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
                      boxShadow: [BoxShadow(color: Colors.black26, blurRadius: 10)],
                    ),
                    child: Column(
                      children: [
                         Container(width: 40, height: 4, margin: const EdgeInsets.symmetric(vertical: 8), color: Colors.grey[300]),
                         Expanded(
                           child: ListView.builder(
                             controller: scrollController,
                             itemCount: _messages.length,
                             itemBuilder: (ctx, i) => _buildChatMessage(_messages[i]),
                           ),
                         ),
                         Padding(
                           padding: const EdgeInsets.all(8.0),
                           child: TextField(
                             controller: _chatController,
                             decoration: InputDecoration(
                               hintText: _reviewSession != null ? "Verify Hypothesis..." : "Type reply...",
                               suffixIcon: IconButton(
                                 icon: const Icon(Icons.send),
                                 onPressed: () {
                                   final text = _chatController.text.trim();
                                   if (text.isNotEmpty) {
                                     _handleUserChat(text);
                                     _chatController.clear();
                                   }
                                 },
                               ),
                               border: OutlineInputBorder(borderRadius: BorderRadius.circular(24)),
                             ),
                             onSubmitted: (val) {
                                if (val.isNotEmpty) {
                                  _handleUserChat(val);
                                  _chatController.clear();
                                }
                             },
                           ),
                         ),
                      ],
                    ),
                  );
               },
             ),
             
          if (!_isChatOpen) 
             Positioned(
               right: 16,
               bottom: 80, 
               child: FloatingActionButton(
                  mini: true,
                  child: Icon(Icons.chat),
                  onPressed: () => setState(() => _isChatOpen = true),
               ),
             ),
           
           // Close Chat
           if (_isChatOpen)
             Positioned(
               right: 16,
               top: 40,
               child: CircleAvatar(
                 backgroundColor: Colors.grey[300],
                 child: IconButton(icon: Icon(Icons.close), onPressed: () => setState(() => _isChatOpen = false)),
               ),
             )
        ],
      ),
    );
  }

  Widget _buildChatMessage(ChatMessage msg) {
      final isMe = msg.sender == 'User';
      return Align(
        alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: isMe ? Colors.blue[100] : Colors.grey[200],
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
               if (msg.imageBytes != null)
                   Padding(
                     padding: const EdgeInsets.only(bottom: 8),
                     child: Image.memory(msg.imageBytes!, height: 100),
                   ),
               if (msg.isLoading)
                  const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
               else
                  Text(msg.text),
                  
               if (msg.verificationSteps != null)
                  Column(
                     crossAxisAlignment: CrossAxisAlignment.start,
                     children: msg.verificationSteps!.map((step) {
                         IconData icon;
                         Color color;
                         String tooltip;
                         
                         if (step.confidence > 0.85) {
                             icon = Icons.check_circle;
                             color = Colors.green;
                             tooltip = "Known Step";
                         } else if (step.confidence > 0.5) {
                             icon = Icons.remove_circle_outline; // Dash-ish
                             color = Colors.orange;
                             tooltip = "Partly Known";
                         } else {
                             icon = Icons.cancel;
                             color = Colors.red;
                             tooltip = "Unknown";
                         }
                         
                         return Padding(
                           padding: const EdgeInsets.symmetric(vertical: 4.0),
                           child: Row(
                             children: [
                                Icon(icon, color: color, size: 16),
                                const SizedBox(width: 8),
                                Expanded(child: Text(step.stepDescription, style: const TextStyle(fontSize: 12))),
                             ],
                           ),
                         );
                     }).toList(),
                  )
            ],
          ),
        ),
      );
  }
}

class ChatMessage {
  final String sender;
  final String text;
  final Uint8List? imageBytes;
  final OcrBlock? highlightBlock;
  final bool isLoading;
  final List<TaskStepVerification>? verificationSteps; // [NEW]

  ChatMessage({
      required this.sender, 
      required this.text, 
      this.imageBytes, 
      this.highlightBlock, 
      this.isLoading = false,
      this.verificationSteps,
  });
}

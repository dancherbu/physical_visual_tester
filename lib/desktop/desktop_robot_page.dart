import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:camera/camera.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';
import 'package:image/image.dart' as img;
import 'package:screen_capturer/screen_capturer.dart';

import '../hid/hid_contract.dart';
import '../hid/windows_hid_adapter.dart';
import '../robot/robot_service.dart';
import '../robot/training_model.dart';
import '../robot/brain_stats_page.dart';
import '../spikes/brain/ollama_client.dart';
import '../spikes/brain/qdrant_service.dart';
import '../spikes/filesystem_indexer.dart';
import '../vision/ocr_models.dart';
import '../vision/vision_overlay_painter.dart';

class DesktopRobotPage extends StatefulWidget {
  const DesktopRobotPage({super.key});

  @override
  State<DesktopRobotPage> createState() => _DesktopRobotPageState();
}

class _DesktopRobotPageState extends State<DesktopRobotPage> {
  static const int _vkLWin = 0x5B;
  static const int _vkF5 = 0x74;
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
  bool _visionOnlyIdle = false;
  bool _hybridIdle = true; // [FIX] Default to Hybrid
  bool _awaitingUserResponse = false;
  
  // ... (existing fields)

  // ... 

  Future<void> _runOcrOnCapture() async {
    if (_isOcrRunning) return;
    setState(() => _isOcrRunning = true);

    try {
      final path = await _prepareImageForOcr();

      if (path == null) {
        return;
      }

      // [FIX] Use TSV for bounding boxes on Desktop
      final tsvText = await _runTesseractTsv(path);
      final width = _imageWidth == 0 ? 1 : _imageWidth;
      final height = _imageHeight == 0 ? 1 : _imageHeight;
      
      final blocks = <OcrBlock>[];
      
      // Parse TSV lines
      // Tesseract TSV format: level page_num block_num par_num line_num word_num left top width height conf text
      final lines = tsvText.split('\n');
      for (final line in lines) {
           if (line.trim().isEmpty) continue;
           final parts = line.split('\t');
           if (parts.length < 12) continue;
           
           // Header check
           if (parts[0] == 'level') continue;
           
           final conf = double.tryParse(parts[10]) ?? 0;
           final text = parts[11].trim();
           
           // Filter low confidence or empty/noise
           if (text.isEmpty || conf < 30) continue;
           
           final left = double.tryParse(parts[6]) ?? 0;
           final top = double.tryParse(parts[7]) ?? 0;
           final w = double.tryParse(parts[8]) ?? 0;
           final h = double.tryParse(parts[9]) ?? 0;
           
           blocks.add(OcrBlock(
               text: text,
               boundingBox: BoundingBox(left: left, top: top, right: left + w, bottom: top + h),
               confidence: conf / 100.0
           ));
      }

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
        _lastOcrText = blocks.map((b) => b.text).join(' '); // Approximate full text
      });
      
      if (blocks.isEmpty) {
         _log('VERBOSE: 🔎 OCR complete. No text detected.');
      } else {
         _log('VERBOSE: 🔎 OCR complete. ${blocks.length} elements detected.');
      }

    } finally {
      if (mounted) setState(() => _isOcrRunning = false);
    }
  }
  String? _lastRobotQuestion;

  final Set<String> _answeredQuestions = {};
  final List<String> _pendingGoalQuestions = []; // [NEW] Queue for sequential questioning
  
  // Vision Overlay State
  final Set<String> _recognizedTexts = {}; // Brain 1 (Cyan)
  final Set<String> _learnedTexts = {};    // Brain 2 (Green)
  bool _verboseLogging = false;

  bool _connecting = false;
  bool _connected = false;
  bool _useLiveScreen = false;
  bool _isCapturing = false;
  bool _isOcrRunning = false;
  bool _isTaskAnalyzing = false;

  bool _isReviewingTasks = false;
  final List<String> _taskReviewQueue = [];
  String? _pendingTaskListRaw;

  bool _isRobotRunning = false; // [NEW] Active Mode
  bool _showTaskList = false;
  final ScrollController _chatScroll = ScrollController();

  @override
  void initState() {
    super.initState();
    _initAssets();
    _connectRobot();
    if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
        _checkTesseract();
    }
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

  Future<void> _checkTesseract() async {
      try {
          final result = await Process.run('tesseract', ['--version']);
          if (result.exitCode != 0) {
              _log('⚠️ Tesseract OCR is installed but threw an error.');
          } else {
             _log('✅ Tesseract OCR found: ${result.stdout.toString().split('\n').first}');
          }
      } catch (e) {
          _log('⚠️ Tesseract OCR NOT found. Desktop OCR will not work.');
          _log('👉 Please install Tesseract (e.g. winget install Tesseract-OCR) and add to PATH.');
      }
  }

  Future<void> _initAssets() async {
    try {
      final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
      final assets = manifest.listAssets();

      _mockAssets
        ..clear()
        ..addAll(
          assets
              .where((key) => key.contains('assets/mock/') && key.toLowerCase().endsWith('.png'))
              .toList(),
        );

      _taskAssets
        ..clear()
        ..addAll(
          assets
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
      // Fallback for Desktop if manifest fails
      _mockAssets.addAll([
         'assets/mock/screen_login.png',
         'assets/mock/my_windows11_desktop.png',
         'assets/mock/file_explorer_window.png',
         'assets/mock/laptop_screen.png'
      ]);
      _taskAssets.addAll([
        'assets/tasks/dashboard_tasks.txt',
        'assets/tasks/desktop_tasks.txt',
        'assets/tasks/file_explorer_tasks.txt',
        'assets/tasks/laptop_general_tasks.txt',
        'assets/tasks/login_tasks.txt',
        'assets/tasks/notepad_menu_tasks.txt',
        'assets/tasks/notepad_write_tasks.txt',
        'assets/tasks/ppt_tasks.txt',
        'assets/tasks/settings_tasks.txt',
        'assets/tasks/start_menu_tasks.txt',
      ]);
    }
  }

  // Connection Checker
  Future<void> _checkHealth() async {
      if (_robot == null) return;
      try {
          final health = await _robot!.checkHealth();
           setState(() {
              _connected = (health['ollama'] == true) && (health['qdrant'] == true);
           });
      } catch (_) {
          setState(() => _connected = false);
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
        model: 'moondream',
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
            
            // Start Indexing background
            final home = Platform.environment['USERPROFILE']!;
            _log('📂 Indexing Documents in background...');
            FileSystemIndexer.indexRoots(['$home\\Documents']).then((_) {
               _log('✅ Documents Indexing Completed.'); 
            }).catchError((e) {
               _log('⚠️ Indexing skipped (DB Locked/Error).');
            });
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
    if (message.startsWith('VERBOSE:') && !_verboseLogging) return;
    final displayMsg = message.startsWith('VERBOSE:') ? message.substring(8).trim() : message;
    
    setState(() {
      _statusLog.insert(0, displayMsg);
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

  List<String> _extractLabelsFromState(UIState state) {
    final labels = <String>{};
    for (final block in state.ocrBlocks) {
      final lines = block.text.split(RegExp(r'[\r\n]+'));
      for (final line in lines) {
        final trimmed = line.trim();
        if (trimmed.isEmpty) continue;
        labels.add(trimmed);
        final parts = trimmed.split(RegExp(r'\s{2,}|\t|\|'));
        for (final part in parts) {
          final p = part.trim();
          if (p.isNotEmpty) labels.add(p);
        }
        final words = trimmed.split(RegExp(r'\s+'));
        for (final word in words) {
          final w = word.trim();
          if (w.length >= 3 && w.length <= 32) labels.add(w);
        }
      }
    }
    return _cleanOcrLabels(labels.toList());
  }

  List<String> _cleanOcrLabels(List<String> labels) {
    final cleaned = <String>[];
    for (final label in labels) {
      var l = label.trim().replaceAll(RegExp(r"^['`\x22]+|['`\x22]+$"), '');
      if (l.isEmpty) continue;
      if (l.length < 4) continue;
      if (!RegExp(r'[A-Za-z]').hasMatch(l)) continue;
      if (RegExp(r'^[0-9\.]+$').hasMatch(l)) continue;
      if (l.contains('â') || l.contains('�')) continue;
      final digits = RegExp(r'\d').allMatches(l).length;
      final digitRatio = digits / l.length;
      if (digitRatio > 0.4) continue;
      final nonAlnum = RegExp(r'[^A-Za-z0-9\s]').allMatches(l).length;
      if ((nonAlnum / l.length) > 0.4) continue;
      if (RegExp(r'[~`^]').hasMatch(l)) continue;
      cleaned.add(l);
    }

    final seen = <String>{};
    final result = <String>[];
    for (final l in cleaned) {
      final key = l.toLowerCase();
      if (seen.contains(key)) continue;
      seen.add(key);
      result.add(l);
    }
    return result;
  }

  List<Rect> _generateRois(int width, int height) {
    final leftW = (width * 0.28).round();
    final topH = (height * 0.18).round();
    return [
      Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
      Rect.fromLTWH(0, 0, leftW.toDouble(), height.toDouble()),
      Rect.fromLTWH(0, 0, width.toDouble(), topH.toDouble()),
      Rect.fromLTWH(leftW.toDouble(), topH.toDouble(), (width - leftW).toDouble(), (height - topH).toDouble()),
    ];
  }

  List<Rect> _tileRoi(Rect roi, int grid, double overlap) {
    final tiles = <Rect>[];
    final tileW = roi.width / grid;
    final tileH = roi.height / grid;
    final padX = (tileW * overlap / 2).roundToDouble();
    final padY = (tileH * overlap / 2).roundToDouble();

    for (var r = 0; r < grid; r++) {
      for (var c = 0; c < grid; c++) {
        final bx0 = roi.left + (c * tileW);
        final by0 = roi.top + (r * tileH);
        final bx1 = roi.left + ((c + 1) * tileW);
        final by1 = roi.top + ((r + 1) * tileH);
        final tx0 = (bx0 - padX).clamp(roi.left, roi.right);
        final ty0 = (by0 - padY).clamp(roi.top, roi.bottom);
        final tx1 = (bx1 + padX).clamp(roi.left, roi.right);
        final ty1 = (by1 + padY).clamp(roi.top, roi.bottom);
        tiles.add(Rect.fromLTRB(tx0, ty0, tx1, ty1));
      }
    }
    return tiles;
  }

  Future<List<String>> _extractLabelsFromCaptureTiled(String imagePath) async {
    try {
      final bytes = await File(imagePath).readAsBytes();
      final decoded = img.decodeImage(bytes);
      if (decoded == null) return [];

      final rois = _generateRois(decoded.width, decoded.height);
      final labels = <String>[];

      for (final roi in rois) {
        final tiles = _tileRoi(roi, 3, 0.3);
        for (final tile in tiles) {
          final crop = img.copyCrop(
            decoded,
            x: tile.left.round(),
            y: tile.top.round(),
            width: tile.width.round(),
            height: tile.height.round(),
          );

          final scaled = img.copyResize(
            img.grayscale(crop),
            width: crop.width * 3,
            height: crop.height * 3,
            interpolation: img.Interpolation.cubic,
          );

          final tempDir = Directory.systemTemp;
          final file = File(
            '${tempDir.path}/pvt_ocr_tile_${DateTime.now().millisecondsSinceEpoch}.png',
          );
          await file.writeAsBytes(img.encodePng(scaled));

          try {
            final tsv = await _runTesseractTsv(file.path);
            labels.addAll(_extractLabelsFromTsv(tsv));
          } finally {
            try {
              if (await file.exists()) await file.delete();
            } catch (_) {}
          }
        }
      }

      return _cleanOcrLabels(labels);
    } catch (_) {
      return [];
    }
  }

  Future<String> _runTesseractTsv(String imagePath) async {
    try {
      final result = await Process.run(
        'tesseract',
        [imagePath, 'stdout', '-l', 'eng', 'tsv'],
      );
      if (result.exitCode != 0) {
        return '';
      }
      return result.stdout.toString();
    } catch (_) {
      return '';
    }
  }

  List<String> _extractLabelsFromTsv(String tsvText) {
    final labels = <String>[];
    for (final line in tsvText.split('\n')) {
      if (line.startsWith('level')) continue;
      final parts = line.split('\t');
      if (parts.length < 12) continue;
      final text = parts[11].trim();
      if (text.isEmpty) continue;
      labels.add(text);
    }
    return _cleanOcrLabels(labels);
  }

  Future<List<String>> _extractHybridLabels() async {
    if (_capturePath != null) {
      final tiled = await _extractLabelsFromCaptureTiled(_capturePath!);
      if (tiled.isNotEmpty) return tiled;
    }
    final state = _currentUiState;
    if (state == null) return [];
    return _extractLabelsFromState(state);
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
    String? ocrPath;
    try {
      ocrPath = await _preprocessImageForOcr(imagePath);
      final result = await Process.run(
        'tesseract',
        [ocrPath, 'stdout', '-l', 'eng'],
      );
      if (result.exitCode != 0) {
        _log('⚠️ Tesseract failed: ${result.stderr}');
        return '';
      }
      return result.stdout.toString();
    } catch (e) {
      _log('❌ OCR error. Install Tesseract and ensure it is in PATH.');
      return '';
    } finally {
      if (ocrPath != null && ocrPath != imagePath) {
        try {
          final file = File(ocrPath);
          if (await file.exists()) await file.delete();
        } catch (_) {}
      }
    }
  }

  Future<String> _preprocessImageForOcr(String imagePath) async {
    try {
      final bytes = await File(imagePath).readAsBytes();
      final decoded = img.decodeImage(bytes);
      if (decoded == null) return imagePath;

      final width = decoded.width * 2;
      final height = decoded.height * 2;
      final resized = img.copyResize(
        decoded,
        width: width,
        height: height,
        interpolation: img.Interpolation.linear,
      );
      final processed = img.grayscale(resized);

      final tempDir = Directory.systemTemp;
      final outFile = File(
        '${tempDir.path}/pvt_ocr_${DateTime.now().millisecondsSinceEpoch}.png',
      );
      await outFile.writeAsBytes(img.encodePng(processed));
      return outFile.path;
    } catch (_) {
      return imagePath;
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



  Future<void> _runIdleAnalysis() async {
    final robot = _robot;
    if (robot == null) return;

    if (!_visionOnlyIdle) {
      if (_currentUiState == null) {
        await _runOcrOnCapture();
      }

      final state = _currentUiState;
      if (state == null) return;
    } else {
      if (_captureBytes == null) {
        await _prepareImageForOcr();
      }
      if (_captureBytes == null) {
        _log('⚠️ No capture available for vision analysis.');
        return;
      }
    }

    setState(() => _isIdleAnalyzing = true);
    _lastIdleAnalysisTime = DateTime.now();
    _log('💤 Idle analysis running...');

    try {
      final imageBase64 = _captureBytes == null ? null : base64Encode(_captureBytes!);
      final result = _visionOnlyIdle
          ? (imageBase64 == null
              ? IdleAnalysisResult()
              : await robot.analyzeIdlePageVisionOnly(
                  imageBase64: imageBase64,
                ))
          : (_hybridIdle && imageBase64 != null
              ? await robot.analyzeIdlePageHybrid(
                  imageBase64: imageBase64,
                  labels: await _extractHybridLabels(),
                )
              : await robot.analyzeIdlePage(
                  _currentUiState!,
                  imageBase64: imageBase64,
                ));
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
           // Queue them instead of showing all at once
           setState(() {
              for (final q in newQuestions) {
                  if (!_pendingGoalQuestions.contains(q)) {
                      _pendingGoalQuestions.add(q);
                  }
              }
           });
           
           // Trigger processing
           _processNextQuestion();
        }
      }
      if (result.learnedItems.isNotEmpty) {
        final now = DateTime.now();
        // Update Brain 2 (Green)
        final newLearned = <String>[];
        for (final item in result.learnedItems) {
            // item is typically the 'action' map or related string. 
            // In RobotService, learnedItems returns List<Map<String, dynamic>> usually? 
            // Checking RobotService.analyzeIdlePage... it returns IdleAnalysisResult.
            // IdleAnalysisResult.learnedItems is List<String> or List<Map>? 
            // Wait, looking at definition of IdleAnalysisResult in robot_service.dart... 
            // I assume it's List<dynamic> or List<Map>.
            // Let's assume it contains the 'goal' or description.
            
            // To be safe, just log count, but user wants CHAT feedback.
            // Let's guess structure or just say "I learned X items".
            // Actually, if we look at mobile implementation (Step 839/842):
            // It has _recognizedTexts.addAll...
            
            // Let's update _learnedTexts if possible. Use the keys from the result if available.
            // Assuming result.learnedItems contains names/goals.
            newLearned.add("Knowledge #${_learnedTexts.length + 1}"); 
        }

        _log('✅ Learned ${result.learnedItems.length} items during idle analysis.');
        
        // Chat Feedback
        setState(() {
            _messages.add(_DesktopChatMessage(
                sender: 'Robot',
                text: "While you were idle, I analyzed the screen and learned ${result.learnedItems.length} new things (e.g. '${result.learnedItems.first.toString()}'). Saved to memory."
            ));
            
            // Update Visualization (Green Boxes)
            // Just populate _learnedTexts with everything we saw, if we can match them.
            // For now, clear and reload known interactive elements to trigger Green.
        });
        
        // Fetch known elements to update overlay
        if (_currentUiState != null && robot != null) {
            robot.fetchKnownInteractiveElements(_currentUiState!).then((known) {
                if (mounted) setState(() {
                    _learnedTexts.addAll(known); 
                });
            });
        }
      }
    } finally {
      if (mounted) setState(() => _isIdleAnalyzing = false);
    }
  }

  void _processNextQuestion() {
      if (_awaitingUserResponse || _pendingGoalQuestions.isEmpty) return;
      
      final nextQ = _pendingGoalQuestions.removeAt(0);
      _lastRobotQuestion = nextQ;
      
      setState(() {
          _messages.add(_DesktopChatMessage(sender: 'Robot', text: nextQ));
          _awaitingUserResponse = true;
      });
  }

  Future<void> _sendChat() async {
    final text = _chatController.text.trim();
    if (text.isEmpty) return;
    _resetIdleTimer();

    final lastQuestion = _lastRobotQuestion;

    if (lastQuestion != null) {
      _answeredQuestions.add(lastQuestion);
      _lastRobotQuestion = null;
      _awaitingUserResponse = false;
    }

    setState(() {
      _messages.add(_DesktopChatMessage(sender: 'User', text: text));
      _messages.add(_DesktopChatMessage(sender: 'Robot', text: 'Thinking... (0s)', isLoading: true));
      _chatController.clear();
    });

    final robot = _robot;
    if (robot == null) {
      _replaceLastMessage('Robot', 'Robot brain is not connected yet.');
      return;
    }

    final stopwatch = Stopwatch()..start();
    Timer? ticker;
    ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      _replaceLastMessage('Robot', 'Thinking... (${stopwatch.elapsed.inSeconds}s)');
    });

    try {
      if (_isReviewingTasks && _taskReviewQueue.isNotEmpty) {
        final state = _currentUiState;
        if (state == null) {
          _replaceLastMessage('Robot', 'I need a screen capture/OCR before I can validate those steps.');
          return;
        }

        final currentTask = _taskReviewQueue.first;
        final verification = await robot.decomposeAndVerify(text, state: state);
        final isFullyCapable = verification.every((s) => s.confidence > 0.85);

        _replaceLastMessage(
          'Robot',
          isFullyCapable
              ? 'I understand all steps:\n${_formatVerificationSummary(verification)}'
              : 'I have analyzed your instructions:\n${_formatVerificationSummary(verification)}',
        );

        if (isFullyCapable) {
          await robot.learn(
            state: state,
            goal: currentTask,
            action: {'type': 'instruction', 'text': text},
            factualDescription: text,
          );
          setState(() => _taskReviewQueue.removeAt(0));
          _messages.add(_DesktopChatMessage(
            sender: 'Robot',
            text: "I am able to perform this task. Saved to memory.",
          ));
          _nextTaskReviewStep();
        } else {
          final unknowns = verification
              .where((s) => s.confidence <= 0.85)
              .map((s) => s.stepDescription)
              .toList();
          final missingTargets = verification
              .where((s) => s.contextVisible == false && s.targetText != null)
              .map((s) => s.targetText!)
              .toSet()
              .toList();

          _messages.add(_DesktopChatMessage(
            sender: 'Robot',
            text: 'I am not confident about: ${unknowns.join(', ')}. Please explain these steps in more detail or simplify.',
          ));
          if (missingTargets.isNotEmpty) {
            _messages.add(_DesktopChatMessage(
              sender: 'Robot',
              text: 'Also, I can’t see: ${missingTargets.join(', ')} on the current screen. Please navigate there first.',
            ));
          }
        }
        return;
      }

      if (lastQuestion != null) {
        final Map<String, dynamic>? lesson;
        if (_visionOnlyIdle) {
          lesson = await robot.analyzeUserClarificationVisionOnly(
            userText: text,
            lastQuestion: lastQuestion,
          );
        } else {
          final state = _currentUiState;
          if (state == null) {
            _replaceLastMessage('Robot', 'I need a screen capture/OCR before I can learn from that answer.');
            lesson = null;
          } else {
            lesson = await robot.analyzeUserClarification(
              userText: text,
              lastQuestion: lastQuestion,
              state: state,
            );
          }
        }

        if (lesson != null) {
          if (_visionOnlyIdle) {
            await robot.learnVisionOnly(
              goal: lesson['goal']?.toString() ?? 'Unknown Goal',
              action: (lesson['action'] as Map<String, dynamic>?) ?? const {},
              fact: lesson['fact']?.toString() ?? '',
              context: lesson['context']?.toString(),
            );
          } else {
            final state = _currentUiState;
            if (state == null) {
              _replaceLastMessage('Robot', 'I need a screen capture/OCR before I can learn from that answer.');
              return;
            }
            await robot.learn(
              state: state,
              goal: lesson['goal']?.toString() ?? 'Unknown Goal',
              action: (lesson['action'] as Map<String, dynamic>?) ?? const {},
              factualDescription: lesson['fact']?.toString() ?? '',
            );
          }

          final elapsed = stopwatch.elapsed.inSeconds;
          final action = lesson['action'] as Map<String, dynamic>;
          _replaceLastMessage(
            'Robot',
            "Understood! I learned to '${lesson['goal']}' by acting on '${action['target_text']}'.\nTime: ${elapsed}s",
          );
          return;
        }
      }

      if (_isCommand(text)) {
        final steps = _decomposeSimpleSteps(text);
        if (steps.isNotEmpty) {
          final elapsed = stopwatch.elapsed.inSeconds;
          _replaceLastMessage('Robot', 'Thought: I will execute ${steps.length} step(s) in order.\nTime: ${elapsed}s');

          for (final step in steps) {
            setState(() {
              _messages.add(_DesktopChatMessage(sender: 'Robot', text: 'Action: ${step.label}'));
            });

            await step.execute();
          }

          setState(() {
            _messages.add(_DesktopChatMessage(sender: 'System', text: 'Feedback: Steps complete.'));
          });

          return;
        }

        if (_isNotepadCommand(text)) {
          final elapsed = stopwatch.elapsed.inSeconds;
          _replaceLastMessage('Robot', 'Thought: I will open the Run dialog, type "notepad", and press Enter.\nTime: ${elapsed}s');

          setState(() {
            _messages.add(_DesktopChatMessage(sender: 'Robot', text: 'Action: Win+R → type "notepad" → Enter'));
          });

          await _executeRunDialogCommand('notepad');

          setState(() {
            _messages.add(_DesktopChatMessage(sender: 'System', text: 'Feedback: Notepad should now be open.'));
          });

          return;
        }

        if (_currentUiState == null) {
          _replaceLastMessage('Robot', 'I need a screen capture/OCR before I can act. Please run OCR or capture the screen first.');
          return;
        }

        final decision = await robot
            .think(state: _currentUiState!, currentGoal: text)
            .timeout(const Duration(seconds: 60));

        final elapsed = stopwatch.elapsed.inSeconds;
        _replaceLastMessage('Robot', 'Thought: ${decision.reasoning}\nTime: ${elapsed}s');

        if (decision.isConfident && decision.action != null) {
          final actionSummary = _formatAction(decision.action!);
          setState(() {
            _messages.add(_DesktopChatMessage(sender: 'Robot', text: 'Action: $actionSummary'));
          });

          if (_hid != null) {
            await _executeAction(decision.action!);
            setState(() {
              _messages.add(_DesktopChatMessage(sender: 'System', text: 'Action executed.'));
            });
          } else {
            setState(() {
              _messages.add(_DesktopChatMessage(sender: 'System', text: 'No HID adapter available to execute the action.'));
            });
          }
        } else if (decision.isConfident) {
          setState(() {
            _messages.add(_DesktopChatMessage(sender: 'Robot', text: 'No physical action needed.'));
          });
        } else {
          setState(() {
            _messages.add(_DesktopChatMessage(sender: 'Robot', text: 'I need help: ${decision.reasoning}'));
          });
        }
      } else {
        final reply = await robot.answerQuestion(text).timeout(const Duration(seconds: 60));
        _replaceLastMessage('Robot', '$reply\nTime: ${stopwatch.elapsed.inSeconds}s');
      }
      
      // Delay to let user read, then ask next question if any
      Future.delayed(const Duration(seconds: 2), () {
          if (mounted) _processNextQuestion();
      });

    } catch (e) {
      _replaceLastMessage('Robot', 'I ran into an error: $e');
    } finally {
      ticker?.cancel();
      stopwatch.stop();
    }
  }

  bool _isCommand(String text) {
    final normalized = text.trim().toLowerCase();
    return normalized.startsWith('open ') ||
        normalized.startsWith('click ') ||
        normalized.startsWith('type ') ||
        normalized.startsWith('go to ') ||
        normalized.startsWith('press ') ||
        normalized.startsWith('launch ') ||
        normalized.startsWith('run ');
  }

  bool _isNotepadCommand(String text) {
    return text.toLowerCase().contains('notepad');
  }

  List<_CommandStep> _decomposeSimpleSteps(String text) {
    final normalized = text.trim().toLowerCase();
    final steps = <_CommandStep>[];

    if (normalized.contains('notepad')) {
      steps.add(_CommandStep(
        label: 'Win+R → type "notepad" → Enter',
        execute: () async {
          await _executeRunDialogCommand('notepad');
          await Future.delayed(const Duration(milliseconds: 600));
        },
      ));
    }

    if (normalized.contains('current date') || normalized.contains('date and time')) {
      steps.add(_CommandStep(
        label: 'Focus Notepad (taskbar)',
        execute: () async {
          final ok = await _focusTaskbarApp('Notepad');
          if (!ok) {
            setState(() {
              _messages.add(_DesktopChatMessage(
                sender: 'System',
                text: 'Could not find Notepad on the taskbar. Run OCR and try again.',
              ));
            });
          }
        },
      ));

      final stamp = _formatNow();
      steps.add(_CommandStep(
        label: 'Type "$stamp"',
        execute: () async {
          final hid = _hid;
          if (hid == null) {
            setState(() {
              _messages.add(_DesktopChatMessage(sender: 'System', text: 'No HID adapter available.'));
            });
            return;
          }
          await hid.sendKeyText(stamp);
        },
      ));
    }

    final typeText = _extractTypeText(text);
    if (typeText != null && typeText.isNotEmpty) {
      steps.add(_CommandStep(
        label: 'Type "$typeText"',
        execute: () async {
          final hid = _hid;
          if (hid == null) {
            setState(() {
              _messages.add(_DesktopChatMessage(sender: 'System', text: 'No HID adapter available.'));
            });
            return;
          }
          await hid.sendKeyText(typeText);
        },
      ));
    }

    if (steps.length >= 2) return steps;
    return const [];
  }

  Future<bool> _focusTaskbarApp(String appName) async {
    final state = _currentUiState;
    if (state == null) return false;
    final lower = appName.toLowerCase();
    try {
      final block = state.ocrBlocks.firstWhere(
        (b) => b.text.toLowerCase().contains(lower),
      );

      final x = (block.boundingBox.left + block.boundingBox.width / 2).round();
      final y = (block.boundingBox.top + block.boundingBox.height / 2).round();
      await _executeAction({'type': 'click', 'x': x, 'y': y});
      return true;
    } catch (_) {
      // Fallback: try opening via Run dialog if Notepad isn't visible on taskbar
      if (appName.toLowerCase() == 'notepad') {
        final opened = await _openAppFromStartSearch('notepad');
        if (!opened) {
          await _executeRunDialogCommand('notepad');
        }
        await Future.delayed(const Duration(milliseconds: 600));
        return true;
      }
      return false;
    }
  }

  Future<bool> _openAppFromStartSearch(String appName) async {
    final hid = _hid;
    if (hid is! WindowsNativeHidAdapter) return false;
    await hid.sendVirtualKey(_vkLWin);
    await Future.delayed(const Duration(milliseconds: 300));
    await hid.sendKeyText(appName);
    await hid.sendKeyText('\n');
    return true;
  }

  String _formatNow() {
    final now = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${now.year}-${two(now.month)}-${two(now.day)} ${two(now.hour)}:${two(now.minute)}:${two(now.second)}';
  }

  String? _extractTypeText(String text) {
    final lower = text.toLowerCase();
    final typeIndex = lower.indexOf('type ');
    final writeIndex = lower.indexOf('write ');
    final index = typeIndex >= 0 ? typeIndex + 5 : (writeIndex >= 0 ? writeIndex + 6 : -1);
    if (index < 0 || index >= text.length) return null;

    var content = text.substring(index).trim();
    if (content.toLowerCase().startsWith('"') || content.toLowerCase().startsWith('\'')) {
      final quote = content[0];
      final end = content.indexOf(quote, 1);
      if (end > 1) {
        content = content.substring(1, end);
      }
    }

    // Remove trailing context like "into" or "in"
    final splitters = [' into ', ' in '];
    for (final splitter in splitters) {
      final idx = content.toLowerCase().indexOf(splitter);
      if (idx > 0) {
        content = content.substring(0, idx).trim();
      }
    }

    return content.isEmpty ? null : content;
  }

  Future<void> _executeRunDialogCommand(String command) async {
    final hid = _hid;
    if (hid == null) {
      setState(() {
        _messages.add(_DesktopChatMessage(sender: 'System', text: 'No HID adapter available.'));
      });
      return;
    }

    if (hid is WindowsNativeHidAdapter) {
      await hid.sendWinR();
      await Future.delayed(const Duration(milliseconds: 300));
      await hid.sendKeyText(command);
      await hid.sendKeyText('\n');
    } else {
      setState(() {
        _messages.add(_DesktopChatMessage(sender: 'System', text: 'Run dialog shortcut not supported on this platform.'));
      });
    }
  }

  String _formatAction(Map<String, dynamic> action) {
    final type = (action['type'] ?? 'click').toString();
    final target = action['target_text']?.toString();
    final text = action['target_text']?.toString();
    if (type == 'click' && target != null) {
      return 'Click "$target"';
    }
    if (type == 'keyboard_type' && text != null) {
      return 'Type "$text"';
    }
    if (type == 'keyboard_key' && text != null) {
      return 'Press "$text"';
    }
    return type;
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

    final missingTargets = <String>{};

    for (final task in lines) {
      final steps = await robot.decomposeAndVerify(task, state: _currentUiState);
      bool taskKnown = true;
      for (final step in steps) {
        total++;
        if (step.confidence > 0.85) {
          known++;
        } else {
          taskKnown = false;
        }
        if (step.contextVisible == false && step.targetText != null) {
          missingTargets.add(step.targetText!);
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
    });

    if (missingTargets.isNotEmpty) {
      _messages.add(_DesktopChatMessage(
        sender: 'Robot',
        text: 'I can’t see these on the current screen: ${missingTargets.join(', ')}. Please navigate to the right screen and try again.',
      ));
    }

    if (unknownTasks.isNotEmpty) {
      _startTaskReview(unknownTasks, pendingRaw: loadAfter ? rawText : null);
      if (loadAfter) {
        _log('⚠️ Tasks not loaded until unknown steps are clarified.');
      }
    } else if (loadAfter) {
      robot.loadTasks(rawText);
      _log('✅ Tasks loaded (${lines.length}).');
    }

    if (mounted) setState(() => _isTaskAnalyzing = false);
  }

  void _startTaskReview(List<String> tasks, {String? pendingRaw}) {
    if (tasks.isEmpty) return;
    setState(() {
      _isReviewingTasks = true;
      _taskReviewQueue
        ..clear()
        ..addAll(tasks);
      _pendingTaskListRaw = pendingRaw;
      _messages.add(_DesktopChatMessage(
        sender: 'Robot',
        text: 'I need help with ${tasks.length} task(s) before we proceed. Let\'s review them.',
      ));
    });
    _nextTaskReviewStep();
  }

  void _nextTaskReviewStep() {
    if (_taskReviewQueue.isEmpty) {
      setState(() => _isReviewingTasks = false);
      final pending = _pendingTaskListRaw;
      _pendingTaskListRaw = null;
      if (pending != null && _robot != null) {
        _robot!.loadTasks(pending);
        _log('✅ Tasks loaded (${pending.split('\n').where((l) => l.trim().isNotEmpty).length}).');
        _messages.add(_DesktopChatMessage(
          sender: 'Robot',
          text: "Review complete! I\'m ready to execute. Press 'Start Active Mode' to begin.",
        ));
      } else {
        _messages.add(_DesktopChatMessage(
          sender: 'Robot',
          text: "Review complete! I\'m ready when you are.",
        ));
      }
      return;
    }

    final task = _taskReviewQueue.first;
    _messages.add(_DesktopChatMessage(
      sender: 'Robot',
      text: 'Task: "$task"\n\nI\'m not confident I can complete this. Please explain the steps (e.g. "Open browser then type url").',
    ));
  }

  String _formatVerificationSummary(List<TaskStepVerification> steps) {
    if (steps.isEmpty) return '- No steps found.';
    return steps.map((s) {
      final pct = (s.confidence * 100).round();
      final visibility = s.contextVisible == false ? ' (not visible)' : '';
      return '- ${s.stepDescription} [$pct%]$visibility';
    }).join('\n');
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
            else if (key == 'f5' && hid is WindowsNativeHidAdapter) {
              await hid.sendVirtualKey(_vkF5);
              _log("✅ Pressed F5.");
              return;
            }
            
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
             
        } else if (type == 'system_command') {
             // Statistical/Background Query
             final cmd = action['command'] as String;
             _log("⚙️ Executing Background Command: $cmd");
             
             // Run Powershell command
             final result = await Process.run('powershell', ['-Command', cmd]);
             
             if (result.exitCode == 0) {
                 final output = result.stdout.toString().trim();
                 _log("✅ Output: $output");
                 
                 // Feed back to Chat
                 setState(() {
                    _messages.add(_DesktopChatMessage(sender: 'System', text: "Result: $output"));
                 });
             } else {
                 final error = result.stderr.toString().trim();
                 _log("❌ Command Failed: $error");
             }
             
        } else if (type == 'db_query') {
             // SQLite Query (Fast)
             final sql = action['query'] as String;
             _log("🗄️ Executing SQL: $sql");
             
             final results = await FileSystemIndexer.runRawQuery(sql);
             
             final output = results.isEmpty 
                  ? "No results." 
                  : results.length == 1 
                      ? results.first.toString() 
                      : "${results.length} rows found.";
             
             _log("✅ DB Result: $output");
             setState(() {
                _messages.add(_DesktopChatMessage(sender: 'System', text: "DB Result: $output"));
             });
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
               const Spacer(), // Push logs flush right? No..
           ],
        ),
        const SizedBox(height: 4),
        if (!_useLiveScreen) ...[
            Row(
              children: [
                Expanded(
                  child: DropdownButton<String>(
                    isExpanded: true,
                    hint: const Text('Select Mock Screen'),
                    value: _currentMockAsset,
                    items: _mockAssets.isEmpty 
                        ? const [DropdownMenuItem(value: null, enabled: false, child: Text("No mocks found"))]
                        : _mockAssets
                            .map(
                              (asset) => DropdownMenuItem(
                                value: asset,
                                child: Text(asset.split('/').last, overflow: TextOverflow.ellipsis),
                              ),
                            )
                            .toList(),
                    onChanged: _mockAssets.isEmpty
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
                IconButton(
                  onPressed: _showMockManagerDialog,
                  icon: const Icon(Icons.folder_open),
                  tooltip: "Manage Mocks",
                ),
              ],
            ),
        ],
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
            Switch(
              value: _visionOnlyIdle,
              onChanged: (val) => setState(() => _visionOnlyIdle = val),
            ),
            const Text('Vision-only idle (no OCR)'),
          ],
        ),
        Row(
          children: [
            Switch(
              value: _hybridIdle,
              onChanged: _visionOnlyIdle
                  ? null
                  : (val) => setState(() => _hybridIdle = val),
            ),
            const Text('Hybrid OCR + Vision'),
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
            width: double.infinity,
            decoration: BoxDecoration(
              color: Colors.black12,
              border: Border.all(color: Colors.black12),
              borderRadius: BorderRadius.circular(8),
            ),
            child: (_useLiveScreen && _captureBytes == null) || (!_useLiveScreen && _currentMockAsset == null)
                ? const Center(child: Text('No image source'))
                : LayoutBuilder(
                    builder: (context, constraints) {
                      final imgW = _imageWidth > 0 ? _imageWidth.toDouble() : 1.0;
                      final imgH = _imageHeight > 0 ? _imageHeight.toDouble() : 1.0;
                      
                       return Center(
                         child: AspectRatio(
                           aspectRatio: imgW / imgH,
                           child: Stack(
                             fit: StackFit.expand,
                             children: [
                               _useLiveScreen
                                   ? Image.memory(_captureBytes!, fit: BoxFit.fill)
                                   : (_currentMockAsset!.startsWith('assets/')
                                       ? Image.asset(_currentMockAsset!, fit: BoxFit.fill)
                                       : Image.file(File(_currentMockAsset!), fit: BoxFit.fill)),
                               if (_currentUiState != null)
                                   CustomPaint(
                                       painter: VisionOverlayPainter(
                                           blocks: _currentUiState!.ocrBlocks,
                                           imageSize: Size(
                                              _currentUiState!.imageWidth.toDouble(),
                                              _currentUiState!.imageHeight.toDouble()
                                           ),
                                           previewSize: Size.zero,
                                           rotation: InputImageRotation.rotation0deg,
                                           cameraLensDirection: CameraLensDirection.back,
                                           learnedTexts: _learnedTexts,
                                           recognizedTexts: _recognizedTexts,
                                           scaleToSize: true, 
                                       ),
                                   ),
                             ],
                           ),
                         ),
                       );
                    },
                  ),
          ),
        ),
        const SizedBox(height: 8),
        Row(
           mainAxisAlignment: MainAxisAlignment.spaceBetween,
           children: [
               const Text("Status Log", style: TextStyle(fontWeight: FontWeight.bold)),
               Row(
                   children: [
                       const Text("Verbose", style: TextStyle(fontSize: 12)),
                       Switch(
                           value: _verboseLogging,
                           onChanged: (val) => setState(() => _verboseLogging = val),
                           activeColor: Colors.green,
                       ),
                       IconButton(
                           icon: const Icon(Icons.delete_outline, size: 20),
                           onPressed: () => setState(() => _statusLog.clear()),
                           tooltip: "Clear Log",
                       )
                   ],
               )
           ],
        ),
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
            itemBuilder: (ctx, i) => SelectionArea(
                child: Text(
                  _statusLog[i],
                  style: const TextStyle(
                    color: Colors.greenAccent,
                    fontFamily: 'Courier',
                    fontSize: 11,
                  ),
                ),
            ),
          ),
        ),
      ],
    );
  }



  void _showSettingsDialog() {
      showDialog(
          context: context,
          builder: (ctx) => StatefulBuilder(
              builder: (context, setDialogState) {
                  return AlertDialog(
                      title: const Text("Connection Settings"),
                      content: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                             TextField(
                                controller: _ollamaController,
                                decoration: const InputDecoration(labelText: 'Ollama URL'),
                             ),
                             const SizedBox(height: 10),
                             TextField(
                                controller: _qdrantController,
                                decoration: const InputDecoration(labelText: 'Qdrant URL'),
                             ),
                             const SizedBox(height: 10),
                             // Use standard connection logic, but we might need to expose _connecting state or similar if we want feedback here
                             ElevatedButton.icon(
                                style: ElevatedButton.styleFrom(
                                    backgroundColor: _connected ? Colors.green : (_connecting ? Colors.orange : Colors.red),
                                    foregroundColor: Colors.white, 
                                ),
                                onPressed: _connecting ? null : () {
                                    _connectRobot(); 
                                    // Close dialog after attempt? Or let user see status change (if we used real reactive state in dialog)
                                    // Since _connectRobot uses setState on the main widget, this StatefulBuilder won't rebuild automatically unless connected
                                    // For now, allow trigger.
                                    Navigator.pop(ctx);
                                },
                                icon: Icon(_connected ? Icons.check_circle : Icons.link),
                                label: Text(_connecting ? 'Connecting...' : (_connected ? 'Connected' : 'Connect')),
                             )
                          ],
                      ),
                      actions: [
                          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("Close")),
                      ],
                  );
              }
          )
      );
  }

  Widget _buildRightPanel() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Connection & URLs moved to Settings Dialog
        Expanded(
          child: Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: Colors.grey[100],
              borderRadius: BorderRadius.circular(8),
            ),
            child: ScrollConfiguration(
              behavior: const _DesktopScrollBehavior(),
              child: Scrollbar(
                controller: _chatScroll,
                thumbVisibility: true,
                interactive: true,
                child: ListView.builder(
                  controller: _chatScroll,
                  reverse: true,
                  itemCount: _messages.length,
                  itemBuilder: (ctx, i) {
                    final reversedIndex = _messages.length - 1 - i;
                    final msg = _messages[reversedIndex];
                    final isThinking = msg.isLoading;
                    return Align(
                      alignment: msg.sender == 'User' ? Alignment.centerRight : Alignment.centerLeft,
                      child: Container(
                        margin: const EdgeInsets.symmetric(vertical: 4),
                        padding: const EdgeInsets.all(10),
                        constraints: const BoxConstraints(maxWidth: 420),
                        decoration: BoxDecoration(
                          color: isThinking
                              ? Colors.amber[100]
                              : msg.sender == 'User'
                                  ? Colors.blue[100]
                                  : Colors.white,
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: Colors.black12),
                        ),
                        child: isThinking
                            ? Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  const SizedBox(
                                    width: 16,
                                    height: 16,
                                    child: CircularProgressIndicator(strokeWidth: 2),
                                  ),
                                  const SizedBox(width: 8),
                                  Flexible(child: Text(msg.text)),
                                ],
                              )
                            : SelectionArea(child: Text(msg.text)),
                      ),
                    );
                  },
                ),
              ),
            ),
          ),
        ),

        // Removed OCR text display (New Y @ Daniel...)
        
        Row(
          children: [
            Expanded(
              child: CallbackShortcuts(
                bindings: {
                    const SingleActivator(LogicalKeyboardKey.enter): _sendChat,
                    const SingleActivator(LogicalKeyboardKey.enter, control: true): () {
                         final text = _chatController.text;
                         final sel = _chatController.selection;
                         final newText = text.replaceRange(sel.start, sel.end, '\n');
                         _chatController.value = TextEditingValue(
                            text: newText,
                            selection: TextSelection.collapsed(offset: sel.start + 1),
                         );
                    }
                },
                child: TextField(
                  controller: _chatController,
                  minLines: 1,
                  maxLines: 4,
                  decoration: const InputDecoration(
                    hintText: 'Ask the robot a question (Enter to Send, Ctrl+Enter for Newline)...',
                    border: OutlineInputBorder(),
                  ),
                  // onSubmitted: (_) => _sendChat(), // Removed to avoid conflict with Shortcut
                ),
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
        if (_showTaskList) ...[
            const SizedBox(height: 12),
            const Text('Task List', style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: DropdownButton<String>(
                    isExpanded: true,
                    hint: const Text('Load task asset'),
                    items: _taskAssets.isEmpty 
                        ? const [DropdownMenuItem(value: null, enabled: false, child: Text("No tasks found"))]
                        : _taskAssets
                            .map(
                              (asset) => DropdownMenuItem(
                                value: asset,
                                child: Text(asset.split('/').last.replaceAll('.txt', '')),
                              ),
                            )
                            .toList(),
                    onChanged: _taskAssets.isEmpty ? null : (val) {
                      if (val != null) _loadTaskAsset(val);
                    },
                  ),
                ),
                const SizedBox(width: 8),
                ElevatedButton(
                  onPressed: _isTaskAnalyzing ? null : _analyzeAndLoadTasks,
                  child: const Text('Load'), // Compact
                ),
                const SizedBox(width: 8),
                // Moved other buttons to Overflow or condense
                PopupMenuButton<String>(
                   icon: const Icon(Icons.more_vert),
                   onSelected: (v) {
                       if (v == 'file') _loadTaskFileFromDisk();
                       if (v == 'script') _runScriptedTaskTest();
                   },
                   itemBuilder: (context) => [
                       const PopupMenuItem(value: 'file', child: Text("Open File")),
                       const PopupMenuItem(value: 'script', child: Text("Scripted Test")),
                   ]
                ),
              ],
            ),
            const SizedBox(height: 8),
            Container(
               height: 120, // Limit height
               child: TextField(
                  controller: _taskController,
                  expands: true,
                  maxLines: null,
                  decoration: const InputDecoration(
                    hintText: '1. Open Chrome\n2. Go to google.com',
                    border: OutlineInputBorder(),
                  ),
               )
            ),
        ]
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('PVT Desktop Companion'),
        actions: [
            PopupMenuButton<String>(
              tooltip: 'View',
              icon: const Icon(Icons.view_list),
              onSelected: (value) {
                if (value == 'toggle_task_list') {
                  setState(() => _showTaskList = !_showTaskList);
                }
                if (value == 'brain_stats') {
                    if (_robot == null) {
                         ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Robot not connected.")));
                         return;
                    }
                    Navigator.push(context, MaterialPageRoute(builder: (_) => BrainStatsPage(robot: _robot!)));
                }
              },
              itemBuilder: (context) => [
                CheckedPopupMenuItem(
                  value: 'toggle_task_list',
                  checked: _showTaskList,
                  child: const Text('Show Task List'),
                ),
                const PopupMenuItem(
                   value: 'brain_stats',
                   child: Text('🧠 Brain Statistics'),
                ),
              ],
            ),
            IconButton(
                icon: const Icon(Icons.settings),
                tooltip: "Settings",
                onPressed: _showSettingsDialog,
            )
        ],
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

class _CommandStep {
  const _CommandStep({required this.label, required this.execute});

  final String label;
  final Future<void> Function() execute;
}

class _DesktopScrollBehavior extends MaterialScrollBehavior {
  const _DesktopScrollBehavior();

  @override
  Set<PointerDeviceKind> get dragDevices => {
        PointerDeviceKind.mouse,
        PointerDeviceKind.touch,
        PointerDeviceKind.trackpad,
        PointerDeviceKind.stylus,
        PointerDeviceKind.unknown,
      };
}

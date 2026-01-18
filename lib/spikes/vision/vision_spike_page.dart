import 'dart:async';
import 'dart:math';
import 'dart:io';
import 'dart:convert';


import 'package:flutter/services.dart'; // rootBundle
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';

import '../../vision/dialog_heuristics.dart';
import '../../vision/input_image_from_camera_image.dart';
import '../../vision/ocr_models.dart';
import '../../vision/vision_overlay_painter.dart';
import '../../vision/calibration_overlay.dart';
import '../../vision/homography_logic.dart';
import '../spike_store.dart';
import '../brain/teacher_service.dart';
import '../brain/ollama_client.dart';
import '../brain/qdrant_service.dart';



class VisionSpikePage extends StatefulWidget {
  const VisionSpikePage({super.key});

  @override
  State<VisionSpikePage> createState() => _VisionSpikePageState();
}

class _VisionSpikePageState extends State<VisionSpikePage> {
  CameraController? _controller;
  CameraDescription? _camera;
  final _recognizer = TextRecognizer(script: TextRecognitionScript.latin);
  
  // AI / Teacher
  TeacherService? _teacher;
  
  // Use "10.0.2.2" for Android Emulator, or your LAN IP (e.g. 192.168.1.X) for physical device.
  // Pass via flag: flutter run --dart-define=HOST_IP=192.168.1.50
  static const _hostIp = String.fromEnvironment('HOST_IP', defaultValue: '192.168.1.100');
  
  String _ollamaUrl = 'http://$_hostIp:11434';
  String _qdrantUrl = 'http://$_hostIp:6333';
  String _ollamaModel = 'nomic-embed-text'; 

  bool _starting = true;
  bool _streaming = false;
  bool _busy = false;
  bool _calibrating = false;
  bool _teaching = false;
  bool _crawling = false;

  List<OcrBlock> _blocks = const [];
  OcrBlock? _activeBlock; // The block currently being taught/clicked
  // Track which blocks we have successfully learned/saved to Memory
  final Set<String> _learnedTexts = {};
  UIState? _lastUiState;
  String? _error;

  // Mock Mode
  bool _useMock = false;
  List<String> _mockAssets = [];
  String? _currentMockAsset;

  int _imageWidth = 0;
  int _imageHeight = 0;

  CameraImage? _latestImage;
  Uint8List? _lastImageBytes; // For AI Vision (JPEG/PNG)
  
  // Calibration
  List<Offset>? _calibrationPoints; // Normalized 0..1 relative to Preview Widget
  List<double>? _homographyMatrix;
  
  @override
  void initState() {
    super.initState();
    unawaited(_initCamera());
    unawaited(_initMocks());
    
    // Auto-init Teacher with defaults
    _teacher = TeacherService(
      ollama: OllamaClient(
          baseUrl: Uri.parse(_ollamaUrl),
          model: _ollamaModel,
      ),
      qdrant: QdrantService(
          baseUrl: Uri.parse(_qdrantUrl),
          collectionName: 'pvt_memory',
      ),
    );
  }

  Future<void> _initMocks() async {
    List<String> mocks = [];
    try {
      final manifestContent = await rootBundle.loadString('AssetManifest.json');
      final Map<String, dynamic> manifestMap = json.decode(manifestContent);
      mocks = manifestMap.keys
          .where((String key) => key.contains('assets/mock') && key.endsWith('.png'))
          .toList();
    } catch (e) {
      debugPrint('Failed to load AssetManifest: $e');
    }

    // FALLBACK: If dynamic load fails, use hardcoded list
    if (mocks.isEmpty) {
       mocks = [
         'assets/mock/screen_login.png',
         'assets/mock/screen_dashboard.png',
         'assets/mock/screen_settings.png',
         'assets/mock/powerpoint/ppt_home.png',
         'assets/mock/powerpoint/ppt_editor_home.png',
         'assets/mock/powerpoint/ppt_editor_insert.png',
       ];
    }
    
    // Sort for consistency
    mocks.sort();

    setState(() {
      _mockAssets = mocks;
      if (_currentMockAsset == null && mocks.isNotEmpty) {
         if (mocks.any((m) => m.contains('ppt_home'))) {
            _currentMockAsset = mocks.firstWhere((m) => m.contains('ppt_home'));
         } else {
            _currentMockAsset = mocks.first;
         }
      }
    });
  }

  @override
  void dispose() {
    unawaited(_stopStream());
    unawaited(_recognizer.close());
    unawaited(_controller?.dispose());
    _teacher?.ollama.close();
    super.dispose();
  }
  
  void _setupAi() {
    final textControllerOllama = TextEditingController(text: _ollamaUrl);
    final textControllerQdrant = TextEditingController(text: _qdrantUrl);
    final textControllerModel = TextEditingController(text: _ollamaModel);

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Configure AI Backend'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: textControllerOllama,
              decoration: const InputDecoration(labelText: 'Ollama URL'),
            ),
            TextField(
              controller: textControllerModel,
              decoration: const InputDecoration(labelText: 'Embedding Model'),
            ),
            TextField(
              controller: textControllerQdrant,
              decoration: const InputDecoration(labelText: 'Qdrant URL'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              setState(() {
                _ollamaUrl = textControllerOllama.text;
                _qdrantUrl = textControllerQdrant.text;
                _ollamaModel = textControllerModel.text;
                
                _teacher = TeacherService(
                  ollama: OllamaClient(
                    baseUrl: Uri.parse(_ollamaUrl),
                    model: _ollamaModel,
                  ),
                  qdrant: QdrantService(
                    baseUrl: Uri.parse(_qdrantUrl),
                    collectionName: 'pvt_memory',
                  ),
                );
              });
              Navigator.pop(context);
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('AI Services Configured!')),
              );
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  Future<void> _initCamera() async {
    setState(() {
      _starting = true;
      _error = null;
    });

    try {
      final cameras = await availableCameras();
      if (cameras.isEmpty) {
        throw StateError('No cameras available on this device.');
      }

      final preferred = cameras.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.back,
        orElse: () => cameras.first,
      );

      // Use high resolution for better OCR text detection
      final controller = CameraController(
        preferred,
        ResolutionPreset.high,
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.yuv420,
      );

      await controller.initialize();
      // Ensure focus mode is auto for clear text
      await controller.setFocusMode(FocusMode.auto);

      setState(() {
        _controller = controller;
        _camera = preferred;
      });

      await _startStream();
    } catch (e) {
      setState(() {
        _error = e.toString();
      });
    } finally {
      setState(() {
        _starting = false;
      });
    }
  }

  Future<void> _startStream() async {
    final controller = _controller;
    if (controller == null || _streaming) return;

    // We still stream for the preview
    await controller.startImageStream((image) {
      _latestImage = image;
      // Only update dimensions from camera if NOT using mock
      if (!_useMock) {
        // We use a local variable update to avoid frequent setStates if not needed for UI?
        // Actually, Painter needs these. But Painter is rebuilt by other signals usually.
        // However, if we just assign to properties, setState might not be called.
        // The original code didn't call setState! 
        // Note: The original code showed:
        // _imageWidth = image.width;
        // _imageHeight = image.height;
        // INSIDE the listener, but OUTSIDE setState.
        // This is a race condition usually, but works if something else triggers build.
        
        _imageWidth = image.width;
        _imageHeight = image.height;
      }
    });

    setState(() {
      _streaming = true;
    });
  }

  Future<void> _stopStream() async {
    final controller = _controller;
    if (controller == null || !_streaming) return;

    await controller.stopImageStream();

    setState(() {
      _streaming = false;
    });
  }

  void _onCalibrationChanged(List<Offset> points) {
    _calibrationPoints = points;
  }

  void _saveCalibration() {
    if (_calibrationPoints == null || _calibrationPoints!.length != 4) return;

    // Source: User selected Normalized Points on Widget (0,0 to 1,1)
    final src = _calibrationPoints!.map((p) => Point(p.dx, p.dy)).toList();
    
    // Dest: Screen Normalized (0,0 to 1,1)
    // TL, TR, BR, BL
    final dst = [
      const Point(0.0, 0.0), // TL
      const Point(1.0, 0.0), // TR
      const Point(1.0, 1.0), // BR
      const Point(0.0, 1.0), // BL
    ];

    try {
      final h = HomographyLogic.findHomography(src, dst);
      setState(() {
        _homographyMatrix = h;
        _calibrating = false;
        _error = null;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Calibration Saved! Tap a block to test.')),
      );
    } catch (e) {
      setState(() => _error = 'Calibration failed: $e');
    }
  }

  Future<void> _captureAndOcr() async {
    if (_busy) return;

    final controller = _controller;
    if (!_useMock && (controller == null || !controller.value.isInitialized)) {
      setState(() => _error = 'Camera not ready.');
      return;
    }

    setState(() {
      _busy = true;
      _error = null;
    });

    try {
      String path;
      if (_useMock) {
        // Load from assets -> Temp File
        final asset = _currentMockAsset ?? 'assets/mock/laptop_screen.png';
        final byteData = await rootBundle.load(asset);
        final buffer = byteData.buffer;
        final tempDir = Directory.systemTemp;
        
        // Use unique name to avoid caching issues if reusing name or something?
        // Actually same name is fine, we overwrite.
        final tempFile = File('${tempDir.path}/mock_screen.png');
        await tempFile.writeAsBytes(
            buffer.asUint8List(byteData.offsetInBytes, byteData.lengthInBytes));
        path = tempFile.path;
      } else {
        final file = await controller!.takePicture();
        path = file.path;
      }

      final file = File(path);
      final bytes = await file.readAsBytes();
      
      // 2. Create InputImage from file
      final input = InputImage.fromFilePath(path);

      // 3. Process
      final recognized = await _recognizer.processImage(input);
      final blocks = <OcrBlock>[];

      // Decode size
      // We already have bytes, let's decode to get size.
      // Note: decodeImageFromList expects full buffer.
      final decodedImage = await decodeImageFromList(bytes);
      final actualWidth = decodedImage.width;
      final actualHeight = decodedImage.height;

      for (final b in recognized.blocks) {
        final rect = b.boundingBox;
        blocks.add(
          OcrBlock(
            text: b.text,
            boundingBox: BoundingBox(
              left: rect.left.toDouble(),
              top: rect.top.toDouble(),
              right: rect.right.toDouble(),
              bottom: rect.bottom.toDouble(),
            ),
            confidence: null, 
          ),
        );
      }

      final derived = DialogHeuristics.derive(
        blocks: blocks,
        imageWidth: actualWidth,
        imageHeight: actualHeight,
      );

      final uiState = UIState(
        ocrBlocks: blocks,
        imageWidth: actualWidth,
        imageHeight: actualHeight,
        derived: derived,
        createdAt: DateTime.now(),
      );

      setState(() {
        _blocks = blocks;
        _lastUiState = uiState;
        _lastImageBytes = bytes;
        _imageWidth = actualWidth;
        _imageHeight = actualHeight;
      });

      SpikeStore.lastUiState = uiState;
      
      // AUTO-CALIBRATE if Mock Mode
      // In Mock mode, we render with BoxFit.contain.
      // We can compute the Perfect Homography Matrix.
      // AUTO-CALIBRATE if Mock Mode
      if (_useMock) {
          // Reset error just in case
          if (_error?.contains('Calibration') == true) _error = null;
          
          setState(() {
             _homographyMatrix = [
               1.0, 0.0, 0.0,
               0.0, 1.0, 0.0,
               0.0, 0.0, 1.0
             ];
          });
      }
      
      // cleanup
      try {
        await File(file.path).delete();
      } catch (_) {} 
      
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

  // ... (Calibration methods)

  Future<void> _teachRecording(OcrBlock block, Point<double> clickCoords) async {
    final teacher = _teacher;
    final state = _lastUiState;
    if (teacher == null || state == null) {
      setState(() => _error = 'AI or State not ready.');
      return;
    }

    // Auto-Labeling Strategy
    setState(() => _activeBlock = block); // Highlight it
    var suggestion = '';
    // If we have an image, we can try Vision.
    if (_lastImageBytes != null) {
        // Show loading indicator in snackbar or something?
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Asking Ollama to identify...'), duration: Duration(seconds: 1)),
        );
        try {
            final base64Image = base64Encode(_lastImageBytes!);
            suggestion = await teacher.suggestLabel(block: block, debugImages: [base64Image]);
        } catch (_) {}
    } else {
        // Fallback or just text only
         try {
            suggestion = await teacher.suggestLabel(block: block);
        } catch (_) {}
    }

    if (!mounted) return;

    final goalController = TextEditingController(text: suggestion);
    String actionType = 'click'; // click, type
    final textParamController = TextEditingController();

    final result = await showDialog<Map<String, String>>(
      context: context,
      barrierColor: Colors.transparent, 
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          backgroundColor: Theme.of(context).dialogTheme.backgroundColor?.withValues(alpha: 0.7) ?? Colors.white.withValues(alpha: 0.7),
          elevation: 0,
          title: const Text('Teach: What are we doing?'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Block: "${block.text}"'),
              const SizedBox(height: 10),
              DropdownButton<String>(
                value: actionType,
                isExpanded: true,
                items: const [
                  DropdownMenuItem(value: 'click', child: Text('Click Element')),
                  DropdownMenuItem(value: 'type', child: Text('Type Text')),
                ],
                onChanged: (v) => setState(() => actionType = v!),
              ),
              const SizedBox(height: 10),
              if (actionType == 'type')
                TextField(
                  controller: textParamController,
                  decoration: const InputDecoration(
                    labelText: 'Text to type',
                    border: OutlineInputBorder(),
                  ),
                ),
              const SizedBox(height: 10),
              if (suggestion.isNotEmpty)
                 Text('🤖 Suggestion: "$suggestion"', style: const TextStyle(fontSize: 12, color: Colors.blueGrey)),
              const SizedBox(height: 6),
              TextField(
                controller: goalController,
                decoration: const InputDecoration(
                  hintText: 'e.g. "Login"',
                  border: OutlineInputBorder(),
                  labelText: 'Goal Description'
                ),
                autofocus: true,
              ),
            ],
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context, {'test_action': 'true', 'goal': 'test'}), 
                child: const Text('🧪 Test Action')
            ),
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
            FilledButton(
              onPressed: () => Navigator.pop(context, {
                'goal': goalController.text,
                'type': actionType,
                'param': textParamController.text,
              }),
              child: const Text('Learn'),
            ),
          ],
        ),
      ),
    );


    if (result == null || result['goal']!.trim().isEmpty) return;

    if (result.containsKey('test_action')) {
       // User chose to "Test" instead of immediately learn
       Navigator.pop(context); // Close dialog
       await _testAction(block, clickCoords);
       return;
    }

    _finalizeLearning(result, state, block, clickCoords).whenComplete(() {
       // Clear highlight only after learning is done
       if (mounted) setState(() => _activeBlock = null);
    });
  }

  Future<void> _finalizeLearning(Map<String, String> result, UIState state, OcrBlock block, Point<double> clickCoords) async {
    final teacher = _teacher;
    if (teacher == null) return;

    setState(() => _busy = true);
    try {
      final actionPayload = <String, dynamic>{
        'type': result['type'], // click or type
        'x': clickCoords.x,
        'y': clickCoords.y,
        'target_text': block.text,
      };
      
      if (result['type'] == 'type') {
        actionPayload['text'] = result['param'];
      }

      await teacher.learnTask(
        state: state,
        goal: result['goal']!,
        action: actionPayload,
      );
      
      if (mounted) {
        setState(() {
          _learnedTexts.add(block.text);
        });
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Lesson Saved to Memory!')));
      }
    } catch (e) {
      setState(() => _error = 'Learning failed: $e');
    } finally {
      setState(() => _busy = false);
    }
  }

  Future<void> _testAction(OcrBlock block, Point<double> clickCoords) async {
    final teacher = _teacher;
    if (teacher == null || _lastImageBytes == null) return;
    
    // 1. Capture BEFORE
    final beforeBytes = _lastImageBytes!;
    final beforeBase64 = base64Encode(beforeBytes);
    
    setState(() {
       _busy = true;
       _activeBlock = block; // Highlight active block
    });
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Testing Action...')));

    // 2. Perform Action (Simulate Click in Mock World)
    if (_useMock) {
       // Basic Router Simulation
       final txt = block.text.toLowerCase();
       if (txt.contains('login')) {
          _currentMockAsset = 'assets/mock/screen_dashboard.png';
       } else if (txt.contains('settings')) {
          _currentMockAsset = 'assets/mock/screen_settings.png';
       } else if (txt.contains('new presentation')) {
          _currentMockAsset = 'assets/mock/powerpoint/ppt_editor_home.png';
       } else if (txt.contains('insert')) {
          _currentMockAsset = 'assets/mock/powerpoint/ppt_editor_insert.png';
       } else if (txt.contains('home')) {
          if (_currentMockAsset!.contains('ppt_')) {
             _currentMockAsset = 'assets/mock/powerpoint/ppt_editor_home.png';
          }
       } else {
         // Default logic
         if (_currentMockAsset?.contains('settings') == true) {
             _currentMockAsset = 'assets/mock/screen_dashboard.png';
         }
       }
       // Force reload
       await Future.delayed(const Duration(milliseconds: 500));
       await _captureAndOcr(); 
    } else {
       // Real HID: Send click
       // await _hid.sendClick(clickCoords);
       // await Future.delayed(const Duration(seconds: 2));
       // await _captureAndOcr();
       
       // Just wait for now
       await Future.delayed(const Duration(milliseconds: 500));
    }

    // 3. Capture AFTER
    final afterBytes = _lastImageBytes!; // Updated by _captureAndOcr
    final afterBase64 = base64Encode(afterBytes);
    
    // 4. Analyze
    try {
      final analysis = await teacher.analyzeConsequence(
        base64Before: beforeBase64, 
        base64After: afterBase64, 
        actionLabel: block.text
      );
      
      if (!mounted) return;
      
      // 5. Evaluate Result
      final lower = analysis.toLowerCase();
      // Valid if not "no_change" and not "unknown"
      final success = !lower.contains('no_change') && 
                      !lower.contains('unknown') && 
                      !lower.contains('no visible change') &&
                      analysis.length > 2;

      if (success) {
         // AUTO-SAVE
         await _finalizeLearning({
             'goal': analysis, 
             'type': 'click',
             'param': '' 
         }, _lastUiState!, block, clickCoords);

         if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('Auto-Learned Action: "$analysis"'),
                backgroundColor: Colors.green,
                duration: const Duration(seconds: 4),
              )
            );
         }
      } else {
          // Fallback to Manual Inspection
          showDialog(
            context: context,
            barrierColor: Colors.transparent, // No dimming
            builder: (context) => AlertDialog(
              backgroundColor: Colors.black45, // Lighter for better visibility
              surfaceTintColor: Colors.transparent, // Material 3 fix
              elevation: 0,
              title: const Text('Analysis Uncertain'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                   Text('I clicked "${block.text}", but I am not sure what happened.'),
                   const SizedBox(height: 10),
                   Text('AI Output: "$analysis"', style: const TextStyle(fontWeight: FontWeight.bold)),
                   const SizedBox(height: 20),
                   const Text('Manual Review Required: If an action occurred, please Teach me. Else Discard.'),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context), 
                  child: const Text('Discard')
                ),
                FilledButton(
                  onPressed: () {
                     Navigator.pop(context); // close uncertain dialog
                     // Open Teach Dialog
                     _teachRecording(block, clickCoords);
                  }, 
                  child: const Text('Teach / Correct')
                ),
              ],
            ),
          );
      }
      
    } catch (e) {
      if(!_crawling) setState(() => _error = 'Analysis failed: $e');
    } finally {
      if(!_crawling) setState(() => _busy = false);
      if (mounted) setState(() => _activeBlock = null); // Clear highlight
    }
  }

  Future<void> _startCrawl() async {
     if (_homographyMatrix == null || _teacher == null) return;
     setState(() { _crawling = true; _busy = true; });
     ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Starting Autonomous Crawler...')));
     
     // BFS/DFS Queue?
     // For now, simple greedy pass on CURRENT screen
     // Ideally we re-scan after every action.
     
     int actionsTaken = 0;
     const maxActions = 5; // Safety limit
     
     try {
       for (int i=0; i<maxActions; i++) {
          if (!mounted || !_crawling) break;
          
          // 1. Scene Understanding (AI)
          setState(() { _error = 'AI Analyzing Scene...'; });
          
          // We need the current image
          // Assuming _processImage() or similar has populated _latestImage / _currentMock
          // We'll regenerate the Base64 from _latestImage for the AI
          String? b64;
          if (_useMock && _currentMockAsset != null) {
              final bytes = await DefaultAssetBundle.of(context).load(_currentMockAsset!);
              b64 = base64Encode(bytes.buffer.asUint8List());
          } else if (_latestImage != null) {
              // TODO: Convert CameraImage to JPEG/Base64 (expensive)
              // For now, assume Mock Mode is primary as per prompt.
          }
          
          List<OcrBlock> aiCandidates = [];
          
          if (b64 != null) {
             final analysis = await _teacher!.analyzeScreenContext(
               base64Image: b64, 
               blocks: _blocks
             );
             
             // Map back to blocks
             // And SAVE MEMORIES (Knowledge Building)
             for (final entry in analysis.entries) {
                final match = _blocks.firstWhere(
                   (b) => b.text.contains(entry.key), 
                   orElse: () => const OcrBlock(text: '', boundingBox: BoundingBox(left:0,top:0,right:0,bottom:0))
                );
                
                if (match.text.isNotEmpty) {
                   aiCandidates.add(match);
                   
                   // Save 'Memory' of this finding (as requested)
                   // "Vision computes/create embeddings and saves to qdrant"
                   await _teacher!.learnTask(
                     state: UIState(
                        ocrBlocks: _blocks, 
                        imageWidth: _imageWidth, imageHeight: _imageHeight, 
                        derived: const DerivedFlags(hasErrorCandidate:false, hasModalCandidate:false, modalKeywords:[]), 
                        createdAt: DateTime.now()
                     ),
                     goal: entry.value, // e.g. "Opens file menu"
                     action: {'type': 'click', 'target': match.text},
                   );
                }
             }
          }
          
          // Fallback to heuristic if AI fails or returns nothing (or if not in Mock mode)
          final finalCandidates = aiCandidates.isNotEmpty ? aiCandidates : _blocks.where((b) {
             final t = b.text.toLowerCase();
             if (_learnedTexts.contains(b.text)) return false;
             if (t.length < 3) return false;
             if (b.boundingBox.top < 80) return false;
             if (b.text.contains(' - ')) return false;
             return true; 
          }).toList();

          // Sort by Area descending (Largest first)
          finalCandidates.sort((a, b) => 
             (b.boundingBox.width * b.boundingBox.height)
             .compareTo(a.boundingBox.width * a.boundingBox.height)
          );
          
          if (finalCandidates.isEmpty) {
             setState(() => _error = 'Crawl finished: No new candidates.');
             break;
          }
          
          // 2. Pick the best one
          final target = finalCandidates.first;
          
           // Calculate Screen Coords
           final cx = target.boundingBox.left + target.boundingBox.width / 2;
           final cy = target.boundingBox.top + target.boundingBox.height / 2;
           
           final rot = _camera == null ? InputImageRotation.rotation0deg : rotationForCamera(_camera!.sensorOrientation);
           final lens = _camera?.lensDirection ?? CameraLensDirection.back;
           final imgSize = Size(_imageWidth.toDouble(), _imageHeight.toDouble());
           final previewSize = const Size(1.0, 1.0); 

           final normX = translateX(cx, rot, previewSize, imgSize, lens);
           final normY = translateY(cy, rot, previewSize, imgSize, lens);
           
           final screenPt = HomographyLogic.project(Point(normX, normY), _homographyMatrix!);

          // 3. Test Action
          await _testAction(target, screenPt); // This will click, move screen, save memory
          actionsTaken++;
          
          // 4. Wait for stabilize (already in testAction?)
          // If screen changed, _blocks is updated.
          // Loop continues with NEW blocks.
       }
     } catch (e) {
        setState(() => _error = 'Crawl error: $e');
     } finally {
        setState(() { _crawling = false; _busy = false; });
     }
  }

  Future<void> _autoScan() async {
    final teacher = _teacher;
    final state = _lastUiState;
    if (teacher == null || state == null || _lastImageBytes == null) {
      setState(() => _error = 'AI, State, or Image not ready.');
      return;
    }
    
    if (_homographyMatrix == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please Calibrate First!')),
      );
      return;
    }

    ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Asking Ollama to scan scene...'), duration: Duration(seconds: 2)),
    );

    setState(() => _busy = true);

    try {
      // 1. Ask Ollama for Labels
      final base64Image = base64Encode(_lastImageBytes!);
      final suggestedLabels = await teacher.suggestActionableFeatures(base64Image);
      
      if (suggestedLabels.isEmpty) {
        throw Exception('No features identified.');
      }

      int learned = 0;
      
      // 2. Find Matches in OCR
      // Normalized logic reuse
      final rot = _camera == null ? InputImageRotation.rotation0deg : rotationForCamera(_camera!.sensorOrientation);
      final lens = _camera?.lensDirection ?? CameraLensDirection.back;
      final imgSize = Size(_imageWidth.toDouble(), _imageHeight.toDouble());
      final previewSize = const Size(1.0, 1.0); // We map to Normalized for Homography

      for (final label in suggestedLabels) {
        // Simple case-insensitive match
        // "File" matches "File" or "File Menu"
        final match = _blocks.firstWhere(
           (b) => b.text.toLowerCase().contains(label.toLowerCase()) || label.toLowerCase().contains(b.text.toLowerCase()),
           orElse: () => const OcrBlock(text: '', boundingBox: BoundingBox(left:0,top:0,right:0,bottom:0)),
        );

        if (match.text.isNotEmpty) {
           // Success! We found the block corresponding to the suggested label.
           
           // Calculate Screen Coords
           final cx = match.boundingBox.left + match.boundingBox.width / 2;
           final cy = match.boundingBox.top + match.boundingBox.height / 2;
           
           final normX = translateX(cx, rot, previewSize, imgSize, lens);
           final normY = translateY(cy, rot, previewSize, imgSize, lens);
           
           final screenPt = HomographyLogic.project(Point(normX, normY), _homographyMatrix!);
           
           // Save Memory
           await teacher.learnTask(
             state: state, 
             goal: 'Click $label',  // We use the AI's label as the Goal
             action: {
              'type': 'click',
              'x': screenPt.x,
              'y': screenPt.y,
              'target_text': match.text,
              'auto_learned': true,
             }
           );
           learned++;
           // Mark as learned so it turns Green
           setState(() {
              _learnedTexts.add(match.text);
           });
        }
      }
      
      if (mounted) {
         final msg = 'Auto-Learned $learned new tasks from ${suggestedLabels.length} suggestions!';
         setState(() => _error = msg); // using error box for visibility
      }

    } catch (e) {
      setState(() => _error = 'Scan failed: $e');
    } finally {
      setState(() => _busy = false);
    }
  }

  void _onBlockTap(OcrBlock block) {
    if (_homographyMatrix == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please Calibrate First!')),
      );
      return;
    }

    // 1. Get Block Center in Image Pixels
    final cx = block.boundingBox.left + block.boundingBox.width / 2;
    final cy = block.boundingBox.top + block.boundingBox.height / 2;

    // 2. Convert Image Pixels -> Widget Normalized
    final rot = _camera == null ? InputImageRotation.rotation0deg : rotationForCamera(_camera!.sensorOrientation);
    final lens = _camera?.lensDirection ?? CameraLensDirection.back;
    
    final normX = translateX(cx, rot, const Size(1.0, 1.0), Size(_imageWidth.toDouble(), _imageHeight.toDouble()), lens
    );
    final normY = translateY(cy, rot, const Size(1.0, 1.0), Size(_imageWidth.toDouble(), _imageHeight.toDouble()), lens
    );

    // 3. Apply Homography
    final screenPt = HomographyLogic.project(Point(normX, normY), _homographyMatrix!);

    // 4. Act or Teach
    if (_teaching) {
      _teachRecording(block, screenPt);
    } else {
      // Check execution? Or just log?
       final msg = 'OCR "${block.text}"\nScreen: (${screenPt.x.toStringAsFixed(2)}, ${screenPt.y.toStringAsFixed(2)})';
       setState(() => _error = msg); 
       // TODO: Actually send the click?
       // _hid.sendClick...
    }
  }
  @override
  Widget build(BuildContext context) {
    final controller = _controller;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Vision Spike'),
        actions: [
          IconButton(
            tooltip: _crawling ? 'Stop Crawl' : 'Start Crawler',
            onPressed: (_teacher != null && !_busy) ? (_crawling ? () => setState(() => _crawling=false) : _startCrawl) : null,
            icon: Icon(Icons.bug_report, color: _crawling ? Colors.red : null),
          ),
          IconButton(
            tooltip: 'Auto Scan Scene',
            onPressed: (_teacher != null && !_busy && !_teaching && !_crawling) ? _autoScan : null,
            icon: const Icon(Icons.travel_explore),
          ),
           IconButton(
            tooltip: 'Config AI',
            onPressed: _setupAi,
            icon: Icon(Icons.psychology, color: _teacher != null ? Colors.green : Colors.grey),
          ),
          IconButton(
            tooltip: _teaching ? 'Stop Teaching' : 'Start Teacher Mode',
            onPressed: () {
               setState(() => _teaching = !_teaching);
            },
            icon: Icon(_teaching ? Icons.stop_circle : Icons.school, color: _teaching ? Colors.red : null),
          ),
          IconButton(
            tooltip: _calibrating ? 'Save Calibration' : 'Calibrate',
            onPressed: () {
               if (_calibrating) {
                 _saveCalibration();
               } else {
                 setState(() => _calibrating = true);
               }
            },
            icon: Icon(_calibrating ? Icons.save : Icons.crop_free), // Changed Icon
          ),

          IconButton(
            tooltip: 'Re-init camera',
            onPressed: _starting ? null : _initCamera,
            icon: const Icon(Icons.refresh),
          ),
          PopupMenuButton<String>(
             tooltip: 'Select Mock Image',
             // enabled: true, // Always enabled so we can toggle ON
             icon: Icon(Icons.monitor, color: _useMock ? Colors.amber : Colors.grey),
             onSelected: (val) {
               if (val == '__TOGGLE__') {
                 setState(() => _useMock = !_useMock);
               } else {
                 setState(() {
                    _currentMockAsset = val;
                    _useMock = true; // Force Mock mode if picking a mock
                 });
                 ScaffoldMessenger.of(context).hideCurrentSnackBar();
                 ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                   content: Text('Processing Mock Image...'), 
                   duration: Duration(milliseconds: 1000)
                 ));
                 
                 // Trigger re-capture with slightly longer delay to allow render
                 Future.delayed(const Duration(milliseconds: 300), _captureAndOcr);
               }
             },
             itemBuilder: (context) {
               return [
                 const PopupMenuItem(
                   value: '__TOGGLE__',
                   child: Text('Toggle Camera / Mock'),
                 ),
                   const PopupMenuDivider(),
                   ..._mockAssets.map((asset) => PopupMenuItem(
                     value: asset,
                     child: Text(asset.split('/').last),
                   )),
               ];
             },
          ),
        ],
      ),
      body: (!_useMock && _starting)
          ? const Center(child: CircularProgressIndicator())
          : (!_useMock && (controller == null || !controller.value.isInitialized))
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text(_error ?? 'Camera not initialized.'),
                  ),
                )
              : LayoutBuilder(
                  builder: (context, constraints) {
                    final previewSize = Size(
                      constraints.maxWidth,
                      constraints.maxHeight,
                    );

                    return Stack(
                      fit: StackFit.expand,
                      children: [
                        if (_useMock)
                          Image.asset(
                             _currentMockAsset ?? 'assets/mock/laptop_screen.png',
                             fit: BoxFit.fill, // FILL strictly for correct alignment
                          )
                        else
                          CameraPreview(controller!),
                        if (!_calibrating)
                          GestureDetector(
                              onTapUp: (details) {
                                // Naive block hit testing
                                // We need to inverse map or project blocks to widget space to hit test.
                                // VisionOverlayPainter paints them in Widget Space.
                                // So we can project all blocks to Widget Space and check distance.
                                
                                final tap = details.localPosition;
                                final rot = _camera == null ? InputImageRotation.rotation0deg : rotationForCamera(_camera!.sensorOrientation);
                                final lens = _camera?.lensDirection ?? CameraLensDirection.back;
                                final imgSize = Size(_imageWidth.toDouble(), _imageHeight.toDouble());
                                
                                OcrBlock? best;
                                double bestDist = 10000;
                                
                                for (final b in _blocks) {
                                    final cx = b.boundingBox.left + b.boundingBox.width/2;
                                    final cy = b.boundingBox.top + b.boundingBox.height/2;
                                    final wx = translateX(cx, rot, previewSize, imgSize, lens);
                                    final wy = translateY(cy, rot, previewSize, imgSize, lens);
                                    
                                    final dist = (Offset(wx, wy) - tap).distance;
                                    if (dist < 50 && dist < bestDist) { // 50px threshold
                                        best = b;
                                        bestDist = dist;
                                    }
                                }
                                
                                if (best != null) {
                                    _onBlockTap(best);
                                }
                              },
                              child: CustomPaint(
                                painter: VisionOverlayPainter(
                                  blocks: _blocks,
                                  imageSize: Size(
                                    _imageWidth.toDouble(),
                                    _imageHeight.toDouble(),
                                  ),
                                  previewSize: previewSize,
                                  rotation: _useMock || _camera == null
                                      ? InputImageRotation.rotation0deg
                                      : rotationForCamera(
                                          _camera!.sensorOrientation),
                                  cameraLensDirection: _useMock 
                                      ? CameraLensDirection.back 
                                      : (_camera?.lensDirection ?? CameraLensDirection.back),
                                  learnedTexts: _learnedTexts,
                                  highlightedBlock: _activeBlock,
                                ),
                              ),
                          ),
                        if (_teaching) 
                          Positioned(
                            bottom: 150, // Moved up to avoid bottom sheet
                            left: 0,
                            right: 0,
                            child: Center(
                              child: Container(
                                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                                decoration: BoxDecoration(color: Colors.red, borderRadius: BorderRadius.circular(20)),
                                child: const Text('TEACHING MODE', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                              ),
                            ),
                          ),
                        if (_calibrating)
                          CalibrationOverlay(
                            onChanged: _onCalibrationChanged,
                            initialPoints: _calibrationPoints,
                          ),
                        if (_error != null)
                          Align(
                            alignment: Alignment.topCenter,
                            child: Container(
                              margin: const EdgeInsets.all(12),
                              padding: const EdgeInsets.all(12),
                              decoration: BoxDecoration(
                                color: Colors.red.withValues(alpha: 0.85),
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Text(
                                _error!,
                                style: const TextStyle(color: Colors.white),
                              ),
                            ),
                          ),
                      ],
                    );
                  },
                ),
      bottomSheet: _BottomPanel(
        busy: _busy,
        streaming: _streaming,
        blocks: _blocks,
        uiState: _lastUiState,
        onCapture: _captureAndOcr,
      ),
    );
  }
}

class _BottomPanel extends StatelessWidget {
  const _BottomPanel({
    required this.busy,
    required this.streaming,
    required this.blocks,
    required this.uiState,
    required this.onCapture,
  });

  final bool busy;
  final bool streaming;
  final List<OcrBlock> blocks;
  final UIState? uiState;
  final VoidCallback onCapture;

  @override
  Widget build(BuildContext context) {
    final derived = uiState?.derived;

    return SafeArea(
      top: false,
      child: Container(
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surface,
          border: Border(
            top: BorderSide(color: Theme.of(context).dividerColor),
          ),
        ),
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Blocks: ${blocks.length}  •  Stream: ${streaming ? 'ON' : 'OFF'}',
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                ),
                FilledButton.icon(
                  onPressed: busy ? null : onCapture,
                  icon: busy
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.camera),
                  label: const Text('Capture + OCR'),
                ),
              ],
            ),
            if (derived != null) ...[
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 6,
                children: [
                  _Chip(
                    label: 'modal=${derived.hasModalCandidate}',
                    ok: derived.hasModalCandidate,
                  ),
                  _Chip(
                    label: 'error=${derived.hasErrorCandidate}',
                    ok: !derived.hasErrorCandidate,
                  ),
                  if (derived.modalKeywords.isNotEmpty)
                    _Chip(
                      label: 'keywords: ${derived.modalKeywords.join(', ')}',
                      ok: true,
                    ),
                ],
              ),
            ],
            if (uiState != null) ...[
              const SizedBox(height: 10),
              SizedBox(
                height: 120,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: Theme.of(context)
                        .colorScheme
                        .surfaceContainerHighest
                        .withValues(alpha: 0.7),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(10),
                    child: Text(
                      uiState!.toPrettyJson(),
                      style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                    ),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({required this.label, required this.ok});

  final String label;
  final bool ok;

  @override
  Widget build(BuildContext context) {
    final color = ok ? Colors.green : Colors.orange;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        border: Border.all(color: color.withValues(alpha: 0.45)),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: Theme.of(context)
            .textTheme
            .labelMedium
            ?.copyWith(color: color.shade700),
      ),
    );
  }
}

import 'dart:async';
import 'dart:math';
import 'dart:io';
import 'dart:convert';
import 'dart:typed_data';

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

// HID
import '../../hid/hid_contract.dart';
import '../../hid/method_channel_hid_adapter.dart';

class VisionSpikePage extends StatefulWidget {
  const VisionSpikePage({super.key});

  @override
  State<VisionSpikePage> createState() => _VisionSpikePageState();
}

class _VisionSpikePageState extends State<VisionSpikePage> {
  CameraController? _controller;
  CameraDescription? _camera;
  final _recognizer = TextRecognizer(script: TextRecognitionScript.latin);
  
  // HID
  final HidAdapter _hid = MethodChannelHidAdapter();
  
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

  List<OcrBlock> _blocks = const [];
  UIState? _lastUiState;
  String? _error;

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
      _imageWidth = image.width;
      _imageHeight = image.height;
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
    if (controller == null || !controller.value.isInitialized) {
      setState(() => _error = 'Camera not ready.');
      return;
    }

    setState(() {
      _busy = true;
      _error = null;
    });

    try {
      // 1. Capture a high-quality JPEG
      final file = await controller.takePicture();
      final bytes = await file.readAsBytes();
      
      // 2. Create InputImage from file
      final input = InputImage.fromFilePath(file.path);

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
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Teach: What are we doing?'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Action: Click "${block.text}" at ${clickCoords.x.toStringAsFixed(2)}, ${clickCoords.y.toStringAsFixed(2)}'),
            const SizedBox(height: 10),
            if (suggestion.isNotEmpty)
               Text('🤖 AI Suggests: "$suggestion"', style: const TextStyle(fontSize: 12, color: Colors.blueGrey)),
            const SizedBox(height: 6),
            TextField(
              controller: goalController,
              decoration: const InputDecoration(
                hintText: 'e.g. "Click Search Bar"',
                border: OutlineInputBorder(),
                labelText: 'Label / Goal'
              ),
              autofocus: true,
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, goalController.text), child: const Text('Learn')),
        ],
      ),
    );

    if (result == null || result.trim().isEmpty) return;

    setState(() => _busy = true);
    try {
      await teacher.learnTask(
        state: state,
        goal: result,
        action: {
          'type': 'click',
          'x': clickCoords.x,
          'y': clickCoords.y,
          'target_text': block.text,
        },
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Lesson Saved to Memory!')));
      }
    } catch (e) {
      setState(() => _error = 'Learning failed: $e');
    } finally {
      setState(() => _busy = false);
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
    final centerImage = block.boundingBox.center; 
    // center is string "[x, y]", we need doubles. Re-calculate.
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
            tooltip: 'Auto Scan Scene',
            onPressed: (_teacher != null && !_busy && !_teaching) ? _autoScan : null,
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
            icon: Icon(_calibrating ? Icons.save : Icons.grid_4x4),
          ),
          IconButton(
            tooltip: 'Re-init camera',
            onPressed: _starting ? null : _initCamera,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: _starting
                ? const Center(child: CircularProgressIndicator())
                : (controller == null || !controller.value.isInitialized)
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
                              CameraPreview(controller),
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
                                        rotation: _camera == null
                                            ? InputImageRotation.rotation0deg
                                            : rotationForCamera(
                                                _camera!.sensorOrientation),
                                        cameraLensDirection:
                                            _camera?.lensDirection ??
                                                CameraLensDirection.back,
                                      ),
                                    ),
                                ),
                              if (_teaching) 
                                Positioned(
                                  bottom: 16,
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
          ),
          _BottomPanel(
            busy: _busy,
            streaming: _streaming,
            blocks: _blocks,
            uiState: _lastUiState,
            onCapture: _captureAndOcr,
          ),
        ],
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

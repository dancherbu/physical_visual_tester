import 'dart:async';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';

import '../spikes/spike_store.dart';
import '../vision/dialog_heuristics.dart';
import '../vision/input_image_from_camera_image.dart';
import '../vision/ocr_models.dart';
import '../vision/vision_overlay_painter.dart';

class EyeActionsLogView extends StatefulWidget {
  const EyeActionsLogView({super.key});

  @override
  State<EyeActionsLogView> createState() => _EyeActionsLogViewState();
}

class _EyeActionsLogViewState extends State<EyeActionsLogView> {
  CameraController? _controller;
  CameraDescription? _camera;
  final _recognizer = TextRecognizer(script: TextRecognitionScript.latin);

  bool _starting = true;
  bool _streaming = false;
  String? _error;

  // OCR Loop State
  bool _ocrBusy = false;
  Timer? _ocrTimer;
  CameraImage? _latestImage;
  int _imageWidth = 0;
  int _imageHeight = 0;

  List<OcrBlock> _blocks = const [];
  UIState? _lastUiState;

  // Throttle configuration
  static const _ocrInterval = Duration(milliseconds: 500); // 2 FPS

  @override
  void initState() {
    super.initState();
    unawaited(_initCamera());
  }

  @override
  void dispose() {
    _ocrTimer?.cancel();
    unawaited(_stopStream());
    unawaited(_recognizer.close());
    unawaited(_controller?.dispose());
    super.dispose();
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

      // Prioritize External (HDMI Capture), then Back, then any
      final preferred = cameras.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.external,
        orElse: () => cameras.firstWhere(
          (c) => c.lensDirection == CameraLensDirection.back,
          orElse: () => cameras.first,
        ),
      );

      final controller = CameraController(
        preferred,
        ResolutionPreset.high, // Higher res for better OCR
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.yuv420,
      );

      await controller.initialize();

      if (!mounted) return;

      setState(() {
        _controller = controller;
        _camera = preferred;
      });

      await _startStream();
      // _startOcrLoop(); // [DISABLED] Moving to RobotTesterPage for AI Vision
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString();
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _starting = false;
        });
      }
    }
  }

  Future<void> _startStream() async {
    final controller = _controller;
    if (controller == null || _streaming) return;

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



  Future<void> _processFrame() async {
    if (_ocrBusy || !_streaming || _error != null) return;

    final camera = _camera;
    final image = _latestImage;
    if (camera == null || image == null) return;

    _ocrBusy = true;
    // Don't setState just for busy flag to avoid frame jitter, unless we show a spinner

    try {
      final input = inputImageFromCameraImage(image, camera: camera);
      if (input == null) {
        // Platform not supported or conversion failed
        _ocrBusy = false;
        return;
      }

      final recognized = await _recognizer.processImage(input);
      final blocks = <OcrBlock>[];

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
            confidence: null, // ML Kit doesn't expose confidence easily per block yet
          ),
        );
      }

      final derived = DialogHeuristics.derive(
        blocks: blocks,
        imageWidth: _imageWidth,
        imageHeight: _imageHeight,
      );

      final uiState = UIState(
        ocrBlocks: blocks,
        imageWidth: _imageWidth,
        imageHeight: _imageHeight,
        derived: derived,
        createdAt: DateTime.now(),
      );

      SpikeStore.lastUiState = uiState;

      if (mounted) {
        setState(() {
          _blocks = blocks;
          _lastUiState = uiState;
        });
      }
    } catch (e) {
      debugPrint('OCR Loop Error: $e');
    } finally {
      _ocrBusy = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    // If we have an error, show it
    if (_error != null) {
      return Container(
        color: Colors.black,
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.error_outline, color: Colors.red, size: 48),
                const SizedBox(height: 16),
                Text(
                  _error!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white70),
                ),
                const SizedBox(height: 16),
                FilledButton(
                  onPressed: _initCamera,
                  child: const Text('Retry Camera'),
                ),
              ],
            ),
          ),
        ),
      );
    }

    if (_starting || _controller == null || !_controller!.value.isInitialized) {
      return Container(
        color: Colors.black,
        child: const Center(
          child: CircularProgressIndicator(color: Colors.white54),
        ),
      );
    }

    // Main Camera View with Overlay
    return LayoutBuilder(
      builder: (context, constraints) {
        final previewSize = Size(constraints.maxWidth, constraints.maxHeight);
        
        // Note: CameraPreview aspect ratio handling is tricky. 
        // For this simple tester, letting Flutter's CameraPreview handle it is simplest,
        // but our overlay might misalign if aspect ratios differ significantly.
        // We pass the raw image size to the painter to handle scaling logic there.

        return Stack(
          fit: StackFit.expand,
          children: [
            CameraPreview(_controller!),
            
            // Vision Overlay (OCR Boxes)
            IgnorePointer(
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
                      : rotationForCamera(_camera!.sensorOrientation),
                  cameraLensDirection:
                      _camera?.lensDirection ?? CameraLensDirection.back,
                  learnedTexts: const {}, // No learning in Log View
                ),
              ),
            ),

            // Top Status Bar (Transparent)
            Positioned(
              left: 0,
              right: 0,
              top: 0,
              child: Container(
                padding: EdgeInsets.only(
                  top: MediaQuery.of(context).padding.top + 8,
                  left: 16,
                  right: 16,
                  bottom: 8,
                ),
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Colors.black54, Colors.transparent],
                  ),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.remove_red_eye, color: Colors.greenAccent, size: 16),
                    const SizedBox(width: 8),
                    Text(
                      _ocrBusy ? 'Processing...' : 'Monitoring (${_blocks.length} blocks)',
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                        shadows: [Shadow(blurRadius: 2, color: Colors.black)],
                      ),
                    ),
                    const Spacer(),
                    if (_camera?.lensDirection == CameraLensDirection.external)
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                        decoration: BoxDecoration(
                          color: Colors.blue,
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: const Text(
                          'HDMI/USB',
                          style: TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.bold),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

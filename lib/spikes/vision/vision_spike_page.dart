import 'dart:async';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';

import 'dialog_heuristics.dart';
import 'input_image_from_camera_image.dart';
import 'ocr_models.dart';
import 'vision_overlay_painter.dart';
import '../spike_store.dart';

class VisionSpikePage extends StatefulWidget {
  const VisionSpikePage({super.key});

  @override
  State<VisionSpikePage> createState() => _VisionSpikePageState();
}

class _VisionSpikePageState extends State<VisionSpikePage> {
  CameraController? _controller;
  CameraDescription? _camera;
  final _recognizer = TextRecognizer(script: TextRecognitionScript.latin);

  bool _starting = true;
  bool _streaming = false;
  bool _busy = false;

  List<OcrBlock> _blocks = const [];
  UIState? _lastUiState;
  String? _error;

  int _imageWidth = 0;
  int _imageHeight = 0;

  CameraImage? _latestImage;

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

      final preferred = cameras.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.back,
        orElse: () => cameras.first,
      );

      final controller = CameraController(
        preferred,
        ResolutionPreset.medium,
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.yuv420,
      );

      await controller.initialize();

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

  Future<void> _captureAndOcr() async {
    if (_busy) return;

    final camera = _camera;
    final image = _latestImage;
    if (camera == null || image == null) {
      setState(() {
        _error = 'Camera not ready yet.';
      });
      return;
    }

    setState(() {
      _busy = true;
      _error = null;
    });

    try {
      final input = inputImageFromCameraImage(image, camera: camera);
      if (input == null) {
        throw StateError(
          'InputImage conversion is not supported on this platform yet.',
        );
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
            confidence: null,
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

      setState(() {
        _blocks = blocks;
        _lastUiState = uiState;
      });

      SpikeStore.lastUiState = uiState;
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

  @override
  Widget build(BuildContext context) {
    final controller = _controller;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Vision Spike'),
        actions: [
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
                              IgnorePointer(
                                child: CustomPaint(
                                  painter: VisionOverlayPainter(
                                    blocks: _blocks,
                                    imageSize: Size(
                                      _imageWidth.toDouble(),
                                      _imageHeight.toDouble(),
                                    ),
                                    previewSize: previewSize,
                                  ),
                                ),
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

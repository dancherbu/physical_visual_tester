import 'dart:io';
import 'dart:typed_data';
import 'dart:ui';

import 'package:camera/camera.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';

/// Converts a [CameraImage] into an ML Kit [InputImage].
///
/// This is implemented for Android NV21/YUV420 images (typical for the `camera`
/// plugin). For iOS/macOS/web this spike currently does not support conversion.
InputImage? inputImageFromCameraImage(
  CameraImage image, {
  required CameraDescription camera,
 }) {
  if (!Platform.isAndroid) {
    return null;
  }

  final format = InputImageFormatValue.fromRawValue(image.format.raw);
  if (format == null) return null;

  final rotation = rotationForCamera(camera.sensorOrientation);

  final bytes = _concatenatePlaneBytes(image.planes);

  return InputImage.fromBytes(
    bytes: bytes,
    metadata: InputImageMetadata(
      size: Size(image.width.toDouble(), image.height.toDouble()),
      rotation: rotation,
      format: format,
      bytesPerRow: image.planes.first.bytesPerRow,
    ),
  );
}

InputImageRotation rotationForCamera(int sensorOrientation) {
  switch (sensorOrientation) {
    case 0:
      return InputImageRotation.rotation0deg;
    case 90:
      return InputImageRotation.rotation90deg;
    case 180:
      return InputImageRotation.rotation180deg;
    case 270:
      return InputImageRotation.rotation270deg;
  }
  return InputImageRotation.rotation0deg;
}

Uint8List _concatenatePlaneBytes(List<Plane> planes) {
  final builder = BytesBuilder(copy: false);
  for (final plane in planes) {
    builder.add(plane.bytes);
  }
  return builder.takeBytes();
}

import 'package:flutter/material.dart';

class CalibrationOverlay extends StatefulWidget {
  const CalibrationOverlay({
    super.key,
    required this.onChanged,
    this.initialPoints,
  });

  /// Called whenever the points change.
  /// Points are normalized [0.0 - 1.0] relative to the widget size.
  final ValueChanged<List<Offset>> onChanged;

  /// Initial optional normalized points.
  final List<Offset>? initialPoints;

  @override
  State<CalibrationOverlay> createState() => _CalibrationOverlayState();
}

class _CalibrationOverlayState extends State<CalibrationOverlay> {
  // 4 corners: TL, TR, BR, BL
  late List<Offset> _points;
  late Size _lastSize;

  @override
  void initState() {
    super.initState();
    _points = widget.initialPoints ??
        [
          const Offset(0.2, 0.2), // TL
          const Offset(0.8, 0.2), // TR
          const Offset(0.8, 0.8), // BR
          const Offset(0.2, 0.8), // BL
        ];
    _lastSize = Size.zero;
  }

  void _updatePoint(int index, Offset newOffset, Size size) {
    // clamp to 0..1
    final dx = newOffset.dx.clamp(0.0, size.width) / size.width;
    final dy = newOffset.dy.clamp(0.0, size.height) / size.height;
    
    setState(() {
      _points[index] = Offset(dx, dy);
    });
    widget.onChanged(_points);
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = Size(constraints.maxWidth, constraints.maxHeight);
        _lastSize = size;
        
        return Stack(
          fit: StackFit.expand,
          children: [
            CustomPaint(
              painter: _CalibrationPainter(_points),
            ),
            // Draggable handles
            for (int i = 0; i < 4; i++)
              Positioned(
                left: _points[i].dx * size.width - 24,
                top: _points[i].dy * size.height - 24,
                child: GestureDetector(
                  onPanUpdate: (details) {
                    final currentPixel = Offset(
                      _points[i].dx * size.width,
                      _points[i].dy * size.height,
                    );
                    _updatePoint(i, currentPixel + details.delta, size);
                  },
                  child: Container(
                    width: 48,
                    height: 48,
                    decoration: BoxDecoration(
                      color: Colors.blue.withOpacity(0.3),
                      shape: BoxShape.circle,
                      border: Border.all(color: Colors.white, width: 2),
                    ),
                    child: Center(
                      child: Container(
                        width: 8,
                        height: 8,
                        decoration: const BoxDecoration(
                          color: Colors.blue,
                          shape: BoxShape.circle,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

class _CalibrationPainter extends CustomPainter {
  _CalibrationPainter(this.points);

  final List<Offset> points;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.greenAccent
      ..strokeWidth = 2.0
      ..style = PaintingStyle.stroke;

    final path = Path();
    final pixelPoints = points.map((p) => Offset(p.dx * size.width, p.dy * size.height)).toList();
    
    if (pixelPoints.isNotEmpty) {
      path.moveTo(pixelPoints[0].dx, pixelPoints[0].dy);
      for (int i = 1; i < pixelPoints.length; i++) {
        path.lineTo(pixelPoints[i].dx, pixelPoints[i].dy);
      }
      path.close();
    }

    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) {
    return true;
  }
}

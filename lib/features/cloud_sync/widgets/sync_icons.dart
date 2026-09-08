import 'package:flutter/material.dart';

class DropboxIcon extends StatelessWidget {
  final double size;
  final Color? color;
  const DropboxIcon({super.key, this.size = 22, this.color});

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      size: Size(size, size),
      painter: _DropboxIconPainter(color ?? Colors.white),
    );
  }
}

class _DropboxIconPainter extends CustomPainter {
  final Color color;
  _DropboxIconPainter(this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.fill;
    final scaleX = size.width / 24.0;
    final scaleY = size.height / 24.0;

    void drawPath(List<Offset> points) {
      final path = Path();
      path.moveTo(points[0].dx * scaleX, points[0].dy * scaleY);
      for (var i = 1; i < points.length; i++) {
        path.lineTo(points[i].dx * scaleX, points[i].dy * scaleY);
      }
      path.close();
      canvas.drawPath(path, paint);
    }

    drawPath([
      const Offset(6.5, 2),
      const Offset(2, 5),
      const Offset(6.5, 8),
      const Offset(11, 5),
    ]);
    drawPath([
      const Offset(17.5, 2),
      const Offset(13, 5),
      const Offset(17.5, 8),
      const Offset(22, 5),
    ]);
    drawPath([
      const Offset(6.5, 8),
      const Offset(2, 11),
      const Offset(6.5, 14),
      const Offset(11, 11),
    ]);
    drawPath([
      const Offset(17.5, 8),
      const Offset(13, 11),
      const Offset(17.5, 14),
      const Offset(22, 11),
    ]);
    drawPath([
      const Offset(12, 14),
      const Offset(7.5, 17),
      const Offset(12, 20),
      const Offset(16.5, 17),
    ]);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class GDriveIcon extends StatelessWidget {
  final double size;
  final Color? color;
  const GDriveIcon({super.key, this.size = 22, this.color});

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      size: Size(size, size),
      painter: _GDriveIconPainter(color ?? Colors.white),
    );
  }
}

class _GDriveIconPainter extends CustomPainter {
  final Color color;
  _GDriveIconPainter(this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.fill;
    final scaleX = size.width / 24.0;
    final scaleY = size.height / 24.0;

    final path = Path()
      ..moveTo(7.71 * scaleX, 3.5 * scaleY)
      ..lineTo(16.29 * scaleX, 3.5 * scaleY)
      ..lineTo(22.85 * scaleX, 15.0 * scaleY)
      ..lineTo(18.27 * scaleX, 22.5 * scaleY)
      ..lineTo(5.73 * scaleX, 22.5 * scaleY)
      ..lineTo(1.15 * scaleX, 15.0 * scaleY)
      ..close();
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class PulsingDot extends StatefulWidget {
  final Color color;
  const PulsingDot({super.key, required this.color});

  @override
  State<PulsingDot> createState() => _PulsingDotState();
}

class _PulsingDotState extends State<PulsingDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 1),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: Tween<double>(begin: 0.3, end: 1.0).animate(_controller),
      child: Container(
        width: 10,
        height: 10,
        decoration: BoxDecoration(
          color: widget.color,
          shape: BoxShape.circle,
          boxShadow: [
            BoxShadow(
              color: widget.color.withValues(alpha: 0.4),
              blurRadius: 4,
              spreadRadius: 1,
            ),
          ],
        ),
      ),
    );
  }
}

// Marca de Radici dentro de la app: el dibujo de brand_mark_geometry.dart en
// crema sobre un círculo terracota (como el ícono de Android). Es un dibujo,
// no una imagen: se ve nítido en cualquier pantalla y en la web no carga nada
// (la CSP de /gestione/ no se entera).
import 'package:flutter/material.dart';
import 'package:radici/core/brand_mark_geometry.dart';

class RadiciMark extends StatelessWidget {
  const RadiciMark({super.key, this.size = 72});

  /// Diámetro en dp.
  final double size;

  @override
  Widget build(BuildContext context) {
    // Decorativa: el nombre de la marca va en texto al lado.
    return ExcludeSemantics(
      child: SizedBox.square(
        dimension: size,
        child: const CustomPaint(painter: _RadiciMarkPainter()),
      ),
    );
  }
}

class _RadiciMarkPainter extends CustomPainter {
  const _RadiciMarkPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final radius = size.shortestSide / 2;
    final center = size.center(Offset.zero);
    canvas.drawCircle(
      center,
      radius,
      Paint()..color = const Color(brandTerracotta),
    );

    final scale = radius * markScaleInBadge;
    Offset toCanvas(MarkPoint p) => center + Offset(p.x, p.y) * scale;

    for (final stroke in markStrokes) {
      final paint = Paint()
        ..color = const Color(brandCream)
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke.width * scale
        ..strokeCap = StrokeCap.round;
      final from = toCanvas(stroke.from);
      final to = toCanvas(stroke.to);
      if (stroke.bulge == 0) {
        canvas.drawLine(from, to, paint);
      } else {
        // Flecha positiva = a la derecha del recorrido = antihorario en
        // pantalla (y hacia abajo).
        final path = Path()
          ..moveTo(from.dx, from.dy)
          ..arcToPoint(
            to,
            radius: Radius.circular(
              arcRadius((to - from).distance, stroke.bulge.abs() * scale),
            ),
            clockwise: stroke.bulge < 0,
          );
        canvas.drawPath(path, paint);
      }
    }

    final fill = Paint()..color = const Color(brandCream);
    for (final leaf in markLeaves) {
      final base = toCanvas(leaf.base);
      final tip = toCanvas(leaf.tip);
      final arc = Radius.circular(
        arcRadius((tip - base).distance, leaf.width * scale / 2),
      );
      // Ida y vuelta con el mismo sentido: cada arco abomba hacia un lado.
      final path = Path()
        ..moveTo(base.dx, base.dy)
        ..arcToPoint(tip, radius: arc, clockwise: false)
        ..arcToPoint(base, radius: arc, clockwise: false)
        ..close();
      canvas.drawPath(path, fill);
    }
  }

  @override
  bool shouldRepaint(_RadiciMarkPainter oldDelegate) => false;
}

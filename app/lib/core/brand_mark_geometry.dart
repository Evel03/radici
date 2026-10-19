// Marca de Radici ("raíces"): un brote con dos hojas sobre la línea de tierra
// y raíces curvas debajo, en crema sobre terracota.
//
// Dart puro (sin Flutter): la usan la app (RadiciMark, core/brand_mark.dart)
// y el generador de íconos (tool/generate_icons.dart), así el dibujo está en
// un solo lugar.
//
// Coordenadas del dibujo: origen en el centro, y hacia abajo; todo entra en
// el círculo de radio 1. Quien lo dibuja elige a cuántos píxeles equivale 1.
// Solo hay segmentos, arcos y lentes definidos por puntos (sin ángulos): así
// se dibujan igual con la API de Flutter y con raíces cuadradas.

/// Terracota, el color de la marca (también la semilla del tema): fondo.
const int brandTerracotta = 0xFFC0583A;

/// Crema: el dibujo sobre la terracota.
const int brandCream = 0xFFFFF4E6;

/// Escala del dibujo dentro de la insignia redonda (fondo circular): radio
/// del dibujo / radio del círculo. La usan RadiciMark y el ícono de Android.
const double markScaleInBadge = 0.66;

final class MarkPoint {
  const MarkPoint(this.x, this.y);

  final double x;
  final double y;
}

/// Trazo con puntas redondeadas: recto, o un arco de circunferencia si
/// [bulge] no es 0.
final class MarkStroke {
  const MarkStroke(this.from, this.to, this.width, {this.bulge = 0});

  final MarkPoint from;
  final MarkPoint to;

  /// Grosor del trazo.
  final double width;

  /// Flecha del arco: cuánto se separa su punto medio de la recta
  /// from–to. Positiva hacia la derecha de quien va de from a to (con y hacia
  /// abajo, como en la pantalla); 0 es un trazo recto.
  final double bulge;
}

/// Hoja: lente entre [base] y [tip], formada por dos arcos de circunferencia
/// del mismo radio; [width] es su ancho máximo (en el medio).
final class MarkLeaf {
  const MarkLeaf(this.base, this.tip, this.width);

  final MarkPoint base;
  final MarkPoint tip;
  final double width;
}

/// Radio de un arco de circunferencia con cuerda de largo [chord] y flecha
/// [sagitta] (> 0).
double arcRadius(double chord, double sagitta) =>
    (chord * chord / 4 + sagitta * sagitta) / (2 * sagitta);

/// Línea de tierra, tallo y raíces.
const List<MarkStroke> markStrokes = [
  // Tierra.
  MarkStroke(MarkPoint(-0.52, 0.10), MarkPoint(0.52, 0.10), 0.13),
  // Tallo.
  MarkStroke(MarkPoint(0, 0.10), MarkPoint(0, -0.32), 0.13),
  // Raíz central y raíces laterales que salen hacia afuera y bajan.
  MarkStroke(MarkPoint(0, 0.10), MarkPoint(0.02, 0.80), 0.11, bulge: -0.04),
  MarkStroke(MarkPoint(0, 0.20), MarkPoint(-0.42, 0.72), 0.10, bulge: 0.09),
  MarkStroke(MarkPoint(0, 0.20), MarkPoint(0.44, 0.64), 0.10, bulge: -0.08),
];

/// Las dos hojas del brote, de distinto tamaño.
const List<MarkLeaf> markLeaves = [
  MarkLeaf(MarkPoint(0, -0.28), MarkPoint(-0.56, -0.68), 0.32),
  MarkLeaf(MarkPoint(0, -0.28), MarkPoint(0.56, -0.80), 0.36),
];

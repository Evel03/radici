// Contorno de una letra de una fuente TrueType (tablas cmap, loca y glyf), en
// Dart puro: los íconos dibujan la R de la marca con la misma fuente que usa
// la app (assets/fonts/Cinzel-Medium.ttf), sin copiar coordenadas a mano.
//
// Alcanza para glifos simples (contornos de cuadráticas) mapeados en una
// subtabla cmap de formato 4. Con cualquier otra cosa lanza FormatException.
import 'dart:typed_data';

/// Punto del contorno en unidades de la fuente (y hacia arriba).
final class GlyphPoint {
  const GlyphPoint(this.x, this.y);

  final double x;
  final double y;
}

/// Tramo de un contorno: recto si [control] es null; si no, una cuadrática.
final class GlyphSegment {
  const GlyphSegment(this.from, this.to, [this.control]);

  final GlyphPoint from;
  final GlyphPoint to;
  final GlyphPoint? control;

  /// Punto del tramo en t ∈ [0, 1].
  GlyphPoint at(double t) {
    final c = control;
    if (c == null) {
      return GlyphPoint(
        from.x + (to.x - from.x) * t,
        from.y + (to.y - from.y) * t,
      );
    }
    final a = (1 - t) * (1 - t);
    final b = 2 * (1 - t) * t;
    final d = t * t;
    return GlyphPoint(
      a * from.x + b * c.x + d * to.x,
      a * from.y + b * c.y + d * to.y,
    );
  }
}

/// Contornos cerrados de la letra [codePoint] de [font] (un .ttf).
List<List<GlyphSegment>> readGlyphContours(Uint8List font, int codePoint) {
  final data = ByteData.sublistView(font);
  final tables = <String, int>{};
  final numTables = data.getUint16(4);
  for (var i = 0; i < numTables; i++) {
    final record = 12 + 16 * i;
    tables[String.fromCharCodes(font, record, record + 4)] = data.getUint32(
      record + 8,
    );
  }
  int table(String tag) =>
      tables[tag] ?? (throw FormatException('La fuente no tiene tabla $tag'));

  final longOffsets = data.getInt16(table('head') + 50) == 1;
  final glyph = _glyphId(data, table('cmap'), codePoint);
  final loca = table('loca');
  final start = longOffsets
      ? data.getUint32(loca + 4 * glyph)
      : 2 * data.getUint16(loca + 2 * glyph);
  final end = longOffsets
      ? data.getUint32(loca + 4 * glyph + 4)
      : 2 * data.getUint16(loca + 2 * glyph + 2);
  if (end == start) return const [];

  var p = table('glyf') + start;
  final contourCount = data.getInt16(p);
  if (contourCount < 0) {
    throw const FormatException('Glifo compuesto: no soportado');
  }
  p += 10; // cantidad de contornos y caja
  final lastPoints = [
    for (var i = 0; i < contourCount; i++) data.getUint16(p + 2 * i),
  ];
  p += 2 * contourCount;
  p += 2 + data.getUint16(p); // instrucciones
  final pointCount = lastPoints.isEmpty ? 0 : lastPoints.last + 1;

  final flags = <int>[];
  while (flags.length < pointCount) {
    final flag = data.getUint8(p++);
    flags.add(flag);
    if (flag & 0x08 != 0) {
      for (var repeat = data.getUint8(p++); repeat > 0; repeat--) {
        flags.add(flag);
      }
    }
  }
  // Cada coordenada es la anterior más un delta: de un byte (con signo en la
  // marca), repetida (0) o de dos bytes con signo.
  List<double> coordinates(int shortBit, int sameOrPositiveBit) {
    final values = <double>[];
    var value = 0;
    for (var i = 0; i < pointCount; i++) {
      final flag = flags[i];
      if (flag & shortBit != 0) {
        final delta = data.getUint8(p++);
        value += flag & sameOrPositiveBit != 0 ? delta : -delta;
      } else if (flag & sameOrPositiveBit == 0) {
        value += data.getInt16(p);
        p += 2;
      }
      values.add(value.toDouble());
    }
    return values;
  }

  final xs = coordinates(0x02, 0x10);
  final ys = coordinates(0x04, 0x20);
  final contours = <List<GlyphSegment>>[];
  var first = 0;
  for (final last in lastPoints) {
    contours.add(
      _segments([
        for (var i = first; i <= last; i++)
          (GlyphPoint(xs[i], ys[i]), flags[i] & 0x01 != 0),
      ]),
    );
    first = last + 1;
  }
  return contours;
}

/// Tramos de un contorno de TrueType: entre dos puntos de control seguidos
/// hay uno sobre la curva implícito, en el medio.
List<GlyphSegment> _segments(List<(GlyphPoint, bool)> points) {
  if (points.length < 2) return const [];
  GlyphPoint mid(GlyphPoint a, GlyphPoint b) =>
      GlyphPoint((a.x + b.x) / 2, (a.y + b.y) / 2);
  // Empieza en un punto sobre la curva; si son todos de control, en el medio
  // de los dos primeros. Después recorre el resto y vuelve al comienzo.
  final startIndex = points.indexWhere((p) => p.$2);
  final GlyphPoint start;
  final List<(GlyphPoint, bool)> rest;
  if (startIndex >= 0) {
    start = points[startIndex].$1;
    rest = [
      ...points.sublist(startIndex + 1),
      ...points.sublist(0, startIndex),
    ];
  } else {
    start = mid(points[0].$1, points[1].$1);
    rest = [...points.sublist(1), points[0]];
  }
  final segments = <GlyphSegment>[];
  var current = start;
  GlyphPoint? control;
  for (final (point, onCurve) in [...rest, (start, true)]) {
    if (onCurve) {
      segments.add(GlyphSegment(current, point, control));
      current = point;
      control = null;
    } else if (control == null) {
      control = point;
    } else {
      final implied = mid(control, point);
      segments.add(GlyphSegment(current, implied, control));
      current = implied;
      control = point;
    }
  }
  return segments;
}

/// Glifo de [codePoint] según la subtabla cmap de formato 4 (Unicode BMP).
int _glyphId(ByteData data, int cmap, int codePoint) {
  final subtables = data.getUint16(cmap + 2);
  for (var i = 0; i < subtables; i++) {
    final record = cmap + 4 + 8 * i;
    final platform = data.getUint16(record);
    final encoding = data.getUint16(record + 2);
    final offset = cmap + data.getUint32(record + 4);
    final unicode = platform == 0 || (platform == 3 && encoding == 1);
    if (!unicode || data.getUint16(offset) != 4) continue;
    final segments = data.getUint16(offset + 6) ~/ 2;
    final ends = offset + 14;
    final starts = ends + 2 * segments + 2;
    final deltas = starts + 2 * segments;
    final rangeOffsets = deltas + 2 * segments;
    for (var s = 0; s < segments; s++) {
      if (codePoint > data.getUint16(ends + 2 * s)) continue;
      final startCode = data.getUint16(starts + 2 * s);
      if (codePoint < startCode) break;
      final delta = data.getInt16(deltas + 2 * s);
      final rangeOffset = data.getUint16(rangeOffsets + 2 * s);
      if (rangeOffset == 0) return (codePoint + delta) & 0xFFFF;
      final id = data.getUint16(
        rangeOffsets + 2 * s + rangeOffset + 2 * (codePoint - startCode),
      );
      return id == 0 ? 0 : (id + delta) & 0xFFFF;
    }
  }
  throw FormatException(
    'La fuente no tiene U+${codePoint.toRadixString(16).toUpperCase()}',
  );
}

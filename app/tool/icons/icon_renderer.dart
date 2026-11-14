// Íconos de Radici (web, Android e iOS): la R de Cinzel en crema sobre oliva,
// como el favicon de la web. La R sale de la misma fuente que usa la app
// (lib/core/brand.dart, leída con glyph_outline.dart), sin dependencias ni
// herramientas externas: se rasteriza con distancias con signo (antialias de
// un píxel) y se codifica PNG con el zlib de dart:io. El resultado es
// determinista: las mismas cuentas en cualquier máquina.
//
// Lo usan tool/generate_icons.dart (escribe los archivos) y
// test/tool/app_icons_test.dart (verifica que los del repo estén al día).
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:radici/core/brand.dart';

import 'glyph_outline.dart';

/// Forma del fondo oliva.
enum IconBackground {
  /// Cuadrado entero y opaco: el sistema recorta la forma (iOS, PWA).
  square,

  /// Cuadrado con esquinas redondeadas y transparentes (favicon).
  roundedSquare,

  /// Círculo con transparencia alrededor (ícono clásico de Android).
  circle,
}

final class IconSpec {
  const IconSpec(
    this.path,
    this.size,
    this.background,
    this.markScale, {
    this.emboldenPx = 0,
  });

  /// Ruta del PNG desde app/, con "/".
  final String path;

  /// Lado en píxeles.
  final int size;

  final IconBackground background;

  /// Media altura de la R como fracción del lado (la caja de la R va
  /// centrada).
  final double markScale;

  /// Cuánto se engrosa la R, en píxeles por lado: en tamaños chicos los trazos
  /// finos de Cinzel quedarían de menos de un píxel (el favicon de la web hace
  /// lo mismo con un trazo de 0,7 en 32 px).
  final double emboldenPx;

  /// Opaco (RGB) o con transparencia (RGBA).
  bool get opaque => background == IconBackground.square;
}

/// Radio del círculo del ícono clásico de Android como fracción del lado
/// (guía de íconos redondos: 44 dp de 48).
const double androidCircleRadius = 22 / 48;

/// Todos los íconos de la app. Los nombres y tamaños son los de la plantilla
/// de Flutter, así no cambia nada en los proyectos nativos (ni manifest.json).
/// La R mide 0,95 de ancho por 1 de alto: con media altura h, su caja llega
/// hasta 1,38·h del centro (la zona segura de los "maskable" es 0,4).
final List<IconSpec> appIcons = [
  // Web (/gestione/). Icon-192 también es el apple-touch-icon de index.html:
  // por eso los "any" son opacos (iOS pinta de negro la transparencia).
  // El favicon, con las medidas del de la web (la R de 21 px en 32).
  const IconSpec(
    'web/favicon.png',
    32,
    IconBackground.roundedSquare,
    0.33,
    emboldenPx: 0.35,
  ),
  const IconSpec('web/icons/Icon-192.png', 192, IconBackground.square, 0.31),
  const IconSpec('web/icons/Icon-512.png', 512, IconBackground.square, 0.31),
  // Maskable: la R entera dentro de la zona segura.
  const IconSpec(
    'web/icons/Icon-maskable-192.png',
    192,
    IconBackground.square,
    0.26,
  ),
  const IconSpec(
    'web/icons/Icon-maskable-512.png',
    512,
    IconBackground.square,
    0.26,
  ),
  // Android: ícono clásico por densidad (sin ícono adaptativo).
  for (final (density, size) in const [
    ('mdpi', 48),
    ('hdpi', 72),
    ('xhdpi', 96),
    ('xxhdpi', 144),
    ('xxxhdpi', 192),
  ])
    IconSpec(
      'android/app/src/main/res/mipmap-$density/ic_launcher.png',
      size,
      IconBackground.circle,
      0.27,
      emboldenPx: 0.25,
    ),
  // iOS: opacos y a sangre (iOS redondea las esquinas). El de 1024 es el de
  // la App Store, que no admite transparencia.
  for (final (name, size) in const [
    ('20x20@1x', 20),
    ('20x20@2x', 40),
    ('20x20@3x', 60),
    ('29x29@1x', 29),
    ('29x29@2x', 58),
    ('29x29@3x', 87),
    ('40x40@1x', 40),
    ('40x40@2x', 80),
    ('40x40@3x', 120),
    ('60x60@2x', 120),
    ('60x60@3x', 180),
    ('76x76@1x', 76),
    ('76x76@2x', 152),
    ('83.5x83.5@2x', 167),
    ('1024x1024@1x', 1024),
  ])
    IconSpec(
      'ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-$name.png',
      size,
      IconBackground.square,
      0.30,
      emboldenPx: 0.25,
    ),
];

typedef Bounds = ({double minX, double minY, double maxX, double maxY});

/// La R de la marca: contornos de la fuente, en sus unidades (y hacia arriba).
/// En Cinzel son contornos que se superponen (el arco con la pierna, el asta y
/// las serifas), sin huecos: la R es la unión.
final class MarkOutline {
  MarkOutline(this.contours) : bounds = _boundsOf(contours);

  factory MarkOutline.fromFont(Uint8List font) =>
      MarkOutline(readGlyphContours(font, brandMarkCodePoint));

  /// Lee la fuente de la marca ([path] desde app/).
  factory MarkOutline.load([String path = brandMarkFontAsset]) =>
      MarkOutline.fromFont(File(path).readAsBytesSync());

  final List<List<GlyphSegment>> contours;

  /// Caja exacta de la letra (incluye los extremos de las curvas).
  final Bounds bounds;
}

Bounds _boundsOf(List<List<GlyphSegment>> contours) {
  var minX = double.infinity;
  var minY = double.infinity;
  var maxX = double.negativeInfinity;
  var maxY = double.negativeInfinity;
  void include(GlyphPoint p) {
    minX = math.min(minX, p.x);
    minY = math.min(minY, p.y);
    maxX = math.max(maxX, p.x);
    maxY = math.max(maxY, p.y);
  }

  for (final contour in contours) {
    for (final segment in contour) {
      include(segment.from);
      include(segment.to);
      final c = segment.control;
      if (c == null) continue;
      // Extremos de la cuadrática en cada eje: t = (p0 − c) / (p0 − 2c + p1).
      for (final (p0, p1, pc) in [
        (segment.from.x, segment.to.x, c.x),
        (segment.from.y, segment.to.y, c.y),
      ]) {
        final denominator = p0 - 2 * pc + p1;
        if (denominator == 0) continue;
        final t = (p0 - pc) / denominator;
        if (t > 0 && t < 1) include(segment.at(t));
      }
    }
  }
  return (minX: minX, minY: minY, maxX: maxX, maxY: maxY);
}

/// Píxeles de [spec], fila por fila: RGB si es opaco, RGBA si no.
Uint8List renderIcon(IconSpec spec, MarkOutline mark) {
  final size = spec.size;
  final channels = spec.opaque ? 3 : 4;
  final pixels = Uint8List(size * size * channels);
  final center = size / 2;

  // De unidades de la fuente (y hacia arriba) a píxeles (y hacia abajo), con
  // la caja de la R centrada. Una transformación afín no cambia las curvas:
  // alcanza con transformar sus puntos.
  final b = mark.bounds;
  final scale = spec.markScale * size / ((b.maxY - b.minY) / 2);
  final midX = (b.minX + b.maxX) / 2;
  final midY = (b.minY + b.maxY) / 2;
  GlyphPoint toPx(GlyphPoint p) =>
      GlyphPoint(center + (p.x - midX) * scale, center - (p.y - midY) * scale);
  // Primero los contornos chicos (el asta es un rectángulo): si uno ya cubre
  // el píxel entero, no hace falta mirar el resto.
  final shapes = [
    for (final contour in mark.contours) _Polygon(_flatten(contour, toPx)),
  ]..sort((a, b) => a.points.length.compareTo(b.points.length));
  final outline = _unionOutline(shapes);

  final background = switch (spec.background) {
    IconBackground.square => (double x, double y) => -double.infinity,
    IconBackground.roundedSquare => (
      double x,
      double y,
    ) => _roundedSquareDistance(x, y, size.toDouble(), size * 0.22),
    IconBackground.circle => (
      double x,
      double y,
    ) => _length(x - center, y - center) - androidCircleRadius * size,
  };

  // Con la R engrosada, el píxel queda cubierto del todo desde una distancia
  // de (engrosado − 0,5) hacia adentro y nada desde (engrosado + 0,5) hacia
  // afuera.
  final full = spec.emboldenPx - 0.5;
  final reach = spec.emboldenPx + 1;
  final cream = _rgb(brandCream);
  final olive = _rgb(brandOlive);
  var i = 0;
  for (var row = 0; row < size; row++) {
    final y = row + 0.5;
    for (var column = 0; column < size; column++) {
      final x = column + 0.5;
      final backgroundCoverage = _coverage(background(x, y));
      var distance = double.infinity;
      for (final shape in shapes) {
        distance = math.min(distance, shape.distance(x, y, reach));
        if (distance <= full) break;
      }
      // Afuera, el mínimo por contorno es la distancia a la unión. Adentro solo
      // acota la profundidad: cerca de un borde interno (las serifas pisan el
      // asta apenas 3 unidades) quedaría una línea más oscura. Ahí se mide
      // hasta el contorno de la unión.
      if (distance > full && distance < 0) {
        distance = -_distanceToOutline(outline, x, y);
      }
      // La R nunca sale del fondo.
      final markCoverage = math.min(
        _coverage(distance - spec.emboldenPx),
        backgroundCoverage,
      );
      // Crema sobre oliva (alfa premultiplicado y después sin premultiplicar).
      final alpha = markCoverage + backgroundCoverage * (1 - markCoverage);
      for (var c = 0; c < 3; c++) {
        final premultiplied =
            cream[c] * markCoverage +
            olive[c] * backgroundCoverage * (1 - markCoverage);
        pixels[i++] = alpha == 0 ? 0 : (premultiplied / alpha).round();
      }
      if (channels == 4) pixels[i++] = (alpha * 255).round();
    }
  }
  return pixels;
}

/// El PNG de [spec].
Uint8List encodeIcon(IconSpec spec, MarkOutline mark) => encodePng(
  width: spec.size,
  height: spec.size,
  channels: spec.opaque ? 3 : 4,
  pixels: renderIcon(spec, mark),
);

/// Polígono que aproxima [contour], ya en píxeles, con un error menor a
/// 0,1 px: cada cuadrática en n tramos, con n según su flecha.
List<GlyphPoint> _flatten(
  List<GlyphSegment> contour,
  GlyphPoint Function(GlyphPoint) toPx,
) {
  final points = <GlyphPoint>[];
  for (final segment in contour) {
    final from = toPx(segment.from);
    final to = toPx(segment.to);
    final c = segment.control;
    if (c == null) {
      points.add(to);
      continue;
    }
    final control = toPx(c);
    // Flecha: |from − 2·control + to| / 4; con n tramos el error es flecha / n².
    final sagitta =
        _length(from.x - 2 * control.x + to.x, from.y - 2 * control.y + to.y) /
        4;
    final n = math.max(1, math.sqrt(sagitta / 0.1).ceil());
    final curve = GlyphSegment(from, to, control);
    for (var k = 1; k <= n; k++) {
      points.add(curve.at(k / n));
    }
  }
  return points;
}

/// Cuánto cubre la figura al píxel según la distancia de su centro al borde
/// (negativa adentro): rampa lineal de un píxel.
double _coverage(double distance) => (0.5 - distance).clamp(0.0, 1.0);

double _length(double x, double y) => math.sqrt(x * x + y * y);

/// Distancia con signo al cuadrado [0, side]² con esquinas de radio [radius].
double _roundedSquareDistance(double x, double y, double side, double radius) {
  final half = side / 2;
  final qx = (x - half).abs() - (half - radius);
  final qy = (y - half).abs() - (half - radius);
  final outside = _length(math.max(qx, 0), math.max(qy, 0));
  final inside = math.min(math.max(qx, qy), 0.0);
  return outside + inside - radius;
}

List<int> _rgb(int argb) => [
  (argb >> 16) & 0xFF,
  (argb >> 8) & 0xFF,
  argb & 0xFF,
];

/// Tramo recto del contorno de la unión.
typedef _Piece = ({GlyphPoint a, GlyphPoint b});

/// Contorno de la unión de [shapes]: cada borde se corta donde cruza los de
/// los otros contornos y quedan los tramos que no están estrictamente adentro
/// de otro (los compartidos o alineados quedan).
List<_Piece> _unionOutline(List<_Polygon> shapes) {
  final pieces = <_Piece>[];
  for (var i = 0; i < shapes.length; i++) {
    final points = shapes[i].points;
    var a = points.last;
    for (final b in points) {
      final rx = b.x - a.x;
      final ry = b.y - a.y;
      final cuts = <double>[0, 1];
      for (var j = 0; j < shapes.length; j++) {
        if (j == i) continue;
        final other = shapes[j].points;
        var c = other.last;
        for (final d in other) {
          final sx = d.x - c.x;
          final sy = d.y - c.y;
          final denominator = rx * sy - ry * sx;
          if (denominator != 0) {
            final qx = c.x - a.x;
            final qy = c.y - a.y;
            final t = (qx * sy - qy * sx) / denominator;
            final u = (qx * ry - qy * rx) / denominator;
            if (t > 0 && t < 1 && u >= 0 && u <= 1) cuts.add(t);
          }
          c = d;
        }
      }
      cuts.sort();
      for (var k = 0; k + 1 < cuts.length; k++) {
        if (cuts[k + 1] - cuts[k] < 1e-12) continue;
        final from = GlyphPoint(a.x + rx * cuts[k], a.y + ry * cuts[k]);
        final to = GlyphPoint(a.x + rx * cuts[k + 1], a.y + ry * cuts[k + 1]);
        final midX = (from.x + to.x) / 2;
        final midY = (from.y + to.y) / 2;
        var inside = false;
        for (var j = 0; j < shapes.length && !inside; j++) {
          inside = j != i && shapes[j].distance(midX, midY, 0) < -1e-9;
        }
        if (!inside) pieces.add((a: from, b: to));
      }
      a = b;
    }
  }
  return pieces;
}

/// Distancia desde (x, y) al tramo más cercano de [outline].
double _distanceToOutline(List<_Piece> outline, double x, double y) {
  var nearest = double.infinity; // al cuadrado
  for (final (:a, :b) in outline) {
    final abx = b.x - a.x;
    final aby = b.y - a.y;
    final lengthSquared = abx * abx + aby * aby;
    final t = lengthSquared == 0
        ? 0.0
        : (((x - a.x) * abx + (y - a.y) * aby) / lengthSquared).clamp(0.0, 1.0);
    final dx = x - (a.x + t * abx);
    final dy = y - (a.y + t * aby);
    nearest = math.min(nearest, dx * dx + dy * dy);
  }
  return math.sqrt(nearest);
}

/// Contorno cerrado (polígono simple) con su caja.
final class _Polygon {
  _Polygon(this.points)
    : minX = points.map((p) => p.x).reduce(math.min),
      minY = points.map((p) => p.y).reduce(math.min),
      maxX = points.map((p) => p.x).reduce(math.max),
      maxY = points.map((p) => p.y).reduce(math.max);

  final List<GlyphPoint> points;
  final double minX;
  final double minY;
  final double maxX;
  final double maxY;

  /// Distancia con signo desde (x, y) al borde (negativa adentro). A más de
  /// [reach] de la caja devuelve infinito: el contorno no toca ese píxel.
  double distance(double x, double y, double reach) {
    if (x < minX - reach ||
        x > maxX + reach ||
        y < minY - reach ||
        y > maxY + reach) {
      return double.infinity;
    }
    var nearest = double.infinity; // al cuadrado
    var inside = false;
    var a = points.last;
    for (final b in points) {
      final abx = b.x - a.x;
      final aby = b.y - a.y;
      final lengthSquared = abx * abx + aby * aby;
      final t = lengthSquared == 0
          ? 0.0
          : (((x - a.x) * abx + (y - a.y) * aby) / lengthSquared).clamp(
              0.0,
              1.0,
            );
      final dx = x - (a.x + t * abx);
      final dy = y - (a.y + t * aby);
      nearest = math.min(nearest, dx * dx + dy * dy);
      // Regla par-impar con un rayo hacia la derecha.
      if ((a.y > y) != (b.y > y) && x < a.x + (y - a.y) * abx / aby) {
        inside = !inside;
      }
      a = b;
    }
    final d = math.sqrt(nearest);
    return inside ? -d : d;
  }
}

// ---------------------------------------------------------------------------
// PNG (8 bits por canal, RGB o RGBA, sin entrelazado)
// ---------------------------------------------------------------------------

const List<int> _pngSignature = [137, 80, 78, 71, 13, 10, 26, 10];

/// Codifica [pixels] (filas de [width] × [channels] bytes). Filas sin
/// filtro: los íconos son de colores planos y zlib los comprime bien igual.
Uint8List encodePng({
  required int width,
  required int height,
  required int channels,
  required Uint8List pixels,
}) {
  assert(channels == 3 || channels == 4);
  final rowLength = width * channels;
  final raw = BytesBuilder(copy: false);
  for (var row = 0; row < height; row++) {
    raw
      ..addByte(0)
      ..add(
        Uint8List.sublistView(pixels, row * rowLength, (row + 1) * rowLength),
      );
  }
  final header = ByteData(13)
    ..setUint32(0, width)
    ..setUint32(4, height)
    ..setUint8(8, 8) // bits por canal
    ..setUint8(9, channels == 4 ? 6 : 2) // RGBA o RGB
    ..setUint8(10, 0) // compresión
    ..setUint8(11, 0) // filtro
    ..setUint8(12, 0); // sin entrelazado
  final png = BytesBuilder(copy: false)..add(_pngSignature);
  _writeChunk(png, 'IHDR', header.buffer.asUint8List());
  _writeChunk(png, 'IDAT', ZLibEncoder(level: 9).convert(raw.takeBytes()));
  _writeChunk(png, 'IEND', const []);
  return png.takeBytes();
}

void _writeChunk(BytesBuilder png, String type, List<int> data) {
  final typeBytes = type.codeUnits;
  final length = ByteData(4)..setUint32(0, data.length);
  final crc = ByteData(4)..setUint32(0, _crc32([...typeBytes, ...data]));
  png
    ..add(length.buffer.asUint8List())
    ..add(typeBytes)
    ..add(data)
    ..add(crc.buffer.asUint8List());
}

final List<int> _crcTable = List<int>.generate(256, (n) {
  var c = n;
  for (var k = 0; k < 8; k++) {
    c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1;
  }
  return c;
});

int _crc32(List<int> bytes) {
  var crc = 0xFFFFFFFF;
  for (final byte in bytes) {
    crc = _crcTable[(crc ^ byte) & 0xFF] ^ (crc >> 8);
  }
  return crc ^ 0xFFFFFFFF;
}

/// PNG decodificado: [channels] es 3 (RGB) o 4 (RGBA).
typedef DecodedPng = ({int width, int height, int channels, Uint8List pixels});

/// Decodifica un PNG de 8 bits RGB o RGBA sin entrelazado, con cualquiera de
/// los cinco filtros de fila (por si alguien lo pasa por un optimizador).
/// Lanza [FormatException] con cualquier otra cosa.
DecodedPng decodePng(Uint8List bytes) {
  for (var i = 0; i < _pngSignature.length; i++) {
    if (bytes.length <= i || bytes[i] != _pngSignature[i]) {
      throw const FormatException('No es un PNG');
    }
  }
  final data = ByteData.sublistView(bytes);
  var offset = _pngSignature.length;
  int? width;
  int? height;
  int? channels;
  final compressed = BytesBuilder(copy: false);
  while (offset + 8 <= bytes.length) {
    final length = data.getUint32(offset);
    final type = String.fromCharCodes(bytes, offset + 4, offset + 8);
    final body = Uint8List.sublistView(bytes, offset + 8, offset + 8 + length);
    offset += 12 + length;
    switch (type) {
      case 'IHDR':
        final header = ByteData.sublistView(body);
        width = header.getUint32(0);
        height = header.getUint32(4);
        final bitDepth = header.getUint8(8);
        final colorType = header.getUint8(9);
        final interlace = header.getUint8(12);
        if (bitDepth != 8 ||
            interlace != 0 ||
            (colorType != 2 && colorType != 6)) {
          throw FormatException(
            'PNG no soportado (bits $bitDepth, color $colorType, entrelazado $interlace)',
          );
        }
        channels = colorType == 6 ? 4 : 3;
      case 'IDAT':
        compressed.add(body);
      case 'IEND':
        break;
    }
  }
  if (width == null || height == null || channels == null) {
    throw const FormatException('PNG sin IHDR');
  }
  final raw = Uint8List.fromList(ZLibDecoder().convert(compressed.takeBytes()));
  final rowLength = width * channels;
  if (raw.length != height * (rowLength + 1)) {
    throw const FormatException('Largo de los datos del PNG inesperado');
  }
  final pixels = Uint8List(height * rowLength);
  for (var row = 0; row < height; row++) {
    final filter = raw[row * (rowLength + 1)];
    final source = row * (rowLength + 1) + 1;
    final target = row * rowLength;
    for (var i = 0; i < rowLength; i++) {
      final left = i >= channels ? pixels[target + i - channels] : 0;
      final up = row > 0 ? pixels[target - rowLength + i] : 0;
      final upLeft = row > 0 && i >= channels
          ? pixels[target - rowLength + i - channels]
          : 0;
      final predictor = switch (filter) {
        0 => 0,
        1 => left,
        2 => up,
        3 => (left + up) >> 1,
        4 => _paeth(left, up, upLeft),
        _ => throw FormatException('Filtro de fila desconocido: $filter'),
      };
      pixels[target + i] = (raw[source + i] + predictor) & 0xFF;
    }
  }
  return (width: width, height: height, channels: channels, pixels: pixels);
}

int _paeth(int a, int b, int c) {
  final p = a + b - c;
  final pa = (p - a).abs();
  final pb = (p - b).abs();
  final pc = (p - c).abs();
  if (pa <= pb && pa <= pc) return a;
  return pb <= pc ? b : c;
}

// Íconos de Radici (web, Android e iOS) dibujados a partir de la marca
// (lib/core/brand_mark_geometry.dart), sin dependencias ni herramientas
// externas: se rasteriza con distancias con signo (antialias de un píxel) y
// se codifica PNG con el zlib de dart:io. El resultado es determinista: las
// mismas cuentas en cualquier máquina.
//
// Lo usan tool/generate_icons.dart (escribe los archivos) y
// test/tool/app_icons_test.dart (verifica que los del repo estén al día).
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:radici/core/brand_mark_geometry.dart';

/// Forma del fondo terracota.
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
    this.minStrokePx = 0,
  });

  /// Ruta del PNG desde app/, con "/".
  final String path;

  /// Lado en píxeles.
  final int size;

  final IconBackground background;

  /// Radio del dibujo como fracción del lado.
  final double markScale;

  /// Grosor mínimo de los trazos, en píxeles: en tamaños chicos un trazo
  /// proporcional quedaría de menos de un píxel.
  final double minStrokePx;

  /// Opaco (RGB) o con transparencia (RGBA).
  bool get opaque => background == IconBackground.square;
}

/// Radio del círculo del ícono clásico de Android como fracción del lado
/// (guía de íconos redondos: 44 dp de 48).
const double androidCircleRadius = 22 / 48;

/// Todos los íconos de la app. Los nombres y tamaños son los de la plantilla
/// de Flutter, así no cambia nada en los proyectos nativos (ni manifest.json).
final List<IconSpec> appIcons = [
  // Web (/gestione/). Icon-192 también es el apple-touch-icon de index.html:
  // por eso los "any" son opacos (iOS pinta de negro la transparencia).
  const IconSpec(
    'web/favicon.png',
    32,
    IconBackground.roundedSquare,
    0.42,
    minStrokePx: 2,
  ),
  const IconSpec('web/icons/Icon-192.png', 192, IconBackground.square, 0.40),
  const IconSpec('web/icons/Icon-512.png', 512, IconBackground.square, 0.40),
  // Maskable: el dibujo dentro de la zona segura (círculo de radio 0,4).
  const IconSpec(
    'web/icons/Icon-maskable-192.png',
    192,
    IconBackground.square,
    0.33,
  ),
  const IconSpec(
    'web/icons/Icon-maskable-512.png',
    512,
    IconBackground.square,
    0.33,
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
      androidCircleRadius * markScaleInBadge,
      minStrokePx: 1.5,
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
      0.38,
      minStrokePx: 1.5,
    ),
];

/// Píxeles de [spec], fila por fila: RGB si es opaco, RGBA si no.
Uint8List renderIcon(IconSpec spec) {
  final size = spec.size;
  final channels = spec.opaque ? 3 : 4;
  final pixels = Uint8List(size * size * channels);
  final center = size / 2;
  final scale = spec.markScale * size;
  MarkPoint toPx(MarkPoint p) =>
      MarkPoint(center + p.x * scale, center + p.y * scale);

  final shapes = <_Shape>[
    for (final stroke in markStrokes)
      if (stroke.bulge == 0)
        _Capsule(
          toPx(stroke.from),
          toPx(stroke.to),
          math.max(stroke.width * scale, spec.minStrokePx) / 2,
        )
      else
        _ArcStroke(
          toPx(stroke.from),
          toPx(stroke.to),
          stroke.bulge * scale,
          math.max(stroke.width * scale, spec.minStrokePx) / 2,
        ),
    for (final leaf in markLeaves)
      _Lens(toPx(leaf.base), toPx(leaf.tip), leaf.width * scale / 2),
  ];
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

  final cream = _rgb(brandCream);
  final terracotta = _rgb(brandTerracotta);
  var i = 0;
  for (var row = 0; row < size; row++) {
    final y = row + 0.5;
    for (var column = 0; column < size; column++) {
      final x = column + 0.5;
      final backgroundCoverage = _coverage(background(x, y));
      var distance = double.infinity;
      for (final shape in shapes) {
        distance = math.min(distance, shape.distance(x, y));
      }
      // El dibujo nunca sale del fondo.
      final markCoverage = math.min(_coverage(distance), backgroundCoverage);
      // Crema sobre terracota (alfa premultiplicado y después sin premultiplicar).
      final alpha = markCoverage + backgroundCoverage * (1 - markCoverage);
      for (var c = 0; c < 3; c++) {
        final premultiplied =
            cream[c] * markCoverage +
            terracotta[c] * backgroundCoverage * (1 - markCoverage);
        pixels[i++] = alpha == 0 ? 0 : (premultiplied / alpha).round();
      }
      if (channels == 4) pixels[i++] = (alpha * 255).round();
    }
  }
  return pixels;
}

/// El PNG de [spec].
Uint8List encodeIcon(IconSpec spec) => encodePng(
  width: spec.size,
  height: spec.size,
  channels: spec.opaque ? 3 : 4,
  pixels: renderIcon(spec),
);

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

sealed class _Shape {
  /// Distancia con signo desde (x, y) al borde (negativa adentro).
  double distance(double x, double y);
}

/// Segmento con puntas redondeadas.
final class _Capsule extends _Shape {
  _Capsule(this.a, this.b, this.radius);

  final MarkPoint a;
  final MarkPoint b;
  final double radius;

  @override
  double distance(double x, double y) {
    final abx = b.x - a.x;
    final aby = b.y - a.y;
    final lengthSquared = abx * abx + aby * aby;
    final t = lengthSquared == 0
        ? 0.0
        : (((x - a.x) * abx + (y - a.y) * aby) / lengthSquared).clamp(0.0, 1.0);
    return _length(x - (a.x + t * abx), y - (a.y + t * aby)) - radius;
  }
}

/// Arco de circunferencia de [a] a [b] con puntas redondeadas. [bulge] es la
/// flecha: positiva hacia la derecha de quien va de a a b (y hacia abajo).
final class _ArcStroke extends _Shape {
  _ArcStroke(this.a, this.b, double bulge, this.halfWidth) {
    final dx = b.x - a.x;
    final dy = b.y - a.y;
    final chord = _length(dx, dy);
    // Normal unitaria a la derecha de quien va de a a b.
    nx = -dy / chord;
    ny = dx / chord;
    side = bulge.sign;
    final sagitta = bulge.abs();
    radius = arcRadius(chord, sagitta);
    // El centro queda del otro lado del punto medio del arco.
    final toCenter = side * (sagitta - radius);
    cx = (a.x + b.x) / 2 + nx * toCenter;
    cy = (a.y + b.y) / 2 + ny * toCenter;
  }

  final MarkPoint a;
  final MarkPoint b;
  final double halfWidth;
  late final double nx;
  late final double ny;
  late final double side;
  late final double radius;
  late final double cx;
  late final double cy;

  @override
  double distance(double x, double y) {
    final px = x - cx;
    final py = y - cy;
    final r = _length(px, py);
    if (r > 0) {
      // El punto de la circunferencia en la dirección de (x, y): si cae del
      // lado del arco respecto de la cuerda, la distancia es al arco.
      final qx = cx + px * radius / r;
      final qy = cy + py * radius / r;
      if (((qx - a.x) * nx + (qy - a.y) * ny) * side >= 0) {
        return (r - radius).abs() - halfWidth;
      }
    }
    // Si no, a la punta más cercana.
    return math.min(_length(x - a.x, y - a.y), _length(x - b.x, y - b.y)) -
        halfWidth;
  }
}

/// Lente entre [base] y [tip]: intersección de dos círculos iguales cuyos
/// bordes pasan por los dos puntos; [halfWidth] es la mitad del ancho máximo.
final class _Lens extends _Shape {
  _Lens(MarkPoint base, MarkPoint tip, double halfWidth) {
    final dx = tip.x - base.x;
    final dy = tip.y - base.y;
    final chord = _length(dx, dy);
    radius = arcRadius(chord, halfWidth);
    final offset = radius - halfWidth;
    final midX = (base.x + tip.x) / 2;
    final midY = (base.y + tip.y) / 2;
    // Normal unitaria a la cuerda.
    final nx = -dy / chord;
    final ny = dx / chord;
    c1x = midX + nx * offset;
    c1y = midY + ny * offset;
    c2x = midX - nx * offset;
    c2y = midY - ny * offset;
  }

  late final double radius;
  late final double c1x;
  late final double c1y;
  late final double c2x;
  late final double c2y;

  @override
  double distance(double x, double y) => math.max(
    _length(x - c1x, y - c1y) - radius,
    _length(x - c2x, y - c2y) - radius,
  );
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

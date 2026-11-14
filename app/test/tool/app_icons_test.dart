// Los íconos del repo (web, Android, iOS) son exactamente los que dibuja
// tool/generate_icons.dart con la marca (la R de Cinzel de la fuente de la
// app), y no queda ninguno de la plantilla de Flutter. Si se cambia la marca,
// la fuente o la lista:
//   cd app && dart run tool/generate_icons.dart
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:radici/core/brand.dart';

import '../../tool/icons/glyph_outline.dart';
import '../../tool/icons/icon_renderer.dart';
import '../support/repo_files.dart';

const String _regenerate =
    'Regenerar con: cd app && dart run tool/generate_icons.dart';

File _appFile(String path) => findRepoFile('app/$path');

void main() {
  final mark = MarkOutline.fromFont(
    _appFile(brandMarkFontAsset).readAsBytesSync(),
  );

  group('cada PNG coincide con lo que genera el script', () {
    for (final spec in appIcons) {
      test(spec.path, () {
        final png = decodePng(_appFile(spec.path).readAsBytesSync());
        expect(
          (png.width, png.height),
          (spec.size, spec.size),
          reason: _regenerate,
        );
        // iOS y los "any" de la web, opacos: sin canal alfa.
        expect(png.channels, spec.opaque ? 3 : 4, reason: _regenerate);

        final expected = renderIcon(spec, mark);
        var maxDifference = 0;
        for (var i = 0; i < expected.length; i++) {
          final difference = (expected[i] - png.pixels[i]).abs();
          if (difference > maxDifference) maxDifference = difference;
        }
        expect(maxDifference, lessThanOrEqualTo(1), reason: _regenerate);
      });
    }
  });

  group('la R de la fuente', () {
    test(
      'Cinzel: cinco contornos cerrados y encadenados, en la caja de la R',
      () {
        final contours = readGlyphContours(
          _appFile(brandMarkFontAsset).readAsBytesSync(),
          brandMarkCodePoint,
        );
        // El arco con la pierna, el asta y tres serifas (se superponen).
        expect(contours, hasLength(5));
        for (final contour in contours) {
          for (var i = 0; i < contour.length; i++) {
            final next = contour[(i + 1) % contour.length];
            expect(
              (contour[i].to.x, contour[i].to.y),
              (next.from.x, next.from.y),
            );
          }
        }
        expect(mark.bounds.minY, closeTo(0, 0.5));
        expect(mark.bounds.maxY, closeTo(700, 0.5));
        expect(
          (mark.bounds.maxX - mark.bounds.minX) /
              (mark.bounds.maxY - mark.bounds.minY),
          closeTo(0.95, 0.01),
        );
      },
    );

    test('una letra con curvas seguidas (la O) también queda cerrada', () {
      final contours = readGlyphContours(
        _appFile(brandMarkFontAsset).readAsBytesSync(),
        0x4F,
      );
      expect(contours, isNotEmpty);
      for (final contour in contours) {
        expect(contour.where((s) => s.control != null), isNotEmpty);
        expect(
          (contour.last.to.x, contour.last.to.y),
          (contour.first.from.x, contour.first.from.y),
        );
      }
    });

    test('una letra que la fuente no tiene: error claro', () {
      expect(
        () => readGlyphContours(
          _appFile(brandMarkFontAsset).readAsBytesSync(),
          0x4E2D, // 中
        ),
        throwsFormatException,
      );
    });
  });

  test('contornos superpuestos: la unión, sin costura en el borde interno', () {
    // Dos rectángulos que se pisan en el medio: su unión es un cuadrado. Los
    // bordes internos (x = ±0,2) no tienen que dejar una línea más clara.
    GlyphSegment line(double x0, double y0, double x1, double y1) =>
        GlyphSegment(GlyphPoint(x0, y0), GlyphPoint(x1, y1));
    List<GlyphSegment> rect(double left, double right) => [
      line(left, -1, right, -1),
      line(right, -1, right, 1),
      line(right, 1, left, 1),
      line(left, 1, left, -1),
    ];
    final square = MarkOutline([rect(-1, 0.2), rect(-0.2, 1)]);
    const spec = IconSpec('x.png', 40, IconBackground.square, 0.25);
    final pixels = renderIcon(spec, square);
    // El cuadrado va de 10 a 30 px: adentro (con un píxel de margen), crema.
    final cream = [
      (brandCream >> 16) & 0xFF,
      (brandCream >> 8) & 0xFF,
      brandCream & 0xFF,
    ];
    for (var row = 11; row < 29; row++) {
      for (var column = 11; column < 29; column++) {
        final i = (row * 40 + column) * 3;
        expect(
          pixels.sublist(i, i + 3),
          cream,
          reason: 'píxel ($column, $row)',
        );
      }
    }
    // Afuera, oliva.
    expect(pixels.sublist(0, 3), [
      (brandOlive >> 16) & 0xFF,
      (brandOlive >> 8) & 0xFF,
      brandOlive & 0xFF,
    ]);
  });

  test('PNG: codificar y decodificar no cambia los píxeles', () {
    const spec = IconSpec('x.png', 24, IconBackground.circle, 0.3);
    final pixels = renderIcon(spec, mark);
    final decoded = decodePng(encodeIcon(spec, mark));
    expect(decoded.channels, 4);
    expect(decoded.pixels, pixels);
  });

  test('no falta ningún ícono de iOS (AppIcon.appiconset/Contents.json)', () {
    const folder = 'ios/Runner/Assets.xcassets/AppIcon.appiconset';
    final contents = jsonDecode(
      _appFile('$folder/Contents.json').readAsStringSync(),
    ) as Map<String, dynamic>;
    final files = {
      for (final image in contents['images'] as List<dynamic>)
        '$folder/${(image as Map<String, dynamic>)['filename']}',
    };
    expect(files, isNotEmpty);
    expect(files.difference({for (final s in appIcons) s.path}), isEmpty);
  });

  test('no falta ningún ícono de la web (manifest.json, favicon)', () {
    final manifest = jsonDecode(
      _appFile('web/manifest.json').readAsStringSync(),
    ) as Map<String, dynamic>;
    final files = {
      'web/favicon.png',
      for (final icon in manifest['icons'] as List<dynamic>)
        'web/${(icon as Map<String, dynamic>)['src']}',
    };
    expect(files.difference({for (final s in appIcons) s.path}), isEmpty);
  });

  test('no falta ningún ícono de Android (mipmap-*/ic_launcher.png)', () {
    final res = _appFile('android/app/src/main/res/values/styles.xml')
        .parent
        .parent;
    final launchers = {
      for (final dir in res.listSync().whereType<Directory>())
        if (File('${dir.path}${Platform.pathSeparator}ic_launcher.png')
            .existsSync())
          'android/app/src/main/res/${dir.uri.pathSegments.where((s) => s.isNotEmpty).last}/ic_launcher.png',
    };
    expect(launchers, hasLength(5));
    expect(launchers.difference({for (final s in appIcons) s.path}), isEmpty);
  });
}

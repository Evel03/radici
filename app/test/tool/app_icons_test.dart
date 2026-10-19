// Los íconos del repo (web, Android, iOS) son exactamente los que dibuja
// tool/generate_icons.dart a partir de la marca, y no queda ninguno de la
// plantilla de Flutter. Si se cambia la marca o la lista:
//   cd app && dart run tool/generate_icons.dart
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../../tool/icons/icon_renderer.dart';
import '../support/repo_files.dart';

const String _regenerate =
    'Regenerar con: cd app && dart run tool/generate_icons.dart';

File _appFile(String path) => findRepoFile('app/$path');

void main() {
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

        final expected = renderIcon(spec);
        var maxDifference = 0;
        for (var i = 0; i < expected.length; i++) {
          final difference = (expected[i] - png.pixels[i]).abs();
          if (difference > maxDifference) maxDifference = difference;
        }
        expect(maxDifference, lessThanOrEqualTo(1), reason: _regenerate);
      });
    }
  });

  test('PNG: codificar y decodificar no cambia los píxeles', () {
    const spec = IconSpec('x.png', 24, IconBackground.circle, 0.3);
    final pixels = renderIcon(spec);
    final decoded = decodePng(encodeIcon(spec));
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

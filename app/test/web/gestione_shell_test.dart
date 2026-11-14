// Lo que se ve antes de que arranque Flutter en /gestione/ (pantalla de carga,
// color del navegador y manifest) usa los colores del tema: sin un parpadeo de
// otro color, en claro y en oscuro.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:radici/core/theme.dart';

import '../support/repo_files.dart';

String _hex(Color color) =>
    '#${(color.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0')}';

void main() {
  final light = buildLightTheme().colorScheme;
  final dark = buildDarkTheme().colorScheme;

  test('loading.css: fondo y rueda del tema, en claro y en oscuro', () {
    final css = findRepoFile('app/web/loading.css')
        .readAsStringSync()
        .toLowerCase();
    final darkBlocks = RegExp(
      r'@media \(prefers-color-scheme: dark\) \{([\s\S]*?)\n\}',
    ).allMatches(css).map((m) => m.group(1)!).join('\n');
    final lightPart = css.replaceAll(
      RegExp(r'@media \(prefers-color-scheme: dark\) \{[\s\S]*?\n\}'),
      '',
    );
    expect(lightPart, contains('background: ${_hex(light.surface)};'));
    expect(lightPart, contains('border-top-color: ${_hex(light.primary)};'));
    expect(darkBlocks, contains('background: ${_hex(dark.surface)};'));
    expect(darkBlocks, contains('border-top-color: ${_hex(dark.primary)};'));
  });

  test('index.html y manifest.json: el color del navegador es el fondo del tema', () {
    final html = findRepoFile('app/web/index.html')
        .readAsStringSync()
        .toLowerCase();
    expect(
      html,
      contains(
        '<meta name="theme-color" media="(prefers-color-scheme: light)" content="${_hex(light.surface)}">',
      ),
    );
    expect(
      html,
      contains(
        '<meta name="theme-color" media="(prefers-color-scheme: dark)" content="${_hex(dark.surface)}">',
      ),
    );
    final manifest = readJsonObject(findRepoFile('app/web/manifest.json'));
    expect(
      (manifest['theme_color'] as String).toLowerCase(),
      _hex(light.surface),
    );
    expect(
      (manifest['background_color'] as String).toLowerCase(),
      _hex(light.surface),
    );
  });
}

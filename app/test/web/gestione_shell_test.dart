// Lo que se ve antes de que arranque Flutter en /gestione/ (pantalla de carga,
// color del navegador y manifest) usa los colores del tema: sin un parpadeo de
// otro color, en claro y en oscuro. Además, lo que necesita el iPhone para la
// app agregada a la pantalla de inicio.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:radici/core/theme.dart';

import '../support/repo_files.dart';

String _hex(Color color) =>
    '#${(color.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0')}';

String _indexHtml() => findRepoFile('app/web/index.html').readAsStringSync();

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
    final html = _indexHtml().toLowerCase();
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

  test('index.html: viewport de la pantalla de carga y app de pantalla completa en iOS', () {
    final html = _indexHtml();
    // Solo para la pantalla de carga: al arrancar, Flutter pone el suyo (por
    // eso tampoco va viewport-fit=cover).
    expect(
      html,
      contains(
        '<meta name="viewport" content="width=device-width, initial-scale=1">',
      ),
    );
    expect(html, isNot(contains('viewport-fit')));
    // iOS abre la app de la pantalla de inicio sin la barra de Safari, con la
    // barra de estado de siempre.
    expect(
      html,
      contains('<meta name="apple-mobile-web-app-capable" content="yes">'),
    );
    expect(html, contains('<meta name="mobile-web-app-capable" content="yes">'));
    expect(
      html,
      contains(
        '<meta name="apple-mobile-web-app-status-bar-style" content="default">',
      ),
    );
  });

  test('pantalla de carga: el ícono de la app y ningún texto (antes de Flutter no hay ARB)', () {
    final html = _indexHtml();
    final start = html.indexOf('<div id="loading"');
    final end = html.indexOf('<script src="flutter_bootstrap.js"');
    expect(start, isNot(-1));
    expect(end, greaterThan(start));
    final loading = html.substring(start, end);

    // El de 512 px: se muestra a 96 px y en un iPhone con 3 píxeles por
    // punto hacen falta 288 (el de 192 se vería borroso).
    expect(
      loading,
      contains(
        '<img class="loading__icon" src="icons/Icon-512.png" alt="" '
        'width="96" height="96">',
      ),
    );
    expect(findRepoFile('app/web/icons/Icon-512.png').existsSync(), isTrue);
    expect(
      loading.replaceAll(RegExp(r'<[^>]*>'), '').trim(),
      isEmpty,
      reason: 'sin texto visible',
    );
    // Lo que lee VoiceOver: el nombre de la marca, igual en todos los idiomas.
    expect(loading, contains('aria-label="Radici"'));
    expect(
      findRepoFile('app/web/loading.css').readAsStringSync(),
      contains('.loading__icon {'),
    );
  });

  test('index.html: sin scripts ni estilos inline (la CSP de /gestione/* no los deja)', () {
    final html = _indexHtml();
    expect(html, isNot(contains('<style')));
    expect(html, isNot(contains(' style=')));
    expect(RegExp(r'<script(?![^>]*\bsrc=)').hasMatch(html), isFalse);
  });

  test('manifest.json: id fijo, el mismo que ya tenía la app instalada (su start_url)', () {
    final manifest = readJsonObject(findRepoFile('app/web/manifest.json'));
    // Sin id, el navegador usa start_url ("." → https://…/gestione/); el id
    // se resuelve contra el origen: "/gestione/" es esa misma URL.
    expect(manifest['id'], '/gestione/');
    expect(manifest['start_url'], '.');
    expect(manifest['scope'], '.');
    expect(manifest['display'], 'standalone');
  });
}

// La portada de la app (features/home) dice lo mismo que la de la web: cada
// texto landing* de los ARB es el de web/src/i18n/{it,es,en}.json, las fotos
// son las mismas y los números de los textos ({minRecipes}, {maxRecipes},
// {maxWeeks}) salen de los mismos límites que usa la web. Si se cambia un
// texto de la portada web, este test pide copiarlo acá.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:radici/features/bookings/domain/booking_draft.dart';
import 'package:radici/features/home/presentation/landing_sections.dart';
import 'package:radici/features/quote/domain/quote.dart';

import '../support/repo_files.dart';

/// Textos de la web que la app no muestra (son del `<head>` de la página).
const _webOnly = {'metaTitle', 'metaDescription'};

/// Los del pie de la web (common.*) que también van en la portada.
const _fromCommon = {
  'landingFooterSlogan': 'slogan',
  'landingFooterTagline': 'footerTagline',
  'landingFooterPrivacy': 'footerPrivacy',
};

String _capitalize(String s) => s[0].toUpperCase() + s.substring(1);

/// Clave del ARB → texto de la web: landing.hero.label1Title pasa a
/// landingHeroLabel1Title.
Map<String, String> _webTexts(String locale) {
  final web = readJsonObject(findRepoFile('web/src/i18n/$locale.json'));
  final texts = <String, String>{};
  void walk(Object? node, List<String> path) {
    if (node is Map<String, dynamic>) {
      node.forEach((key, value) => walk(value, [...path, key]));
    } else if (!_webOnly.contains(path.last)) {
      texts['landing${path.map(_capitalize).join()}'] = node! as String;
    }
  }

  walk(web['landing'], const []);
  final common = web['common'] as Map<String, dynamic>;
  _fromCommon.forEach((key, source) => texts[key] = common[source] as String);
  return texts;
}

/// El valor entero de [name] en LIMITS de cook_load.ts (lo que usa la web).
int _webLimit(String source, String name) {
  final match = RegExp('\\b$name:\\s*(\\d+)').firstMatch(source);
  expect(match, isNotNull, reason: 'LIMITS.$name en cook_load.ts');
  return int.parse(match!.group(1)!);
}

void main() {
  for (final locale in ['it', 'es', 'en']) {
    test('app_$locale.arb: los textos de la portada son los de la web', () {
      final expected = _webTexts(locale);
      final arb = readJsonObject(findRepoFile('lib/l10n/app_$locale.arb'));
      final landing = {
        for (final MapEntry(:key, :value) in arb.entries)
          if (key.startsWith('landing')) key: value,
      };
      expect(expected, isNotEmpty);
      expect(
        landing.keys.toSet().difference(expected.keys.toSet()),
        isEmpty,
        reason: 'claves landing* que la web no tiene',
      );
      for (final MapEntry(:key, :value) in expected.entries) {
        expect(landing[key], value, reason: '$key ($locale)');
      }
    });
  }

  test('las fotos son las de la web, sin cambios', () {
    // app/web/index.html es el de Flutter: la portada es la de la web pública,
    // al lado de su vite.config.ts.
    final webRoot = findRepoFile('web/vite.config.ts').parent.path;
    final html = File('$webRoot/index.html').readAsStringSync();
    final webPhotos = RegExp(r'/src/images/([\w-]+\.jpg)')
        .allMatches(html)
        .map((m) => m.group(1)!)
        .toSet();
    final appPhotos = {
      for (final asset in LandingPhotos.all) asset.split('/').last,
    };
    expect(appPhotos, webPhotos);
    for (final asset in LandingPhotos.all) {
      final name = asset.split('/').last;
      expect(
        findRepoFile(asset).readAsBytesSync(),
        findRepoFile('web/src/images/$name').readAsBytesSync(),
        reason: name,
      );
    }
  });

  test('los números de los textos son los límites de la web', () {
    final source = findRepoFile('supabase/functions/_shared/cook_load.ts')
        .readAsStringSync();
    expect(QuoteLimits.minRecipes, _webLimit(source, 'minRecipes'));
    expect(QuoteLimits.maxRecipes, _webLimit(source, 'maxRecipes'));
    expect(maxBookingWeeks, _webLimit(source, 'maxWeeks'));
  });
}

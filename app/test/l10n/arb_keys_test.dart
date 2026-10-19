// Las traducciones tienen que tener exactamente las mismas claves que la
// plantilla italiana, y los mismos placeholders.
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mestolo/app.dart';
import 'package:mestolo/l10n/app_localizations.dart';

import '../support/repo_files.dart';

Map<String, dynamic> _arb(String locale) =>
    readJsonObject(findRepoFile('lib/l10n/app_$locale.arb'));

/// Claves de mensajes (sin metadatos `@...`).
Set<String> _messageKeys(Map<String, dynamic> arb) =>
    arb.keys.where((k) => !k.startsWith('@')).toSet();

/// Placeholders `{nombre}` que aparecen en un mensaje simple.
Set<String> _placeholders(String message) =>
    RegExp(r'\{(\w+)\}').allMatches(message).map((m) => m.group(1)!).toSet();

void main() {
  final template = _arb('it');
  final templateKeys = _messageKeys(template);

  test('la plantilla italiana tiene mensajes', () {
    expect(template['@@locale'], 'it');
    expect(templateKeys, isNotEmpty);
  });

  for (final locale in ['es', 'en']) {
    group('app_$locale.arb', () {
      final arb = _arb(locale);

      test('declara su idioma', () => expect(arb['@@locale'], locale));

      test('tiene las mismas claves que app_it.arb', () {
        final keys = _messageKeys(arb);
        expect(
          keys.difference(templateKeys),
          isEmpty,
          reason: 'claves que sobran en $locale',
        );
        expect(
          templateKeys.difference(keys),
          isEmpty,
          reason: 'claves que faltan en $locale',
        );
      });

      test('sin textos vacíos y con los mismos placeholders', () {
        for (final key in templateKeys) {
          final message = arb[key] as String;
          expect(message.trim(), isNotEmpty, reason: key);
          expect(
            _placeholders(message),
            _placeholders(template[key] as String),
            reason: key,
          );
        }
      });
    });
  }

  test('el italiano es el idioma de respaldo y no falta ninguno', () {
    expect(appSupportedLocales.first, const Locale('it'));
    expect(
      appSupportedLocales.toSet(),
      AppLocalizations.supportedLocales.toSet(),
    );
  });
}

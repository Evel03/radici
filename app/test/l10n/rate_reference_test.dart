// La referencia de la tarifa (decisión del 22/11/2026) existe en los tres
// idiomas, con el nombre que ve Evelyn, y el importe va dentro del texto.
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:radici/l10n/app_localizations.dart';

void main() {
  final expected = {
    'it': 'Riferimento tariffa',
    'es': 'Referencia de la tarifa',
    'en': 'Rate reference',
  };
  for (final entry in expected.entries) {
    test('referencia de la tarifa en ${entry.key}', () async {
      final l10n = await AppLocalizations.delegate.load(Locale(entry.key));
      expect(l10n.rateReferenceLabel, entry.value);
      expect(l10n.bookingRateReference('560,00 €'), '${entry.value}: 560,00 €');
    });
  }
}

// Textos de la disponibilidad en los tres idiomas: nombre de cada feriado,
// nacional o local (el patrono de Bergamo), y el horario del día.
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:radici/features/availability/domain/availability.dart';
import 'package:radici/features/availability/domain/italian_holidays.dart';
import 'package:radici/features/availability/presentation/availability_labels.dart';
import 'package:radici/l10n/app_localizations.dart';

void main() {
  AppLocalizations l10n(String code) => lookupAppLocalizations(Locale(code));

  test('feriado nacional y feriado local de Bergamo, en it, es y en', () {
    expect(l10n('it').holidayLine(ItalianHoliday.immaculate), 'Festività: Immacolata Concezione');
    expect(
      l10n('it').holidayLine(ItalianHoliday.saintAlexander),
      "Festività locale: Sant'Alessandro, patrono di Bergamo",
    );
    expect(l10n('es').holidayLine(ItalianHoliday.saintFrancis), 'Feriado: San Francisco de Asís');
    expect(
      l10n('es').holidayLine(ItalianHoliday.saintAlexander),
      'Feriado local: San Alejandro, patrono de Bérgamo',
    );
    expect(l10n('en').holidayLine(ItalianHoliday.christmas), 'Public holiday: Christmas Day');
    expect(
      l10n('en').holidayLine(ItalianHoliday.saintAlexander),
      'Local holiday: St Alexander, patron saint of Bergamo',
    );
  });

  test('cada feriado tiene nombre en cada idioma', () {
    for (final code in ['it', 'es', 'en']) {
      final names = {for (final h in ItalianHoliday.values) l10n(code).holidayName(h)};
      expect(names, hasLength(ItalianHoliday.values.length), reason: code);
      expect(names.every((n) => n.trim().isNotEmpty), isTrue, reason: code);
    }
  });

  test('el horario: una franja o varias, en 24 horas', () {
    AvailabilityRule rule(Duration start, Duration end) =>
        AvailabilityRule(weekday: 1, start: start, end: end);

    expect(formatHours([rule(const Duration(hours: 9), const Duration(hours: 15))]), '09:00–15:00');
    expect(
      formatHours([
        rule(const Duration(hours: 9), const Duration(hours: 12, minutes: 30)),
        rule(const Duration(hours: 14), const Duration(hours: 18)),
      ]),
      '09:00–12:30, 14:00–18:00',
    );
    expect(formatHours(const []), '');
  });
}

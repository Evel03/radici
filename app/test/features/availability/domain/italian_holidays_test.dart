// Feriados: Pascua (algoritmo gregoriano anónimo), Pasquetta, los de fecha
// fija, San Francesco desde 2026 (legge 8 ottobre 2025, n. 151) y el patrono
// de Bergamo, que es feriado local y no nacional.
import 'package:flutter_test/flutter_test.dart';
import 'package:radici/core/rome_time.dart';
import 'package:radici/features/availability/domain/italian_holidays.dart';

void main() {
  group('easterSunday', () {
    test('fechas conocidas', () {
      expect(easterSunday(2025), CalendarDate(2025, 4, 20));
      expect(easterSunday(2026), CalendarDate(2026, 4, 5));
      expect(easterSunday(2027), CalendarDate(2027, 3, 28));
      expect(easterSunday(2028), CalendarDate(2028, 4, 16));
    });

    test('los extremos del calendario gregoriano: 22/3 y 25/4', () {
      expect(easterSunday(1818), CalendarDate(1818, 3, 22));
      expect(easterSunday(2285), CalendarDate(2285, 3, 22));
      expect(easterSunday(1943), CalendarDate(1943, 4, 25));
      expect(easterSunday(2038), CalendarDate(2038, 4, 25));
    });

    test('siempre cae domingo, entre el 22/3 y el 25/4', () {
      for (var year = 1900; year <= 2200; year++) {
        final easter = easterSunday(year);
        expect(easter.weekday, DateTime.sunday, reason: '$year');
        expect(easter.isBefore(CalendarDate(year, 3, 22)), isFalse, reason: '$year');
        expect(easter.isAfter(CalendarDate(year, 4, 25)), isFalse, reason: '$year');
      }
    });
  });

  group('italianHolidays (nacionales)', () {
    test('2026: los doce, con Pasquetta calculada', () {
      expect(italianHolidays(2026), {
        CalendarDate(2026, 1, 1): ItalianHoliday.newYear,
        CalendarDate(2026, 1, 6): ItalianHoliday.epiphany,
        CalendarDate(2026, 4, 6): ItalianHoliday.easterMonday,
        CalendarDate(2026, 4, 25): ItalianHoliday.liberation,
        CalendarDate(2026, 5, 1): ItalianHoliday.labour,
        CalendarDate(2026, 6, 2): ItalianHoliday.republic,
        CalendarDate(2026, 8, 15): ItalianHoliday.assumption,
        CalendarDate(2026, 10, 4): ItalianHoliday.saintFrancis,
        CalendarDate(2026, 11, 1): ItalianHoliday.allSaints,
        CalendarDate(2026, 12, 8): ItalianHoliday.immaculate,
        CalendarDate(2026, 12, 25): ItalianHoliday.christmas,
        CalendarDate(2026, 12, 26): ItalianHoliday.stStephen,
      });
    });

    test('el 8/12 es la Inmaculada', () {
      expect(
        italianHolidays(2026)[CalendarDate(2026, 12, 8)],
        ItalianHoliday.immaculate,
      );
    });

    test('Pasquetta 2027 cae el 29/3', () {
      expect(
        italianHolidays(2027)[CalendarDate(2027, 3, 29)],
        ItalianHoliday.easterMonday,
      );
    });

    test('San Francesco (4/10) es feriado nacional desde 2026, no antes', () {
      expect(italianHolidays(2025).values, isNot(contains(ItalianHoliday.saintFrancis)));
      expect(italianHolidays(2025)[CalendarDate(2025, 10, 4)], isNull);
      expect(
        italianHolidays(2026)[CalendarDate(2026, 10, 4)],
        ItalianHoliday.saintFrancis,
      );
      expect(
        italianHolidays(2030)[CalendarDate(2030, 10, 4)],
        ItalianHoliday.saintFrancis,
      );
    });

    test('Sant\'Alessandro no es feriado nacional', () {
      expect(italianHolidays(2026)[CalendarDate(2026, 8, 26)], isNull);
      expect(italianHolidays(2026).values, isNot(contains(ItalianHoliday.saintAlexander)));
    });

    test('si Pasquetta cae el 25/4 (2011) se marca una sola vez, como Liberazione', () {
      final holidays = italianHolidays(2011);
      expect(holidays[CalendarDate(2011, 4, 25)], ItalianHoliday.liberation);
      expect(holidays.values, isNot(contains(ItalianHoliday.easterMonday)));
      expect(holidays, hasLength(10));
    });
  });

  group('Bergamo: los nacionales más el patrono', () {
    test('Sant\'Alessandro (26/8) es festivo local de Bergamo', () {
      final holidays = bergamoHolidays(2026);
      expect(holidays[CalendarDate(2026, 8, 26)], ItalianHoliday.saintAlexander);
      expect(ItalianHoliday.saintAlexander.isNational, isFalse);
      expect(holidays, hasLength(13));
      // También antes de 2026: el patrono no depende de la ley de San Francesco.
      expect(
        bergamoHolidays(2025)[CalendarDate(2025, 8, 26)],
        ItalianHoliday.saintAlexander,
      );
    });

    test('todos los demás son nacionales', () {
      for (final holiday in ItalianHoliday.values) {
        if (holiday == ItalianHoliday.saintAlexander) continue;
        expect(holiday.isNational, isTrue, reason: holiday.name);
      }
    });

    test('bergamoHolidayOn busca por fecha; un día común da null', () {
      expect(bergamoHolidayOn(CalendarDate(2026, 12, 8)), ItalianHoliday.immaculate);
      expect(bergamoHolidayOn(CalendarDate(2026, 8, 26)), ItalianHoliday.saintAlexander);
      expect(bergamoHolidayOn(CalendarDate(2027, 3, 29)), ItalianHoliday.easterMonday);
      expect(bergamoHolidayOn(CalendarDate(2026, 10, 19)), isNull);
    });
  });
}

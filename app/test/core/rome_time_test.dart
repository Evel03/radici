import 'package:flutter_test/flutter_test.dart';
import 'package:radici/core/rome_time.dart';

void main() {
  group('romeInstant: una hora de Roma de un día, como instante', () {
    test('en invierno (UTC+1) y en verano (UTC+2)', () {
      expect(
        romeInstant(CalendarDate(2026, 11, 25), 10 * 60),
        DateTime.utc(2026, 11, 25, 9),
      );
      expect(
        romeInstant(CalendarDate(2026, 7, 15), 10 * 60 + 30),
        DateTime.utc(2026, 7, 15, 8, 30),
      );
    });

    test('el día del cambio de hora, con el desfase de esa hora', () {
      // 29/3/2026: a las 2:00 de Roma (1:00 UTC) pasa a las 3:00.
      expect(
        romeInstant(CalendarDate(2026, 3, 29), 60),
        DateTime.utc(2026, 3, 29, 0),
      );
      expect(
        romeInstant(CalendarDate(2026, 3, 29), 10 * 60),
        DateTime.utc(2026, 3, 29, 8),
      );
      // 25/10/2026: a las 3:00 de Roma (1:00 UTC) vuelve a las 2:00.
      expect(
        romeInstant(CalendarDate(2026, 10, 25), 10 * 60),
        DateTime.utc(2026, 10, 25, 9),
      );
    });

    test('es la inversa de romeWallClock', () {
      final instant = romeInstant(CalendarDate(2026, 12, 2), 9 * 60 + 45);
      final wall = romeWallClock(instant);
      expect((wall.day, wall.hour, wall.minute), (2, 9, 45));
    });
  });

  group('romeToday (mismos casos que public_request.test.ts)', () {
    test('cambio a horario de verano: 23:30 UTC ya es el día siguiente', () {
      // 2026-03-28 23:30 UTC ya es 29 de marzo en Roma (UTC+1).
      expect(romeToday(DateTime.utc(2026, 3, 28, 23, 30)).toIso(), '2026-03-29');
    });

    test('verano (UTC+2)', () {
      expect(romeToday(DateTime.utc(2026, 7, 14, 22, 30)).toIso(), '2026-07-15');
      expect(romeToday(DateTime.utc(2026, 7, 14, 21, 30)).toIso(), '2026-07-14');
    });
  });

  group('romeUtcOffset: cambios de hora de 2026', () {
    test('29 de marzo a la 01:00 UTC empieza el horario de verano', () {
      expect(
        romeUtcOffset(DateTime.utc(2026, 3, 29, 0, 59)),
        const Duration(hours: 1),
      );
      expect(
        romeUtcOffset(DateTime.utc(2026, 3, 29, 1)),
        const Duration(hours: 2),
      );
    });

    test('25 de octubre a la 01:00 UTC vuelve el horario de invierno', () {
      expect(
        romeUtcOffset(DateTime.utc(2026, 10, 25, 0, 59)),
        const Duration(hours: 2),
      );
      expect(
        romeUtcOffset(DateTime.utc(2026, 10, 25, 1)),
        const Duration(hours: 1),
      );
    });

    test('romeStartOfDay: medianoche de Roma, también los días del cambio de hora', () {
      // Verano (UTC+2) e invierno (UTC+1).
      expect(romeStartOfDay(CalendarDate(2026, 10, 20)), DateTime.utc(2026, 10, 19, 22));
      expect(romeStartOfDay(CalendarDate(2026, 12, 25)), DateTime.utc(2026, 12, 24, 23));
      // El domingo del cambio empieza con el desfase de antes; el lunes, con el nuevo.
      expect(romeStartOfDay(CalendarDate(2026, 3, 29)), DateTime.utc(2026, 3, 28, 23));
      expect(romeStartOfDay(CalendarDate(2026, 3, 30)), DateTime.utc(2026, 3, 29, 22));
      expect(romeStartOfDay(CalendarDate(2026, 10, 25)), DateTime.utc(2026, 10, 24, 22));
      expect(romeStartOfDay(CalendarDate(2026, 10, 26)), DateTime.utc(2026, 10, 25, 23));
      // Coherente con romeToday: justo antes es el día anterior.
      for (final date in [CalendarDate(2026, 3, 29), CalendarDate(2026, 10, 26)]) {
        final start = romeStartOfDay(date);
        expect(romeToday(start), date);
        expect(romeToday(start.subtract(const Duration(milliseconds: 1))), date.addDays(-1));
      }
    });

    test('la hora de pared respeta el desfase', () {
      final summer = romeWallClock(DateTime.utc(2026, 10, 19, 12, 34));
      expect((summer.hour, summer.minute), (14, 34));
      final winter = romeWallClock(DateTime.utc(2026, 12, 24, 23, 15));
      expect((winter.day, winter.hour), (25, 0));
      // Un instante con otra zona se convierte igual.
      final local = DateTime.utc(2026, 1, 10, 8).toLocal();
      expect(romeWallClock(local).hour, 9);
    });
  });

  group('CalendarDate', () {
    test('lee y escribe AAAA-MM-DD y rechaza fechas inexistentes', () {
      expect(CalendarDate.parse('2026-10-20').toIso(), '2026-10-20');
      expect(CalendarDate.parse('2028-02-29').day, 29);
      expect(() => CalendarDate.parse('2026-02-29'), throwsFormatException);
      expect(() => CalendarDate.parse('20/10/2026'), throwsFormatException);
    });

    test('suma días cruzando meses, años y cambios de hora', () {
      expect(CalendarDate(2026, 10, 31).addDays(1).toIso(), '2026-11-01');
      expect(CalendarDate(2026, 12, 31).addDays(14).toIso(), '2027-01-14');
      expect(CalendarDate(2026, 3, 28).addDays(2).toIso(), '2026-03-30');
      expect(CalendarDate(2026, 10, 24).addDays(2).toIso(), '2026-10-26');
    });

    test('semana desde el lunes y meses', () {
      // 19/10/2026 es lunes; 25/10/2026, domingo.
      expect(CalendarDate(2026, 10, 19).weekday, DateTime.monday);
      expect(CalendarDate(2026, 10, 25).startOfWeek.toIso(), '2026-10-19');
      expect(CalendarDate(2026, 10, 19).startOfWeek.toIso(), '2026-10-19');
      expect(CalendarDate(2026, 1, 31).addMonths(1).toIso(), '2026-02-28');
      expect(CalendarDate(2026, 12, 15).addMonths(1).toIso(), '2027-01-15');
      expect(CalendarDate(2026, 1, 15).addMonths(-1).toIso(), '2025-12-15');
    });

    test('igualdad, orden y distancia en días', () {
      expect(CalendarDate(2026, 10, 19), CalendarDate.parse('2026-10-19'));
      expect(CalendarDate(2026, 10, 19).isBefore(CalendarDate(2026, 10, 20)), isTrue);
      expect(CalendarDate(2026, 10, 19).daysUntil(CalendarDate(2026, 11, 2)), 14);
      expect({CalendarDate(2026, 1, 1), CalendarDate(2026, 1, 1)}, hasLength(1));
    });
  });
}

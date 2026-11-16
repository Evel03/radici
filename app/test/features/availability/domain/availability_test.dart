// Disponibilidad en Dart puro: dow de Postgres, horas, estado de cada día,
// rangos y lo que la agenda muestra de un día. "Hoy" en los tests: lunes
// 19/10/2026 (testNow).
import 'package:flutter_test/flutter_test.dart';
import 'package:radici/core/rome_time.dart';
import 'package:radici/features/availability/domain/availability.dart';
import 'package:radici/features/availability/domain/italian_holidays.dart';

void main() {
  final today = CalendarDate(2026, 10, 19);

  AvailabilityRule rule(int weekday, int from, int to) => AvailabilityRule(
    weekday: weekday,
    start: Duration(hours: from),
    end: Duration(hours: to),
  );

  // Lunes a viernes de 9 a 15, como Evelyn.
  final weekdays = [for (var d = 1; d <= 5; d++) rule(d, 9, 15)];

  AvailabilitySnapshot snapshot({
    List<AvailabilityRule>? rules,
    List<BlockedDay> blocked = const [],
  }) => AvailabilitySnapshot(
    rules: rules ?? weekdays,
    blocked: {for (final b in blocked) b.date: b},
  );

  group('dow de Postgres y weekday de Dart', () {
    test('weekdayFromDow: 0 es domingo (7); de 1 a 6 queda igual', () {
      expect(weekdayFromDow(0), 7);
      expect(weekdayFromDow(1), 1);
      expect(weekdayFromDow(6), 6);
      expect(() => weekdayFromDow(7), throwsRangeError);
      expect(() => weekdayFromDow(-1), throwsRangeError);
    });

    test('dowFromWeekday: el domingo (7) es 0', () {
      expect(dowFromWeekday(7), 0);
      expect(dowFromWeekday(1), 1);
      expect(dowFromWeekday(6), 6);
      expect(() => dowFromWeekday(0), throwsRangeError);
      expect(() => dowFromWeekday(8), throwsRangeError);
    });

    test('ida y vuelta para toda la semana', () {
      for (var weekday = 1; weekday <= 7; weekday++) {
        expect(weekdayFromDow(dowFromWeekday(weekday)), weekday);
      }
    });
  });

  group('parsePgTime', () {
    test('lee la hora `time` de Postgres', () {
      expect(parsePgTime('09:00:00'), const Duration(hours: 9));
      expect(parsePgTime('15:30:00'), const Duration(hours: 15, minutes: 30));
      expect(parsePgTime('09:00'), const Duration(hours: 9));
      expect(parsePgTime('08:45:30.5'), const Duration(hours: 8, minutes: 45, seconds: 30));
      expect(parsePgTime('24:00:00'), const Duration(hours: 24));
    });

    test('rechaza lo que no es una hora', () {
      for (final value in ['9am', '25:00:00', '09:60:00', '', '9:00:00']) {
        expect(() => parsePgTime(value), throwsFormatException, reason: value);
      }
    });
  });

  group('AvailabilityRule.fromJson', () {
    test('"09:00:00" se lee como 9 h y el dow 0 como domingo', () {
      final parsed = AvailabilityRule.fromJson({
        'dow': 0,
        'start_time': '09:00:00',
        'end_time': '15:00:00',
      });
      expect(parsed, rule(7, 9, 15));
    });

    test('una fila rota lanza FormatException', () {
      for (final json in <Map<String, dynamic>>[
        {'dow': 9, 'start_time': '09:00:00', 'end_time': '15:00:00'},
        {'dow': '1', 'start_time': '09:00:00', 'end_time': '15:00:00'},
        {'dow': 1, 'start_time': null, 'end_time': '15:00:00'},
      ]) {
        expect(() => AvailabilityRule.fromJson(json), throwsFormatException);
      }
    });
  });

  group('BlockedDay', () {
    test('fromJson lee id, fecha y nota', () {
      final day = BlockedDay.fromJson({
        'id': 'b1',
        'date': '2026-10-23',
        'note': 'Ferie',
      });
      expect(day, BlockedDay(id: 'b1', date: CalendarDate(2026, 10, 23), note: 'Ferie'));
    });

    test('una nota vacía o con espacios queda en null', () {
      for (final note in [null, '', '   ']) {
        final day = BlockedDay.fromJson({'id': 'b1', 'date': '2026-10-23', 'note': note});
        expect(day.note, isNull, reason: '$note');
      }
    });

    test('la nota es privada: no sale en toString', () {
      final day = BlockedDay(id: 'b1', date: CalendarDate(2026, 10, 23), note: 'Dal medico');
      expect(day.toString(), isNot(contains('medico')));
      final all = snapshot(blocked: [day]);
      expect(all.toString(), isNot(contains('medico')));
    });

    test('normalizeNote: recorta y deja null si queda vacía', () {
      expect(normalizeNote('  Ferie  '), 'Ferie');
      expect(normalizeNote('   '), isNull);
      expect(normalizeNote(null), isNull);
    });
  });

  group('dayStatus (hoy: lunes 19/10/2026)', () {
    final week = snapshot();

    test('hoy no cuenta como pasado: se puede bloquear', () {
      expect(dayStatus(today, today: today, availability: week), DayStatus.open);
    });

    test('el sábado no tiene regla', () {
      expect(
        dayStatus(CalendarDate(2026, 10, 24), today: today, availability: week),
        DayStatus.closed,
      );
    });

    test('el 16/10 ya pasó', () {
      expect(
        dayStatus(CalendarDate(2026, 10, 16), today: today, availability: week),
        DayStatus.past,
      );
    });

    test('un sábado bloqueado figura como bloqueado', () {
      final saturday = CalendarDate(2026, 10, 24);
      final blocked = snapshot(blocked: [BlockedDay(id: 'b1', date: saturday)]);
      expect(
        dayStatus(saturday, today: today, availability: blocked),
        DayStatus.blocked,
      );
    });

    test('prioridad: pasado > bloqueado > sin regla > abierto', () {
      final friday = CalendarDate(2026, 10, 16);
      final blocked = snapshot(blocked: [BlockedDay(id: 'b1', date: friday)]);
      expect(dayStatus(friday, today: today, availability: blocked), DayStatus.past);
      final wednesday = CalendarDate(2026, 10, 21);
      expect(
        dayStatus(
          wednesday,
          today: today,
          availability: snapshot(blocked: [BlockedDay(id: 'b2', date: wednesday)]),
        ),
        DayStatus.blocked,
      );
    });
  });

  group('datesInRange', () {
    test('incluye los dos extremos y cruza el año', () {
      expect(datesInRange(CalendarDate(2026, 12, 30), CalendarDate(2027, 1, 2)), [
        CalendarDate(2026, 12, 30),
        CalendarDate(2026, 12, 31),
        CalendarDate(2027, 1, 1),
        CalendarDate(2027, 1, 2),
      ]);
    });

    test('un solo día', () {
      expect(datesInRange(today, today), [today]);
    });

    test('un rango al revés lanza ArgumentError', () {
      expect(
        () => datesInRange(CalendarDate(2026, 10, 20), CalendarDate(2026, 10, 19)),
        throwsArgumentError,
      );
    });

    test('hasta 366 días; uno más lanza ArgumentError', () {
      expect(datesInRange(today, today.addDays(365)), hasLength(366));
      expect(() => datesInRange(today, today.addDays(366)), throwsArgumentError);
    });
  });

  group('summarizeRange', () {
    test('del 21/12 al 6/1 con 25/12, 1/1 y 6/1 ya bloqueados', () {
      final blocked = [
        BlockedDay(id: 'b1', date: CalendarDate(2026, 12, 25)),
        BlockedDay(id: 'b2', date: CalendarDate(2027, 1, 1)),
        BlockedDay(id: 'b3', date: CalendarDate(2027, 1, 6)),
      ];
      final summary = summarizeRange(
        CalendarDate(2026, 12, 21),
        CalendarDate(2027, 1, 6),
        snapshot(blocked: blocked),
      );
      expect(summary.total, 17);
      expect(summary.working, 13);
      expect(summary.toBlock, hasLength(14));
      expect(summary.alreadyBlocked, [
        CalendarDate(2026, 12, 25),
        CalendarDate(2027, 1, 1),
        CalendarDate(2027, 1, 6),
      ]);
      // Se bloquean también los fines de semana (por si suma el sábado).
      expect(summary.toBlock, contains(CalendarDate(2026, 12, 26)));
      expect(summary.toBlock, isNot(contains(CalendarDate(2026, 12, 25))));
    });
  });

  group('blockedDaysFrom', () {
    test('el lunes de la primera semana del mes de hoy', () {
      expect(blockedDaysFrom(today), CalendarDate(2026, 9, 28));
      expect(blockedDaysFrom(CalendarDate(2026, 11, 1)), CalendarDate(2026, 10, 26));
      expect(blockedDaysFrom(CalendarDate(2027, 2, 15)), CalendarDate(2027, 2, 1));
    });
  });

  group('agendaDayAvailability', () {
    test('miércoles 21/10 abierto, con su horario y los pedidos de ese día', () {
      final day = agendaDayAvailability(
        day: CalendarDate(2026, 10, 21),
        today: today,
        snapshot: snapshot(),
        requestsThatDay: 2,
      );
      expect(day.status, DayStatus.open);
      expect(day.hours, [rule(3, 9, 15)]);
      expect(day.requestCount, 2);
      expect(day.holiday, isNull);
      expect(day.canBlock, isTrue);
      expect(day.canUnblock, isFalse);
    });

    test('las franjas del día van por hora de inicio', () {
      final day = agendaDayAvailability(
        day: CalendarDate(2026, 10, 21),
        today: today,
        snapshot: snapshot(rules: [rule(3, 14, 18), rule(1, 9, 15), rule(3, 9, 12)]),
      );
      expect(day.hours, [rule(3, 9, 12), rule(3, 14, 18)]);
    });

    test('un día bloqueado trae su nota y se puede desbloquear', () {
      final friday = CalendarDate(2026, 10, 23);
      final day = agendaDayAvailability(
        day: friday,
        today: today,
        snapshot: snapshot(blocked: [BlockedDay(id: 'b1', date: friday, note: 'Ferie')]),
      );
      expect(day.status, DayStatus.blocked);
      expect(day.note, 'Ferie');
      expect(day.canBlock, isFalse);
      expect(day.canUnblock, isTrue);
      expect(day.toString(), isNot(contains('Ferie')));
    });

    test('el sábado no se puede bloquear desde la tarjeta y el pasado no tiene acciones', () {
      final saturday = agendaDayAvailability(
        day: CalendarDate(2026, 10, 24),
        today: today,
        snapshot: snapshot(),
      );
      expect(saturday.status, DayStatus.closed);
      expect(saturday.hours, isEmpty);
      expect(saturday.canBlock, isFalse);
      expect(saturday.canUnblock, isFalse);

      final past = agendaDayAvailability(
        day: CalendarDate(2026, 10, 16),
        today: today,
        snapshot: snapshot(),
      );
      expect(past.status, DayStatus.past);
      expect(past.canBlock || past.canUnblock, isFalse);
    });

    test('marca el feriado del día (también el patrono de Bergamo)', () {
      expect(
        agendaDayAvailability(
          day: CalendarDate(2026, 12, 8),
          today: today,
          snapshot: snapshot(),
        ).holiday,
        ItalianHoliday.immaculate,
      );
      expect(
        agendaDayAvailability(
          day: CalendarDate(2027, 8, 26),
          today: today,
          snapshot: snapshot(),
        ).holiday,
        ItalianHoliday.saintAlexander,
      );
    });
  });
}

import 'package:flutter_test/flutter_test.dart';
import 'package:radici/core/rome_time.dart';
import 'package:radici/features/requests/domain/agenda.dart';
import 'package:radici/features/requests/domain/chef_request.dart';

import '../../../support/request_fixtures.dart';

void main() {
  group('monthGrid', () {
    test('octubre 2026: de lunes 28/9 a domingo 1/11, 5 semanas', () {
      final weeks = monthGrid(CalendarDate(2026, 10, 19));
      expect(weeks, hasLength(5));
      expect(weeks.first.first.toIso(), '2026-09-28');
      expect(weeks.last.last.toIso(), '2026-11-01');
      for (final week in weeks) {
        expect(week, hasLength(7));
        expect(week.first.weekday, DateTime.monday);
      }
    });

    test('un mes que empieza en domingo ocupa 6 semanas', () {
      // 1/11/2026 es domingo.
      final weeks = monthGrid(CalendarDate(2026, 11, 15));
      expect(weeks, hasLength(6));
      expect(weeks.first.first.toIso(), '2026-10-26');
      expect(weeks.last.last.toIso(), '2026-12-06');
    });

    test('febrero 2027 que empieza en lunes ocupa 4 semanas', () {
      final weeks = monthGrid(CalendarDate(2027, 2, 1));
      expect(weeks, hasLength(4));
      expect(weeks.first.first.toIso(), '2027-02-01');
    });
  });

  test('weekDays: de lunes a domingo, aunque cruce el mes', () {
    final days = weekDays(CalendarDate(2026, 11, 1));
    expect(days.map((d) => d.toIso()), [
      '2026-10-26',
      '2026-10-27',
      '2026-10-28',
      '2026-10-29',
      '2026-10-30',
      '2026-10-31',
      '2026-11-01',
    ]);
  });

  group('pedidos por fecha', () {
    final day = CalendarDate(2026, 10, 21);
    // Sin franja: un pedido de la web, que manda "any" (se lee como null).
    final any = buildRequest(
      id: 'any',
      preferredDate: day,
      preferredSlot: null,
    );
    final afternoon = buildRequest(
      id: 'afternoon',
      preferredDate: day,
      preferredSlot: PreferredSlot.afternoon,
    );
    final morningLate = buildRequest(
      id: 'morning-late',
      preferredDate: day,
      createdAt: DateTime.utc(2026, 10, 19, 11),
    );
    final morningEarly = buildRequest(
      id: 'morning-early',
      preferredDate: day,
      createdAt: DateTime.utc(2026, 10, 19, 8),
    );
    final rejected = buildRequest(
      id: 'rejected',
      preferredDate: day,
      status: RequestStatus.rejected,
    );
    final otherDay = buildRequest(id: 'other', preferredDate: CalendarDate(2026, 10, 22));
    final noDateOld = buildRequest(
      id: 'no-date-old',
      noDate: true,
      createdAt: DateTime.utc(2026, 10, 10),
    );
    final noDateNew = buildRequest(id: 'no-date-new', noDate: true);
    final noDateRejected = buildRequest(
      id: 'no-date-rejected',
      noDate: true,
      status: RequestStatus.rejected,
    );
    final all = [
      any,
      afternoon,
      morningLate,
      morningEarly,
      rejected,
      otherDay,
      noDateOld,
      noDateNew,
      noDateRejected,
    ];

    test('agrupa por fecha, ordena por franja y llegada, sin rechazados', () {
      final byDate = requestsByPreferredDate(all);
      expect(byDate.keys, unorderedEquals([day, CalendarDate(2026, 10, 22)]));
      expect(byDate[day]!.map((r) => r.id), [
        'morning-early',
        'morning-late',
        'afternoon',
        'any',
      ]);
    });

    test('senza data: activos sin fecha, el que espera hace más, primero', () {
      expect(requestsWithoutDate(all).map((r) => r.id), [
        'no-date-old',
        'no-date-new',
      ]);
    });
  });
}

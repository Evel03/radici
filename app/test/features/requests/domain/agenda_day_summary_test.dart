// El resumen de un día para el cartel de su celda en el mes: de cada sesión
// viva, la clienta, las horas, «Semana k de N» (solo si la agenda leyó todas
// las semanas de la reserva), las personas, el estado y la zona; de cada
// pedido activo, el cliente, el tipo y el estado. Primero las sesiones, por
// llegada; como mucho 4, y cuántos más. Sin datos de la clienta en toString.
import 'package:flutter_test/flutter_test.dart';
import 'package:radici/core/clock_time.dart';
import 'package:radici/core/rome_time.dart';
import 'package:radici/features/requests/domain/agenda_day_summary.dart';
import 'package:radici/features/requests/domain/chef_request.dart';
import 'package:radici/features/sessions/domain/cooking_session.dart';
import 'package:radici/features/sessions/domain/session_booking.dart';

import '../../../support/request_fixtures.dart';
import '../../../support/session_fixtures.dart';

void main() {
  final day = CalendarDate(2026, 11, 25);

  /// Una sesión suelta de [day] (su pedido es de una semana).
  CookingSession single(
    int n, {
    ClockTime start = const ClockTime.hm(10, 0),
    SessionStatus status = SessionStatus.confirmed,
    String? requestId,
  }) => buildSession(
    n: n,
    date: day,
    start: start,
    status: status,
    requestId: requestId ?? 'pedido-$n',
    weeks: 1,
  );

  ChefRequest request(String id, {RequestStatus? status, DateTime? seenAt}) =>
      buildRequest(
        id: id,
        name: 'Cliente $id',
        preferredDate: day,
        status: status ?? RequestStatus.newRequest,
        seenAt: seenAt,
      );

  test('un día sin sesiones ni pedidos: sin cartel', () {
    final summary = agendaDaySummary(
      sessions: const [],
      requests: const [],
      loaded: const [],
    );
    expect(summary, AgendaDaySummary.empty);
    expect(summary.isEmpty, isTrue);
    expect(summary.more, 0);
  });

  test('de cada sesión: la clienta, las horas, «Semana k de N», las personas, el estado y la zona', () {
    final booking = buildBooking(first: CalendarDate(2026, 11, 18));
    final summary = agendaDaySummary(
      sessions: [booking[1]],
      requests: const [],
      loaded: booking,
    );
    expect(summary.items, [
      AgendaSessionSummary(
        sessionId: sessionId(2),
        name: 'Giulia Rossi',
        arrival: 10 * 60,
        end: 13 * 60,
        status: SessionStatus.confirmed,
        week: (week: 2, weeks: 4),
        people: 4,
        zone: 'Città Alta',
      ),
    ]);
    expect(summary.more, 0);
  });

  test('de cada pedido: el cliente, el tipo y el estado (uno nuevo ya abierto, visto)', () {
    final extra = buildRequest(
      id: 'extra',
      name: 'Marco Bianchi',
      preferredDate: day,
      type: RequestType.extra,
      seenAt: DateTime.utc(2026, 11, 20, 9),
    );
    final summary = agendaDaySummary(
      sessions: const [],
      requests: [
        extra,
        request('quoted', status: RequestStatus.quoted),
      ],
      loaded: const [],
    );
    expect(summary.items, const [
      AgendaRequestSummary(
        requestId: 'extra',
        name: 'Marco Bianchi',
        type: RequestType.extra,
        status: RequestStatus.newRequest,
        seen: true,
      ),
      AgendaRequestSummary(
        requestId: 'quoted',
        name: 'Cliente quoted',
        type: RequestType.week,
        status: RequestStatus.quoted,
        seen: false,
      ),
    ]);
  });

  test('primero las sesiones, por llegada; después los pedidos, en el orden de la agenda', () {
    final late = single(5, start: const ClockTime.hm(14, 0));
    final early = single(6, start: const ClockTime.hm(9, 30));
    final summary = agendaDaySummary(
      sessions: [late, early],
      requests: [request('b'), request('a')],
      loaded: [late, early],
    );
    expect(
      [
        for (final item in summary.items)
          switch (item) {
            AgendaSessionSummary(:final sessionId) => sessionId,
            AgendaRequestSummary(:final requestId) => requestId,
          },
      ],
      [sessionId(6), sessionId(5), 'b', 'a'],
    );
  });

  test(
    'las sesiones canceladas y los pedidos que ya no están activos no salen',
    () {
      final cancelled = single(5, status: SessionStatus.cancelled);
      final live = single(6);
      final summary = agendaDaySummary(
        sessions: [cancelled, live],
        requests: [request('rechazado', status: RequestStatus.rejected)],
        loaded: [cancelled, live],
      );
      expect(summary.items, hasLength(1));
      expect(
        (summary.items.single as AgendaSessionSummary).sessionId,
        sessionId(6),
      );
      expect(summary.more, 0);

      expect(
        agendaDaySummary(
          sessions: [cancelled],
          requests: const [],
          loaded: [cancelled],
        ),
        AgendaDaySummary.empty,
      );
    },
  );

  test('una vieja en shopping_done se muestra como confirmada', () {
    final old = single(5, status: SessionStatus.shoppingDone);
    final summary = agendaDaySummary(
      sessions: [old],
      requests: const [],
      loaded: [old],
    );
    expect(
      (summary.items.single as AgendaSessionSummary).status,
      SessionStatus.confirmed,
    );
  });

  group('«Semana k de N»', () {
    BookingWeekPosition? weekOf(
      CookingSession session,
      List<CookingSession> loaded,
    ) {
      final summary = agendaDaySummary(
        sessions: [session],
        requests: const [],
        loaded: loaded,
      );
      return (summary.items.single as AgendaSessionSummary).week;
    }

    test('sin contar las canceladas, como la ficha', () {
      final booking = buildBooking(statuses: {1: SessionStatus.cancelled});
      expect(weekOf(booking[2], booking), (week: 2, weeks: 3));
    });

    test(
      'sin número si la agenda no leyó las primeras semanas de la reserva',
      () {
        // Las dos primeras quedaron antes de la ventana de la agenda
        // (sessionsWindowFrom): con las otras dos saldría «2 de 2».
        final booking = buildBooking();
        final loaded = booking.skip(2).toList();
        expect(weekOf(booking[3], loaded), isNull);
        // Con todas, sí.
        expect(weekOf(booking[3], booking), (week: 4, weeks: 4));
      },
    );

    test(
      'sin número en una reserva de una semana o en una sesión sin pedido',
      () {
        final week = buildBooking(weeks: 1);
        expect(weekOf(week.single, week), isNull);
        final alone = buildSession(requestId: null);
        expect(weekOf(alone, [alone]), isNull);
      },
    );

    test('las semanas de otra reserva no cuentan', () {
      final booking = buildBooking(weeks: 2);
      final other = buildBooking(
        firstN: 10,
        requestId: 'otra-reserva',
        first: CalendarDate(2026, 11, 26),
      );
      expect(weekOf(booking[1], [...booking, ...other]), (week: 2, weeks: 2));
    });
  });

  test('como mucho 4, primero las sesiones, y cuántos más', () {
    final sessions = [
      for (var n = 1; n <= 3; n++) single(n, start: ClockTime.hm(8 + 2 * n, 0)),
    ];
    final requests = [
      for (final id in ['a', 'b', 'c']) request(id),
    ];
    final summary = agendaDaySummary(
      sessions: sessions,
      requests: requests,
      loaded: sessions,
    );
    expect(summary.items, hasLength(agendaSummaryMaxItems));
    expect(summary.items.whereType<AgendaSessionSummary>(), hasLength(3));
    expect((summary.items.last as AgendaRequestSummary).requestId, 'a');
    expect(summary.more, 2);

    final many = [
      for (var n = 1; n <= 6; n++) single(n, start: ClockTime.hm(8 + n, 0)),
    ];
    final crowded = agendaDaySummary(
      sessions: many,
      requests: [request('a')],
      loaded: many,
    );
    expect(crowded.items, hasLength(4));
    expect(crowded.items, everyElement(isA<AgendaSessionSummary>()));
    expect(crowded.more, 3);
  });

  test('dos resúmenes que muestran lo mismo son iguales', () {
    final booking = buildBooking();
    AgendaDaySummary build(List<CookingSession> loaded) => agendaDaySummary(
      sessions: [loaded[0]],
      requests: [request('a')],
      loaded: loaded,
    );
    final first = build(booking);
    final again = build([...booking]);
    expect(again, first);
    expect(again.hashCode, first.hashCode);

    final cooked = [
      booking[0].copyWith(status: SessionStatus.cooked),
      ...booking.skip(1),
    ];
    expect(build(cooked), isNot(first));
  });

  test('toString no dice nada de las clientas', () {
    final booking = buildBooking();
    final summary = agendaDaySummary(
      sessions: [booking[0]],
      requests: [request('a')],
      loaded: booking,
    );
    final printed = [
      summary.toString(),
      for (final item in summary.items) item.toString(),
    ].join(' ');
    expect(printed, isNot(contains('Giulia')));
    expect(printed, isNot(contains('Cliente')));
    expect(printed, isNot(contains('Città')));
  });
}

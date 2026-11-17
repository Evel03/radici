// Una sesión como la lee la app con la RLS: la fila de PostgREST con la
// ficha, sus restricciones y el pedido embebidos; las horas que salen de lo
// guardado (compra, llegada y fin); de dónde salen el nombre, el teléfono, la
// zona y el idioma; las alergias de la ficha y del pedido (también como
// llegan de la web: solo la nota); la dirección como se guarda, y que nada de
// eso se imprime.
import 'package:flutter_test/flutter_test.dart';
import 'package:radici/core/clock_time.dart';
import 'package:radici/core/rome_time.dart';
import 'package:radici/features/requests/domain/chef_request.dart';
import 'package:radici/features/sessions/domain/cooking_session.dart';

import '../../../support/request_fixtures.dart';
import '../../../support/session_fixtures.dart';

void main() {
  group('CookingSession.fromJson', () {
    test(
      'lee la fila con la ficha, sus restricciones y el pedido embebidos',
      () {
        final session = CookingSession.fromJson(sessionRow());

        expect(session.id, sessionId(1));
        expect(session.chefId, testChefId);
        expect(session.clientId, testClientId);
        expect(session.requestId, bookingRequestId);
        expect(session.date, CalendarDate(2026, 11, 25));
        // "10:00:00" de Postgres, como hora del día.
        expect(session.start, const ClockTime.hm(10, 0));
        expect(session.cookMinutes, 180);
        expect(session.shopMinutes, 45);
        expect(session.gapMinutes, 30);
        expect(session.portions, 20);
        expect(session.status, SessionStatus.confirmed);
        expect(session.serviceCents, 14000);
        expect(session.client.address, 'Via Gombito 12, 24129 Bergamo');
        expect(session.client.kitchenNotes, 'Forno a gas');
        expect(session.client.allergens, [Allergen.gluten]);
        expect(session.request?.id, bookingRequestId);
        expect(session.request?.status, RequestStatus.accepted);
        expect(session.request?.weeks, 4);
      },
    );

    test('todos los estados de la base, también shopping_done', () {
      for (final status in SessionStatus.values) {
        final session = CookingSession.fromJson(
          sessionRow(status: status.dbName),
        );
        expect(session.status, status);
      }
      expect(SessionStatus.shoppingDone.dbName, 'shopping_done');
    });

    test('una sesión sin pedido y una cancelada, con su motivo', () {
      final alone = CookingSession.fromJson(sessionRow(requestId: null));
      expect(alone.requestId, isNull);
      expect(alone.request, isNull);

      final cancelled = CookingSession.fromJson(
        sessionRow(status: 'cancelled'),
      );
      expect(cancelled.isLive, isFalse);
      expect(cancelled.cancelReason, 'client_cancelled');
      expect(cancelled.cancelledAt, DateTime.utc(2026, 11, 20, 10));
    });

    test('las restricciones de la ficha sin repetir, en el orden del enum, y sin los desconocidos', () {
      final session = CookingSession.fromJson(
        sessionRow(
          clientRestrictions: const [
            {'allergen': 'milk', 'diet': null},
            {'allergen': null, 'diet': 'vegan'},
            {'allergen': 'gluten', 'diet': null},
            {'allergen': 'unicorn', 'diet': null},
          ],
        ),
      );
      expect(session.client.allergens, [Allergen.gluten, Allergen.milk]);
      expect(session.client.diets, [Diet.vegan]);
    });

    test('una fila rota da FormatException', () {
      for (final broken in <Map<String, dynamic>>[
        {...sessionRow(), 'status': 'boiling'},
        {...sessionRow(), 'start_time': 'las diez'},
        {...sessionRow(), 'date': '2026-02-30'},
        {...sessionRow(), 'client': null},
        {...sessionRow(), 'cook_minutes': '180'},
      ]) {
        expect(
          () => CookingSession.fromJson(broken),
          throwsFormatException,
          reason: '$broken',
        );
      }
    });

    test('las columnas piden la ficha y el pedido con el nombre de su FK (requests también apunta a sessions)', () {
      expect(
        cookingSessionColumns,
        contains('client:clients!sessions_client_id_chef_id_fkey('),
      );
      expect(
        cookingSessionColumns,
        contains('request:requests!sessions_request_id_chef_id_fkey('),
      );
      expect(
        cookingSessionColumns,
        contains('restrictions:client_restrictions(allergen, diet)'),
      );
      expect(cookingSessionColumns, contains('address'));
      expect(cookingSessionColumns, contains(chefRequestColumns));
    });
  });

  group('las horas salen de la sesión', () {
    test(
      'compra desde la llegada menos la compra, hasta la llegada más la cocina',
      () {
        final times = buildSession().times;
        expect(SessionTimes.hhmm(times.shopStart), '09:15');
        expect(SessionTimes.hhmm(times.arrival), '10:00');
        expect(SessionTimes.hhmm(times.end), '13:00');
      },
    );

    test('con otros minutos guardados, otras horas (nada fijo)', () {
      final times = buildSession(
        start: const ClockTime.hm(11, 30),
        shopMinutes: 60,
        cookMinutes: 210,
        gapMinutes: 0,
      ).times;
      expect(SessionTimes.hhmm(times.shopStart), '10:30');
      expect(SessionTimes.hhmm(times.arrival), '11:30');
      expect(SessionTimes.hhmm(times.end), '15:00');
    });

    test('sin compra, la compra empieza a la llegada; cruzar la medianoche no rompe el texto', () {
      final noShopping = buildSession(shopMinutes: 0).times;
      expect(noShopping.shopStart, noShopping.arrival);

      final late = buildSession(
        start: const ClockTime.hm(22, 0),
        cookMinutes: 180,
      ).times;
      expect(SessionTimes.hhmm(late.end), '01:00');
      final early = buildSession(
        start: const ClockTime.hm(0, 30),
        shopMinutes: 45,
      ).times;
      expect(SessionTimes.hhmm(early.shopStart), '23:45');
    });
  });

  group('nombre, teléfono e idioma', () {
    test('del pedido de la reserva (su contacto), como en la bandeja', () {
      final session = CookingSession.fromJson(
        sessionRow(
          request: requestRow(
            id: bookingRequestId,
            status: 'accepted',
            locale: 'es',
            contact: {'name': 'Giulia R.', 'phone': '+39 333 000 1111'},
          ),
        ),
      );
      expect(session.displayName, 'Giulia R.');
      expect(session.firstName, 'Giulia');
      expect(session.phoneE164, '+393330001111');
      expect(session.locale, ClientLocale.es);
    });

    test('sin pedido, de la ficha, y en italiano', () {
      final session = CookingSession.fromJson(sessionRow(requestId: null));
      expect(session.displayName, 'Famiglia Rossi');
      expect(session.phoneE164, '+393339990000');
      expect(session.locale, ClientLocale.it);
    });

    test('la zona, como el nombre: la del pedido y, si falta, la de la ficha', () {
      final base = buildSession();
      // El pedido dice «Città Alta»; la ficha, otra.
      final session = base.copyWith(
        client: base.client.copyWith(zone: 'Borgo Palazzo'),
      );
      expect(session.zone, 'Città Alta');
      final withoutRequestZone = session.copyWith(
        request: session.request!.copyWith(
          client: session.request!.client.copyWith(zone: '  '),
        ),
      );
      expect(withoutRequestZone.zone, 'Borgo Palazzo');
      expect(session.copyWith(request: null).zone, 'Borgo Palazzo');
    });

    test('las personas: las del pedido y, si no las dice, las de la ficha', () {
      final base = buildSession();
      // El pedido: 2 adultos y 2 niños. La ficha, otra cuenta.
      final session = base.copyWith(
        client: base.client.copyWith(adults: 3, kids: 0),
      );
      expect(session.people, 4);
      final requestWithout = session.copyWith(
        request: session.request!.copyWith(adults: null, kids: null),
      );
      expect(requestWithout.people, 3);
      expect(session.copyWith(request: null).people, 3);
      expect(
        session
            .copyWith(
              request: null,
              client: session.client.copyWith(adults: null, kids: 1),
            )
            .people,
        1,
      );
      expect(
        session
            .copyWith(
              request: null,
              client: session.client.copyWith(adults: null, kids: null),
            )
            .people,
        isNull,
      );
    });
  });

  group('alergias', () {
    test('las del pedido y las de la ficha juntas, sin repetir', () {
      final session = buildSession(
        clientAllergens: const [Allergen.gluten],
        restrictions: const RequestRestrictions(
          allergens: [Allergen.milk, Allergen.gluten],
          diets: [Diet.vegetarian],
          note: '  Celiaca, anche le tracce  ',
        ),
      );
      expect(session.allergens, [Allergen.gluten, Allergen.milk]);
      expect(session.diets, [Diet.vegetarian]);
      expect(session.allergyNote, 'Celiaca, anche le tracce');
      expect(session.allergyAnswer, AllergyAnswer.listed);
    });

    test('la nota de contaminación cruzada con gluten en la ficha o en el pedido (SPEC §5.6)', () {
      expect(
        buildSession(clientAllergens: const [Allergen.gluten])
            .needsCrossContaminationNote,
        isTrue,
      );
      expect(
        buildSession(
          restrictions: const RequestRestrictions(allergens: [Allergen.gluten]),
        ).needsCrossContaminationNote,
        isTrue,
      );
      expect(
        buildSession(clientAllergens: const [Allergen.milk])
            .needsCrossContaminationNote,
        isFalse,
      );
    });

    test('como llegan de la web: solo la nota (sin alérgenos ni dietas) ya son alergias indicadas', () {
      final session = buildSession(restrictions: webRestrictions);
      expect(session.allergens, isEmpty);
      expect(session.diets, isEmpty);
      expect(session.allergyNote, 'Celiachia, noci');
      expect(session.allergyAnswer, AllergyAnswer.listed);
      // Sin gluten guardado no hay nota de contaminación cruzada: la nota
      // resaltada es la única señal de la celiaquía.
      expect(session.needsCrossContaminationNote, isFalse);
    });

    test('la fila como la guarda submit_public_request: listas vacías, la nota y sin client_restrictions', () {
      final session = CookingSession.fromJson(
        sessionRow(
          clientRestrictions: const [],
          request: requestRow(
            id: bookingRequestId,
            status: 'accepted',
            restrictions: const {
              'allergens': <String>[],
              'diets': <String>[],
              'note': 'Celiachia, noci',
            },
            noAllergies: false,
          ),
        ),
      );
      expect(session.allergens, isEmpty);
      expect(session.diets, isEmpty);
      expect(session.allergyNote, 'Celiachia, noci');
      expect(session.allergyAnswer, AllergyAnswer.listed);
    });

    test('sin ninguna: «nadie tiene» solo si el pedido lo confirmó; si no, sin datos', () {
      expect(buildSession(noAllergies: true).allergyAnswer, AllergyAnswer.none);
      expect(buildSession().allergyAnswer, AllergyAnswer.unknown);
      expect(
        buildSession(requestId: null).allergyAnswer,
        AllergyAnswer.unknown,
      );
    });

    test('una reserva a mano (pedido de la app, que no guarda alergias): sin datos, salvo que la ficha tenga restricciones', () {
      expect(
        buildSession(requestSource: RequestSource.app).allergyAnswer,
        AllergyAnswer.unknown,
      );
      expect(
        buildSession(
          requestSource: RequestSource.app,
          clientAllergens: const [Allergen.milk],
        ).allergyAnswer,
        AllergyAnswer.listed,
      );
    });
  });

  test('la dirección como se guarda: en una línea y sin espacios de más; vacía, null', () {
    expect(
      normalizeClientAddress('  Via Pignolo 5,\n  Bergamo  '),
      'Via Pignolo 5, Bergamo',
    );
    expect(normalizeClientAddress(' \n '), isNull);
    // Como newClient.address en el contrato chef-api §4.
    expect(maxClientAddressLength, 200);
  });

  test('qué se puede hacer según el estado', () {
    Set<SessionStatus> where(bool Function(CookingSession) test) => {
      for (final status in SessionStatus.values)
        if (test(buildSession(status: status))) status,
    };
    expect(where((s) => s.canMove), {
      SessionStatus.held,
      SessionStatus.confirmed,
    });
    expect(where((s) => s.canCancel), {
      SessionStatus.held,
      SessionStatus.confirmed,
      SessionStatus.shoppingDone,
    });
    expect(where((s) => !s.isLive), {SessionStatus.cancelled});
  });

  test('toString no imprime la dirección, las alergias ni las notas', () {
    final session = CookingSession.fromJson(
      sessionRow(
        request: requestRow(
          id: bookingRequestId,
          status: 'accepted',
          restrictions: const {
            'allergens': ['gluten'],
            'diets': <String>[],
            'note': 'Celiaca grave',
          },
        ),
      ),
    );
    final printed = [
      session.toString(),
      session.client.toString(),
      session.request.toString(),
    ].join(' ');
    for (final secret in [
      'Gombito',
      'Celiaca',
      'gluten',
      'Forno',
      'Rossi',
      '333',
      'Città',
    ]) {
      expect(printed, isNot(contains(secret)), reason: secret);
    }
    expect(session.toString(), 'CookingSession(${sessionId(1)}, confirmed)');
  });
}

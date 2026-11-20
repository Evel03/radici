// Lectura de una fila de `requests` (con el cliente embebido) tal como la
// devuelve PostgREST.
import 'package:flutter_test/flutter_test.dart';
import 'package:radici/core/rome_time.dart';
import 'package:radici/features/requests/domain/chef_request.dart';

import '../../../support/request_fixtures.dart';

void main() {
  test('lee todas las columnas del contrato', () {
    final request = ChefRequest.fromJson(requestRow());

    expect(request.id, 'req-1');
    expect(request.chefId, testChefId);
    expect(request.clientId, testClientId);
    expect(request.type, RequestType.week);
    expect(request.status, RequestStatus.newRequest);
    expect((request.adults, request.kids, request.days), (2, 2, 5));
    expect(request.meals, [Meal.dinner]);
    expect(request.preferredDate, CalendarDate(2026, 10, 21));
    expect(request.preferredSlot, PreferredSlot.morning);
    expect(request.locale, ClientLocale.it);
    expect(request.whatsappOptIn, isTrue);
    expect(request.source, RequestSource.web);
    expect(request.seenAt, isNull);
    expect(request.createdAt, DateTime.utc(2026, 10, 19, 9, 15, 30, 123, 456));
    expect(request.notes, 'Citofono: Rossi');
    expect(request.client.displayName, 'Giulia Rossi');
    expect(request.client.contactEmail, 'giulia@example.test');
    expect(request.client.contactPhone, '+39 333 123 4567');
    expect(request.client.zone, 'Città Alta');
  });

  test('respuesta a la pregunta de alergias (no_allergies): true, false o sin respuesta', () {
    expect(ChefRequest.fromJson(requestRow(restrictions: null, noAllergies: true)).noAllergies, isTrue);
    expect(ChefRequest.fromJson(requestRow(noAllergies: false)).noAllergies, isFalse);
    expect(ChefRequest.fromJson(requestRow()).noAllergies, isNull, reason: 'pedido anterior a la pregunta');
    expect(ChefRequest.fromJson(requestRow()..remove('no_allergies')).noAllergies, isNull);
  });

  test('restricciones: alérgenos en el orden del enum, dietas y nota', () {
    final restrictions = ChefRequest.fromJson(requestRow()).restrictions!;
    expect(restrictions.allergens, [Allergen.gluten, Allergen.milk]);
    expect(restrictions.diets, [Diet.vegetarian]);
    expect(restrictions.note, 'niente funghi');
    expect(restrictions.isEmpty, isFalse);
  });

  test('valores desconocidos en listas se descartan sin romper', () {
    final request = ChefRequest.fromJson(
      requestRow(
        restrictions: const {
          'allergens': ['milk', 'kryptonite', 'milk'],
          'diets': ['carnivore'],
        },
      )..['meals'] = ['brunch', 'lunch'],
    );
    expect(request.restrictions!.allergens, [Allergen.milk]);
    expect(request.restrictions!.diets, isEmpty);
    expect(request.restrictions!.note, '');
    expect(request.meals, [Meal.lunch]);
  });

  test('sin restricciones, sin fecha, sin franja y sin estimación', () {
    final request = ChefRequest.fromJson(
      requestRow(
        restrictions: null,
        preferredDate: null,
        preferredSlot: null,
        estimate: null,
      )..['meals'] = null,
    );
    expect(request.restrictions, isNull);
    expect(request.hasRestrictions, isFalse);
    expect(request.preferredDate, isNull);
    expect(request.preferredSlot, isNull);
    expect(request.estimate, isNull);
    expect(request.meals, isEmpty);
  });

  test('la estimación guardada (quote.ts + pricing) se lee en centavos', () {
    final estimate = ChefRequest.fromJson(requestRow()).estimate!;
    expect(estimate.portions, 20);
    expect(estimate.recipes, 3);
    expect(estimate.cookMinutes, 180);
    expect(estimate.serviceCents, 7800);
  });

  test('una estimación vieja con compra se sigue leyendo: la compra y el total se ignoran', () {
    // Como los pedidos de antes del 19/11/2026 (la compra ahora la hace el cliente).
    final row = requestRow();
    expect(row['estimate'], containsPair('groceriesEstCents', 6300));
    expect(row['estimate'], containsPair('preauthCents', 7245));
    expect(row['estimate'], containsPair('totalCents', 14100));
    expect(
      ChefRequest.fromJson(row).estimate,
      const RequestEstimate(portions: 20, recipes: 3, cookMinutes: 180, serviceCents: 7800),
    );
    // Si solo trae la compra, no queda nada que mostrar.
    expect(
      RequestEstimate.fromJson(const {
        'groceriesEstCents': 6300,
        'preauthCents': 7245,
        'totalCents': 14100,
      }).isEmpty,
      isTrue,
    );
  });

  test('la estimación de antes del precio por semana: servicio por hora, sin autoPrice, con precio', () {
    final estimate = ChefRequest.fromJson(requestRow()).estimate!;
    expect(estimate.isLegacy, isTrue);
    expect(estimate.hasAutoPrice, isTrue);
    expect(estimate.weeks, isNull);
    expect(ChefRequest.fromJson(requestRow()).weeks, 1);
  });

  test('semanas del pedido (requests.weeks); sin la columna, 1', () {
    expect(ChefRequest.fromJson(requestRow(weeks: 4)).weeks, 4);
    expect(ChefRequest.fromJson(requestRow()..remove('weeks')).weeks, 1);
    expect(chefRequestColumns, contains('weeks'));
  });

  test('la estimación con precio por semana: semanas, servicio por semana, total y ahorro, sin la compra que traía', () {
    final estimate = ChefRequest.fromJson(
      requestRow(
        weeks: 4,
        estimate: const {
          'weeks': 4,
          'portions': 20,
          'recipes': 3,
          'cookMinutes': 180,
          'groceriesEstCents': 6300,
          'preauthCents': 7245,
          'autoPrice': true,
          'weeklyServiceCents': 14000,
          'serviceCents': 56000,
          'savingsCents': 4000,
          'totalCents': 81200,
          'pricing': {
            'weeklyRateCents': 15000,
            'weeklyRateDiscountedCents': 14000,
            'weeklyDiscountMinWeeks': 4,
            'weeklyRateMaxPeople': 5,
          },
        },
      ),
    ).estimate!;
    expect(estimate.isLegacy, isFalse);
    expect(estimate.hasAutoPrice, isTrue);
    expect(estimate.weeks, 4);
    expect(estimate.weeklyServiceCents, 14000);
    expect(estimate.serviceCents, 56000);
    expect(estimate.savingsCents, 4000);
    expect(estimate.maxPeople, 5);
    expect(estimate.reason, isNull);
    // Las tarifas por semana con que se calculó (para otra cantidad de semanas).
    expect(estimate.weeklyRateCents, 15000);
    expect(estimate.weeklyRateDiscountedCents, 14000);
    expect(estimate.weeklyDiscountMinWeeks, 4);
    // groceriesEstCents, preauthCents y totalCents no dejan rastro.
    expect(
      estimate,
      const RequestEstimate(
        weeks: 4,
        portions: 20,
        recipes: 3,
        cookMinutes: 180,
        autoPrice: true,
        weeklyServiceCents: 14000,
        serviceCents: 56000,
        savingsCents: 4000,
        maxPeople: 5,
        weeklyRateCents: 15000,
        weeklyRateDiscountedCents: 14000,
        weeklyDiscountMinWeeks: 4,
      ),
    );
  });

  test('una estimación de antes no trae tarifas por semana', () {
    final legacy = ChefRequest.fromJson(requestRow()).estimate!;
    expect(legacy.weeklyRateCents, isNull);
    expect(legacy.weeklyRateDiscountedCents, isNull);
    expect(legacy.weeklyDiscountMinWeeks, isNull);
  });

  test('sin precio automático: el motivo, sin servicio', () {
    RequestEstimate read(String reason) => RequestEstimate.fromJson({
      'weeks': 1,
      'portions': 30,
      'recipes': 3,
      'cookMinutes': 210,
      'autoPrice': false,
      'reason': reason,
      'pricing': {'weeklyRateMaxPeople': 6},
    });
    final people = read('people');
    expect(people.hasAutoPrice, isFalse);
    expect(people.reason, NoAutoPriceReason.people);
    expect(people.maxPeople, 6);
    expect(people.serviceCents, isNull);
    expect(people.isEmpty, isFalse);
    expect(read('extra').reason, NoAutoPriceReason.extra);
    expect(read('otro').reason, isNull, reason: 'un motivo desconocido no rompe');
  });

  test('estimación parcial o con números raros: lo que falta queda en null', () {
    final estimate = RequestEstimate.fromJson(const {
      'serviceCents': 7800.0,
      'savingsCents': 78.5,
      'portions': '20',
    });
    expect(estimate.serviceCents, 7800);
    expect(estimate.savingsCents, isNull);
    expect(estimate.portions, isNull);
    expect(estimate.isEmpty, isFalse);
    expect(RequestEstimate.fromJson(const {}).isEmpty, isTrue);
  });

  test('idioma y origen desconocidos usan los valores por defecto', () {
    final request = ChefRequest.fromJson(
      requestRow(locale: 'fr', preferredSlot: 'night')..['source'] = 'fax',
    );
    expect(request.locale, ClientLocale.it);
    expect(request.source, RequestSource.app);
    expect(request.preferredSlot, isNull);
  });

  test('sin cliente embebido no rompe', () {
    final request = ChefRequest.fromJson(requestRow()..remove('client'));
    expect(request.client.displayName, '');
    expect(request.client.phoneE164, isNull);
  });

  group('contacto del pedido (requests.contact)', () {
    const snapshot = {
      'name': 'Marco B.',
      'zone': 'Borgo Palazzo',
      'phone': '+393409998877',
      'email': 'marco@example.test',
    };

    test('un pedido de la web muestra el contacto con el que llegó, no el de la ficha', () {
      // La ficha puede tener otros datos (Evelyn los corrigió, o es de otro pedido): cada pedido
      // muestra los suyos, y WhatsApp y llamar usan ese teléfono.
      final request = ChefRequest.fromJson(requestRow(contact: snapshot));
      expect(request.client.displayName, 'Marco B.');
      expect(request.client.zone, 'Borgo Palazzo');
      expect(request.client.contactPhone, '+393409998877');
      expect(request.client.phoneE164, '+393409998877');
      expect(request.client.contactEmail, 'marco@example.test');
      expect(request.client.status, ClientStatus.prospect, reason: 'el estado sale de la ficha');
    });

    test('lo que falta en la copia sale de la ficha; un pedido de la app no tiene copia', () {
      final partial = ChefRequest.fromJson(
        requestRow(contact: {'phone': '+393409998877', 'name': 5, 'zone': '  '}),
      );
      expect(partial.client.contactPhone, '+393409998877');
      expect(partial.client.displayName, 'Giulia Rossi');
      expect(partial.client.zone, 'Città Alta');
      expect(partial.client.contactEmail, 'giulia@example.test');

      final fromApp = ChefRequest.fromJson(requestRow());
      expect(fromApp.client.contactPhone, '+39 333 123 4567');
      expect(ChefRequest.fromJson(requestRow(contact: 'x')).client.displayName, 'Giulia Rossi');
    });

    test('sin ficha embebida alcanza la copia', () {
      final request = ChefRequest.fromJson(requestRow(contact: snapshot)..remove('client'));
      expect(request.client.displayName, 'Marco B.');
      expect(request.client.status, isNull);
    });
  });

  test('estado de la ficha del cliente; uno desconocido queda en null', () {
    expect(ChefRequest.fromJson(requestRow()).client.status, ClientStatus.prospect);
    expect(ChefRequest.fromJson(requestRow(clientStatus: 'trial')).client.status, ClientStatus.trial);
    expect(ChefRequest.fromJson(requestRow(clientStatus: 'vip')).client.status, isNull);
    expect(ChefRequest.fromJson(requestRow(clientStatus: null)).client.status, isNull);
  });

  test('seen_at con zona se lee como instante', () {
    final request = ChefRequest.fromJson(
      requestRow(seenAt: '2026-10-19T14:00:00+02:00'),
    );
    expect(request.seenAt, DateTime.utc(2026, 10, 19, 12));
  });

  group('reglas', () {
    test('nuevo = sin abrir, no rechazado y que no es una reserva', () {
      expect(buildRequest().isNew, isTrue);
      expect(buildRequest(seenAt: testNow).isNew, isFalse);
      expect(buildRequest(status: RequestStatus.rejected).isNew, isFalse);
      // Una reserva sin seen_at (como las del seed) no cuenta como nueva.
      expect(buildRequest(status: RequestStatus.accepted).isNew, isFalse);
    });

    test('el aviso en tiempo real, solo para un pedido sin abrir que llega de la web', () {
      expect(buildRequest().alertsOnArrival, isTrue);
      // Un pedido nuevo de la app no avisa, aunque cuente como nuevo en la bandeja.
      final fromApp = buildRequest(source: RequestSource.app);
      expect(fromApp.alertsOnArrival, isFalse);
      expect(fromApp.isNew, isTrue);
      // Una reserva no avisa: la de la app (una reserva a mano nace aceptada y
      // vista) ni la de la web, aunque no tenga seen_at.
      expect(
        buildRequest(
          source: RequestSource.app,
          status: RequestStatus.accepted,
          seenAt: testNow,
        ).alertsOnArrival,
        isFalse,
      );
      for (final source in RequestSource.values) {
        expect(
          buildRequest(source: source, status: RequestStatus.accepted).alertsOnArrival,
          isFalse,
          reason: '$source',
        );
      }
      expect(buildRequest(seenAt: testNow).alertsOnArrival, isFalse);
      expect(buildRequest(status: RequestStatus.rejected).alertsOnArrival, isFalse);
    });

    test('solo un pedido en estado new se puede rechazar', () {
      expect(buildRequest().canReject, isTrue);
      expect(buildRequest(seenAt: testNow).canReject, isTrue);
      for (final status in RequestStatus.values.skip(1)) {
        expect(buildRequest(status: status).canReject, isFalse, reason: '$status');
      }
    });

    test('«Confirmar reserva» solo desde un pedido nuevo que no es un cambio', () {
      expect(buildRequest().canConfirmBooking, isTrue);
      expect(buildRequest(seenAt: testNow).canConfirmBooking, isTrue);
      expect(buildRequest(type: RequestType.extra).canConfirmBooking, isTrue);
      expect(buildRequest(type: RequestType.change).canConfirmBooking, isFalse);
      for (final status in RequestStatus.values.skip(1)) {
        expect(buildRequest(status: status).canConfirmBooking, isFalse, reason: '$status');
      }
    });

    test('una reserva es un pedido aceptado', () {
      expect(buildRequest(status: RequestStatus.accepted).isBooking, isTrue);
      for (final status in RequestStatus.values.where((s) => s != RequestStatus.accepted)) {
        expect(buildRequest(status: status).isBooking, isFalse, reason: '$status');
      }
    });

    test('solo un prospecto se puede marcar como cliente', () {
      expect(buildRequest().canMarkClient, isTrue);
      for (final status in [...ClientStatus.values.skip(1), null]) {
        expect(buildRequest(clientStatus: status).canMarkClient, isFalse, reason: '$status');
      }
    });

    test('activos para la agenda: new y quoted (una reserva ya tiene sus sesiones)', () {
      final active = {
        for (final status in RequestStatus.values)
          if (buildRequest(status: status).isActive) status,
      };
      expect(active, {RequestStatus.newRequest, RequestStatus.quoted});
    });

    test('alergias: indicadas si hay restricciones; nadie solo si lo confirmó; si no, sin datos', () {
      const note = RequestRestrictions(note: 'Celiachia');
      expect(buildRequest(noAllergies: true).allergyAnswer, AllergyAnswer.none);
      expect(buildRequest(restrictions: note, noAllergies: false).allergyAnswer, AllergyAnswer.listed);
      // Pedidos anteriores (con o sin restricciones copiadas) y de la app.
      expect(buildRequest(restrictions: note).allergyAnswer, AllergyAnswer.listed);
      expect(buildRequest().allergyAnswer, AllergyAnswer.unknown);
      expect(buildRequest(restrictions: const RequestRestrictions()).allergyAnswer, AllergyAnswer.unknown);
      // Retiró el consentimiento de salud: la base borra la nota y el "hay alergias".
      expect(buildRequest(noAllergies: false).allergyAnswer, AllergyAnswer.unknown);
      // Si llegaran las dos cosas (la base no lo deja), se muestran las restricciones.
      expect(buildRequest(restrictions: note, noAllergies: true).allergyAnswer, AllergyAnswer.listed);
    });

    test('una dieta sola no responde sobre alergias: sin datos (la dieta igual se muestra)', () {
      const note = RequestRestrictions(note: 'Celiachia');
      const vegetarian = RequestRestrictions(diets: [Diet.vegetarian]);
      final dietOnly = buildRequest(restrictions: vegetarian);
      expect(dietOnly.allergyAnswer, AllergyAnswer.unknown);
      expect(dietOnly.answersAllergies, isFalse);
      // La lista de la bandeja igual marca que trae restricciones.
      expect(dietOnly.hasRestrictions, isTrue);
      // Con alérgenos o la nota, sí.
      expect(
        buildRequest(
          restrictions: const RequestRestrictions(
            diets: [Diet.vegan],
            note: 'Noci',
          ),
        ).allergyAnswer,
        AllergyAnswer.listed,
      );
      expect(
        buildRequest(
          restrictions: const RequestRestrictions(
            diets: [Diet.vegan],
            allergens: [Allergen.nuts],
          ),
        ).allergyAnswer,
        AllergyAnswer.listed,
      );
      // Una nota en blanco tampoco responde.
      expect(
        buildRequest(restrictions: const RequestRestrictions(note: '   '))
            .allergyAnswer,
        AllergyAnswer.unknown,
      );
      // «Nadie tiene» responde.
      expect(buildRequest(noAllergies: true).answersAllergies, isTrue);
      expect(buildRequest(restrictions: note).answersAllergies, isTrue);
      expect(buildRequest().answersAllergies, isFalse);
    });

    test('personas, teléfono normalizado y primer nombre', () {
      final request = buildRequest(name: '  Giulia   Maria Rossi ');
      expect(request.people, 4);
      expect(request.client.phoneE164, '+393331234567');
      expect(request.client.firstName, 'Giulia');
      expect(buildRequest(phone: '612 345 678').client.phoneE164, isNull);
      expect(buildRequest(phone: null).client.phoneE164, isNull);
    });

    test('toString no muestra datos personales ni de salud', () {
      final request = ChefRequest.fromJson(
        requestRow(contact: {'name': 'Giulia R.', 'phone': '+393331234567'}),
      );
      final text = '$request ${request.client} ${request.restrictions}';
      expect(text, isNot(contains('Giulia')));
      expect(text, isNot(contains('333')));
      expect(text, isNot(contains('example.test')));
      expect(text, isNot(contains('funghi')));
      expect(text, isNot(contains('milk')));
    });
  });
}

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
    expect(estimate.groceriesEstCents, 6300);
    expect(estimate.totalCents, 14100);
  });

  test('estimación parcial o con números raros: lo que falta queda en null', () {
    final estimate = RequestEstimate.fromJson(const {
      'totalCents': 14100.0,
      'serviceCents': 78.5,
      'portions': '20',
    });
    expect(estimate.totalCents, 14100);
    expect(estimate.serviceCents, isNull);
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
    test('nuevo = sin abrir y no rechazado', () {
      expect(buildRequest().isNew, isTrue);
      expect(buildRequest(seenAt: testNow).isNew, isFalse);
      expect(buildRequest(status: RequestStatus.rejected).isNew, isFalse);
    });

    test('solo un pedido en estado new se puede rechazar', () {
      expect(buildRequest().canReject, isTrue);
      expect(buildRequest(seenAt: testNow).canReject, isTrue);
      for (final status in RequestStatus.values.skip(1)) {
        expect(buildRequest(status: status).canReject, isFalse, reason: '$status');
      }
    });

    test('solo un prospecto se puede marcar como cliente', () {
      expect(buildRequest().canMarkClient, isTrue);
      for (final status in [...ClientStatus.values.skip(1), null]) {
        expect(buildRequest(clientStatus: status).canMarkClient, isFalse, reason: '$status');
      }
    });

    test('activos para la agenda: new, quoted y accepted', () {
      final active = {
        for (final status in RequestStatus.values)
          if (buildRequest(status: status).isActive) status,
      };
      expect(active, {
        RequestStatus.newRequest,
        RequestStatus.quoted,
        RequestStatus.accepted,
      });
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

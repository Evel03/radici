// Ficha de una clienta como la lee el directorio de «Nuova prenotazione»:
// solo nombre, teléfono, zona, adultos, niños, estado y el último pedido
// semanal (nada de dirección, email ni restricciones).
import 'package:flutter_test/flutter_test.dart';
import 'package:radici/features/clients/domain/chef_client.dart';
import 'package:radici/features/requests/domain/chef_request.dart';

import '../../../support/client_fixtures.dart';
import '../../../support/request_fixtures.dart';

void main() {
  group('fromJson', () {
    test('sin pedido semanal: los datos de la ficha', () {
      final client = ChefClient.fromJson(clientRow());
      expect(client.id, testClientId);
      expect(client.displayName, 'Chiara Rossi');
      expect(client.contactPhone, '+39 340 111 2233');
      expect(client.zone, 'Città Alta');
      expect(client.adults, 2);
      expect(client.kids, 1);
      expect(client.status, ClientStatus.active);
      expect(client.latestWeekly, isNull);
    });

    test('con el último pedido semanal embebido', () {
      final client = ChefClient.fromJson(
        clientRow(requests: [latestRequestRow()]),
      );
      final latest = client.latestWeekly!;
      expect(latest.type, RequestType.week);
      expect(latest.locale, ClientLocale.es);
      expect(latest.adults, 2);
      expect(latest.kids, 2);
      expect(latest.days, 4);
      // En el orden del enum, como requests.meals.
      expect(latest.meals, [Meal.lunch, Meal.dinner]);
      expect(latest.createdAt, DateTime.utc(2026, 11, 15, 9, 30));
    });

    test('un idioma desconocido se lee como it; una comida desconocida no está', () {
      final latest = ChefClient.fromJson(
        clientRow(
          requests: [
            latestRequestRow(locale: 'fr', meals: ['brunch', 'dinner']),
          ],
        ),
      ).latestWeekly!;
      expect(latest.locale, ClientLocale.it);
      expect(latest.meals, [Meal.dinner]);
    });

    test('un pedido embebido roto se ignora: vale la ficha', () {
      for (final broken in [
        latestRequestRow(type: 'brunch'),
        latestRequestRow(createdAt: 'ayer'),
        latestRequestRow(createdAt: null),
      ]) {
        expect(
          ChefClient.fromJson(clientRow(requests: [broken])).latestWeekly,
          isNull,
        );
      }
      expect(ChefClient.fromJson(clientRow(requests: null)).latestWeekly, isNull);
    });

    test('sin teléfono ni zona; un estado desconocido queda en null', () {
      final client = ChefClient.fromJson(
        clientRow(phone: null, zone: '  ', status: 'vip'),
      );
      expect(client.contactPhone, isNull);
      expect(client.zone, isNull);
      expect(client.status, isNull);
      expect(client.phoneE164, isNull);
    });

    test('sin id o sin nombre: FormatException', () {
      expect(
        () => ChefClient.fromJson(clientRow(name: null)),
        throwsFormatException,
      );
      expect(
        () => ChefClient.fromJson(clientRow(name: '   ')),
        throwsFormatException,
      );
      expect(
        () => ChefClient.fromJson({...clientRow(), 'id': null}),
        throwsFormatException,
      );
    });
  });

  group('phoneE164', () {
    test('como lo escribió, normalizado', () {
      expect(buildClient(phone: '333 123 4567').phoneE164, '+393331234567');
      expect(buildClient(phone: '612 345 678').phoneE164, isNull);
      expect(buildClient(phone: null).phoneE164, isNull);
    });

    test('guardado entre marcas invisibles (pegado de Contactos)', () {
      expect(
        buildClient(phone: '\u202a+39 333 123 4567\u202c').phoneE164,
        '+393331234567',
      );
      expect(
        buildClient(phone: '\u200e+39 333 123 4567').phoneE164,
        '+393331234567',
      );
    });
  });

  test('isProspect y firstName', () {
    expect(buildClient(status: ClientStatus.prospect).isProspect, isTrue);
    expect(buildClient(status: ClientStatus.trial).isProspect, isFalse);
    expect(buildClient(status: null).isProspect, isFalse);
    expect(buildClient(name: '  Giulia   Rossi ').firstName, 'Giulia');
  });

  test('toString sin el nombre ni el teléfono', () {
    final text = buildClient(
      name: 'Chiara Rossi',
      phone: '+39 340 111 2233',
      latestWeekly: buildLatestWeekly(),
    ).toString();
    expect(text, isNot(contains('Chiara')));
    expect(text, isNot(contains('340')));
    expect(text, contains(testClientId));
  });
}

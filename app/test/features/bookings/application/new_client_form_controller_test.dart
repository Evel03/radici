// Borrador de «Nuova cliente»: vive mientras alguien lo escuche (el elegir),
// lo que dice la barra de abajo, el teléfono (también pegado del iPhone) con
// su error recién después de «Continua», los textos que pasan el límite del
// servidor, el hogar y el idioma (una sola fuente con la hoja) y el teléfono
// repetido contra el directorio.
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:radici/features/auth/application/session_controller.dart';
import 'package:radici/features/auth/data/account_repository.dart';
import 'package:radici/features/auth/data/auth_repository.dart';
import 'package:radici/features/bookings/application/new_client_form_controller.dart';
import 'package:radici/features/bookings/domain/booking.dart';
import 'package:radici/features/clients/application/client_directory_controller.dart';
import 'package:radici/features/clients/data/clients_repository.dart';
import 'package:radici/features/requests/domain/chef_request.dart';

import '../../../support/client_fixtures.dart';
import '../../../support/fakes.dart';
import '../../../support/pump_app.dart';
import '../../../support/request_fixtures.dart';

void main() {
  late FakeClientsRepository clients;
  late ProviderContainer container;

  NewClientForm form() => container.read(newClientFormProvider);
  NewClientFormController controller() =>
      container.read(newClientFormProvider.notifier);

  setUp(() async {
    clients = FakeClientsRepository([
      buildClient(id: 'c-chiara', name: 'Chiara Rossi', phone: '333 123 4567'),
    ]);
    container = ProviderContainer.test(
      retry: noRetry,
      overrides: [
        authRepositoryProvider.overrideWithValue(
          FakeAuthRepository(user: chefUser),
        ),
        accountRepositoryProvider.overrideWithValue(
          FakeAccountRepository(chefAccountData),
        ),
        clientsRepositoryProvider.overrideWithValue(clients),
      ],
    );
    // Como en la app: el formulario se abre con la sesión ya leída.
    container.listen(currentChefProvider, (_, _) {});
    await pumpEventQueue();
  });

  group('vida del borrador', () {
    test('sobrevive mientras alguien lo escucha (el elegir); sin oyentes, se descarta', () async {
      final picker = container.listen(newClientFormProvider, (_, _) {});
      controller()
        ..setName('Giulia Rossi')
        ..setPhone('333 999 0000');
      // El formulario se cierra y se vuelve a abrir: el elegir sigue en la pila.
      await pumpEventQueue();
      expect(form().name, 'Giulia Rossi');
      expect(form().phoneText, '333 999 0000');

      picker.close();
      await pumpEventQueue();
      expect(form().isEmpty, isTrue, reason: 'sin el elegir, arranca vacío');
    });

    test('prefillIfEmpty: con el borrador vacío prellena desde la búsqueda; con algo escrito, no lo toca', () {
      container.listen(newClientFormProvider, (_, _) {});
      controller().prefillIfEmpty('Giulia');
      expect(form().name, 'Giulia');
      expect(form().phoneText, isEmpty);

      controller().prefillIfEmpty('333 12');
      expect(form().name, 'Giulia', reason: 'ya tenía algo');
      expect(form().phoneText, isEmpty);

      container.invalidate(newClientFormProvider);
      controller().prefillIfEmpty('333 12');
      expect(form().phoneText, '333 12');
      expect(form().name, isEmpty);
    });

    test('tocar los contadores o el idioma también cuenta como escrito', () {
      container.listen(newClientFormProvider, (_, _) {});
      controller().stepAdults(1);
      expect(form().isEmpty, isFalse);
      controller().prefillIfEmpty('Giulia');
      expect(form().name, isEmpty);
    });
  });

  group('lo que dice la barra', () {
    test('sin nombre: no se puede continuar y la barra lo dice', () {
      container.listen(newClientFormProvider, (_, _) {});
      expect(form().canContinue, isFalse);
      expect(form().blocker, NewClientBlocker.nameMissing);
      controller().setName('   ');
      expect(form().canContinue, isFalse);
      controller().setName(' Giulia ');
      expect(form().canContinue, isTrue);
      expect(form().blocker, isNull);
      expect(form().cleanName, 'Giulia');
      expect(controller().submit(), isTrue);
    });

    test('el error del teléfono aparece recién después de «Continua» y se actualiza al escribir', () {
      container.listen(newClientFormProvider, (_, _) {});
      controller()
        ..setName('Giulia')
        ..setPhone('612 345 678');
      expect(form().phoneInvalid, isTrue);
      expect(form().showPhoneError, isFalse);
      expect(form().blocker, isNull, reason: 'antes del primer intento');

      expect(controller().submit(), isFalse);
      expect(form().showPhoneError, isTrue);
      expect(form().blocker, NewClientBlocker.phoneInvalid);

      controller().setPhone('+34 612 345 678');
      expect(form().showPhoneError, isFalse);
      expect(form().blocker, isNull);
      expect(controller().submit(), isTrue);
      expect(form().phoneE164, '+34612345678');
    });

    test('sin teléfono se puede seguir: es opcional', () {
      container.listen(newClientFormProvider, (_, _) {});
      controller().setName('Giulia');
      expect(controller().submit(), isTrue);
      expect(form().toNewClientData(), const NewClientData(name: 'Giulia'));
    });

    test('un nombre de 80 grafemas con emojis pasa el límite del servidor (80 en UTF-16)', () {
      container.listen(newClientFormProvider, (_, _) {});
      // 40 letras y 40 emojis: 80 grafemas, 120 unidades UTF-16.
      final name = '${'a' * 40}${'\u{1F600}' * 40}';
      controller().setName(name);
      expect(form().tooLong, {NewClientField.name});
      expect(form().blocker, isNull, reason: 'antes del primer intento');
      expect(controller().submit(), isFalse);
      expect(form().tooLong, {NewClientField.name});
      expect(form().blocker, NewClientBlocker.tooLong);

      controller().setName('a' * 80);
      expect(form().tooLong, isEmpty);
      expect(controller().submit(), isTrue);

      controller().setZone('z' * 81);
      expect(form().tooLong, {NewClientField.zone});
      controller()
        ..setZone('Città Alta')
        ..setAddress('x' * 201);
      expect(form().tooLong, {NewClientField.address});
    });
  });

  group('datos de la ficha nueva', () {
    test('el teléfono en E.164, también pegado entre marcas invisibles; la dirección y la zona limpias', () {
      container.listen(newClientFormProvider, (_, _) {});
      controller()
        ..setName('  Giulia   Rossi ')
        ..setPhone('\u202a+39 333 123 4567\u202c')
        ..setZone('\u202aCittà  Alta\u202c')
        ..setAddress('  Via   Gombito 12,\n Bergamo ');
      expect(form().phoneE164, '+393331234567');
      expect(
        form().toNewClientData(),
        const NewClientData(
          name: 'Giulia Rossi',
          phone: '+393331234567',
          zone: 'Città Alta',
          address: 'Via Gombito 12, Bergamo',
        ),
      );
      controller().setPhone('\u200e333 123 4567');
      expect(form().phoneE164, '+393331234567');
    });

    test('adultos y niños con los límites; setHousehold guarda días y comidas y marca householdTouched', () {
      container.listen(newClientFormProvider, (_, _) {});
      expect(form().household, const BookingHousehold(adults: 2, kids: 2, days: 5, meals: [Meal.dinner]));
      expect(form().householdTouched, isFalse);
      controller()
        ..stepKids(-1)
        ..stepKids(-1)
        ..stepKids(-1);
      expect(form().household.kids, 0);
      controller()
        ..stepAdults(-1)
        ..stepAdults(-1);
      expect(form().household.adults, 1, reason: 'al menos una persona');
      expect(form().householdTouched, isTrue);

      container.invalidate(newClientFormProvider);
      controller().setHousehold(
        const BookingHousehold(adults: 3, kids: 0, days: 4, meals: [Meal.lunch]),
      );
      expect(form().household.days, 4);
      expect(form().household.meals, [Meal.lunch]);
      expect(form().householdTouched, isTrue);
    });

    test('setLocale marca localeTouched; empieza en italiano', () {
      container.listen(newClientFormProvider, (_, _) {});
      expect(form().locale, ClientLocale.it);
      expect(form().localeTouched, isFalse);
      controller().setLocale(ClientLocale.es);
      expect(form().locale, ClientLocale.es);
      expect(form().localeTouched, isTrue);
    });

    test('toString sin nada de la clienta', () {
      container.listen(newClientFormProvider, (_, _) {});
      controller()
        ..setName('Giulia Rossi')
        ..setPhone('333 123 4567');
      expect(form().toString(), isNot(contains('Giulia')));
      expect(form().toString(), isNot(contains('333')));
    });
  });

  group('teléfono repetido', () {
    PhoneMatch match() => container.read(newClientPhoneMatchProvider);

    test('la ficha con ese número, aunque esté guardado de otra forma', () async {
      container.listen(newClientPhoneMatchProvider, (_, _) {});
      expect(match(), isA<NoPhoneMatch>(), reason: 'sin teléfono');
      controller().setPhone('+39 333 1234567');
      await pumpEventQueue();
      final found = match();
      expect(found, isA<PhoneMatchFound>());
      expect((found as PhoneMatchFound).client.id, 'c-chiara');

      controller().setPhone('+39 333 7654321');
      expect(match(), isA<NoPhoneMatch>());
      controller().setPhone('612');
      expect(match(), isA<NoPhoneMatch>(), reason: 'un teléfono inválido no busca');
    });

    test('con una ficha y su prospecto gemelo, la ficha', () async {
      clients.clients.add(
        buildClient(
          id: 'a-twin',
          name: 'Chiara Rossi',
          phone: '+39 333 123 4567',
          status: ClientStatus.prospect,
          latestWeekly: buildLatestWeekly(createdAt: DateTime.utc(2026, 11, 16)),
        ),
      );
      container.listen(newClientPhoneMatchProvider, (_, _) {});
      controller().setPhone('333 123 4567');
      await pumpEventQueue();
      expect((match() as PhoneMatchFound).client.id, 'c-chiara');
    });

    test('mientras el directorio carga, «checking»; cuando llega, la coincidencia', () async {
      clients.pendingFetch = Completer<void>();
      container.listen(newClientPhoneMatchProvider, (_, _) {});
      controller().setPhone('333 123 4567');
      await pumpEventQueue();
      expect(match(), isA<PhoneMatchChecking>());

      clients.pendingFetch!.complete();
      await pumpEventQueue();
      expect(match(), isA<PhoneMatchFound>());
    });

    test('si el directorio falla, «unchecked»; reintentarlo lo vuelve a leer', () async {
      clients.fetchFailure = const ClientsFailure(ClientsFailureKind.unavailable);
      container.listen(newClientPhoneMatchProvider, (_, _) {});
      controller().setPhone('333 123 4567');
      await pumpEventQueue();
      expect(match(), isA<PhoneMatchUnchecked>());

      clients.fetchFailure = null;
      container.invalidate(clientDirectoryProvider);
      await pumpEventQueue();
      expect(match(), isA<PhoneMatchFound>());
    });
  });
}

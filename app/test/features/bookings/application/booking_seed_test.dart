// Lo inicial de la hoja «Conferma prenotazione» según de dónde se abre: un
// pedido (como el PR 5), una ficha existente (con y sin último pedido
// semanal, nunca el de un evento), una ficha elegida desde «Nuova cliente»
// (lo que Evelyn tocó en el formulario va al pedido, no a la ficha) o una
// ficha nueva (el borrador). null en cada caso de «no está». "Hoy": lunes
// 19/10/2026.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:radici/core/clock.dart';
import 'package:radici/core/rome_time.dart';
import 'package:radici/features/auth/application/session_controller.dart';
import 'package:radici/features/auth/data/account_repository.dart';
import 'package:radici/features/auth/data/auth_repository.dart';
import 'package:radici/features/bookings/application/booking_seed.dart';
import 'package:radici/features/bookings/application/new_client_form_controller.dart';
import 'package:radici/features/bookings/data/bookings_repository.dart';
import 'package:radici/features/bookings/domain/booking.dart';
import 'package:radici/features/bookings/domain/booking_draft.dart';
import 'package:radici/features/clients/data/clients_repository.dart';
import 'package:radici/features/requests/data/chef_requests_repository.dart';
import 'package:radici/features/requests/domain/chef_request.dart';

import '../../../support/client_fixtures.dart';
import '../../../support/fakes.dart';
import '../../../support/pump_app.dart';
import '../../../support/request_fixtures.dart';

void main() {
  final today = CalendarDate(2026, 10, 19);
  final tomorrow = today.addDays(1);
  final monday = CalendarDate(2026, 11, 23);

  late FakeChefRequestsRepository requests;
  late FakeClientsRepository clients;
  late ProviderContainer container;

  final chiara = buildClient(
    id: 'c-chiara',
    name: 'Chiara Rossi',
    phone: '340 111 2233',
    zone: 'Loreto',
    adults: 1,
    kids: 0,
    latestWeekly: buildLatestWeekly(
      locale: ClientLocale.es,
      adults: 3,
      kids: 1,
      days: 4,
      meals: const [Meal.lunch, Meal.dinner],
    ),
  );

  setUp(() async {
    requests = FakeChefRequestsRepository(const []);
    clients = FakeClientsRepository([chiara]);
    container = ProviderContainer.test(
      retry: noRetry,
      overrides: [
        authRepositoryProvider.overrideWithValue(
          FakeAuthRepository(user: chefUser),
        ),
        accountRepositoryProvider.overrideWithValue(
          FakeAccountRepository(chefAccountData),
        ),
        chefRequestsRepositoryProvider.overrideWithValue(requests),
        clientsRepositoryProvider.overrideWithValue(clients),
        clockProvider.overrideWithValue(() => testNow),
      ],
    );
    // Como en la app: la hoja se abre con la sesión de la cocinera ya leída.
    container.listen(currentChefProvider, (_, _) {});
    await pumpEventQueue();
  });

  Future<BookingSeed?> seedOf(BookingSource source) async {
    container.listen(bookingSeedProvider(source), (_, _) {});
    return container.read(bookingSeedProvider(source).future);
  }

  group('desde un pedido (como el PR 5)', () {
    test('las semanas del pedido desde la preferida, los minutos, porciones, compra y precio de la estimación', () async {
      requests.requests['req-1'] = buildRequest(
        weeks: 4,
        preferredDate: monday,
        estimate: fourWeeksEstimate.copyWith(cookMinutes: 420),
        locale: ClientLocale.es,
      );
      final seed = (await seedOf(const BookingSource.request('req-1')))!;
      expect(seed.kind, BookingSourceKind.request);
      expect(seed.request?.id, 'req-1');
      expect(seed.clientId, isNull);
      expect(seed.newClient, isNull);
      expect(seed.household, isNull);
      expect(seed.locale, ClientLocale.es);
      expect(seed.today, today);
      expect(seed.maxWeeks, 8);
      expect(seed.dates, weeklyDates(monday, 4));
      expect(seed.start, isNull);
      expect(seed.startEdited, isFalse);
      expect(seed.cookMinutes, 300, reason: 'con el tope de la hoja');
      expect(seed.cookFollowsHousehold, isFalse);
      expect(seed.priceRule.suggestedFor(4), 56000);
      expect(seed.priceRule.suggestedFor(2), 30000);
      expect(seed.portions, 20);
      expect(seed.groceriesEstCents, 6300);
      expect(seed.initialFailure, isNull);
      expect(seed.party.displayName, 'Giulia Rossi');
      expect(seed.party.firstName, 'Giulia');
      expect(seed.party.phoneE164, '+393331234567');
    });

    test('un pedido que ya es una reserva: la falla de entrada, sin preguntarle al servidor', () async {
      requests.requests['req-1'] = buildRequest(status: RequestStatus.accepted);
      final seed = (await seedOf(const BookingSource.request('req-1')))!;
      expect(seed.initialFailure?.kind, BookingFailureKind.requestNotNew);
      expect(seed.initialFailure?.requestStatus, 'accepted');
    });

    test('un pedido que no está: null', () async {
      expect(await seedOf(const BookingSource.request('nope')), isNull);
    });
  });

  group('una ficha existente', () {
    test('el hogar y el idioma de su último pedido semanal; 4 semanas desde mañana; sin precio', () async {
      final seed = (await seedOf(const BookingSource.client('c-chiara')))!;
      expect(seed.kind, BookingSourceKind.manual);
      expect(seed.clientId, 'c-chiara');
      expect(seed.request, isNull);
      expect(seed.newClient, isNull);
      const household = BookingHousehold(
        adults: 3,
        kids: 1,
        days: 4,
        meals: [Meal.lunch, Meal.dinner],
      );
      expect(seed.household, household);
      expect(seed.locale, ClientLocale.es);
      expect(seed.maxWeeks, 8);
      expect(seed.dates, weeklyDates(tomorrow, 4));
      final estimate = manualBookingEstimate(household);
      expect(seed.cookMinutes, estimate.cookMinutes);
      expect(seed.portions, estimate.portions);
      expect(seed.groceriesEstCents, estimate.groceriesEstCents);
      expect(seed.cookFollowsHousehold, isTrue);
      expect(seed.priceRule.suggestedFor(4), isNull);
      expect(seed.party.displayName, 'Chiara Rossi');
      expect(seed.party.phoneText, '340 111 2233');
      expect(seed.party.phoneE164, '+393401112233');
      expect(seed.party.zone, 'Loreto');
    });

    test('sin pedido semanal: adultos y niños de la ficha, 5 días y cena, en italiano', () async {
      clients.clients.add(
        buildClient(id: 'c-anna', name: 'Anna Verdi', adults: 2, kids: 1),
      );
      final seed = (await seedOf(const BookingSource.client('c-anna')))!;
      expect(
        seed.household,
        const BookingHousehold(adults: 2, kids: 1, days: 5, meals: [Meal.dinner]),
      );
      expect(seed.locale, ClientLocale.it);
    });

    test('nunca el hogar de un evento (el caso Bonetti)', () async {
      clients.clients.add(
        buildClient(
          id: 'c-bonetti',
          name: 'Famiglia Bonetti',
          adults: 2,
          kids: 1,
          latestWeekly: buildLatestWeekly(
            type: RequestType.extra,
            locale: ClientLocale.en,
            adults: 10,
            kids: 6,
            days: 1,
          ),
        ),
      );
      final seed = (await seedOf(const BookingSource.client('c-bonetti')))!;
      expect(
        seed.household,
        const BookingHousehold(adults: 2, kids: 1, days: 5, meals: [Meal.dinner]),
      );
      expect(seed.locale, ClientLocale.it);
    });

    test('una ficha que no está: null', () async {
      expect(await seedOf(const BookingSource.client('nope')), isNull);
    });
  });

  group('una ficha elegida desde «Nuova cliente» (teléfono repetido)', () {
    test('los adultos, niños e idioma que Evelyn tocó en el formulario; la ficha no cambia', () async {
      container.listen(newClientFormProvider, (_, _) {});
      container.read(newClientFormProvider.notifier)
        ..stepAdults(1) // 3 adultos
        ..stepKids(-1) // 1 niño
        ..setLocale(ClientLocale.en);
      final seed = (await seedOf(
        const BookingSource.client('c-chiara', fromForm: true),
      ))!;
      // Días y comidas siguen siendo los de su último pedido semanal.
      expect(
        seed.household,
        const BookingHousehold(adults: 3, kids: 1, days: 4, meals: [Meal.lunch, Meal.dinner]),
      );
      expect(seed.locale, ClientLocale.en);
      expect(clients.clients.single, chiara, reason: 'nada toca la ficha');
    });

    test('sin tocarlos (o sin borrador, si se recargó la página): los de la ficha', () async {
      final seed = (await seedOf(
        const BookingSource.client('c-chiara', fromForm: true),
      ))!;
      expect(seed.household?.adults, 3);
      expect(seed.locale, ClientLocale.es);
    });
  });

  group('una ficha nueva', () {
    test('los datos y el hogar (con días y comidas) del borrador', () async {
      container.listen(newClientFormProvider, (_, _) {});
      container.read(newClientFormProvider.notifier)
        ..setName(' Giulia  Rossi ')
        ..setPhone('333 123 4567')
        ..setZone('Città Alta')
        ..setAddress('Via Gombito 12')
        ..setHousehold(
          const BookingHousehold(adults: 2, kids: 0, days: 3, meals: [Meal.lunch]),
        )
        ..setLocale(ClientLocale.es);
      final seed = (await seedOf(const BookingSource.newClient()))!;
      expect(seed.kind, BookingSourceKind.manual);
      expect(
        seed.newClient,
        const NewClientData(
          name: 'Giulia Rossi',
          phone: '+393331234567',
          zone: 'Città Alta',
          address: 'Via Gombito 12',
        ),
      );
      expect(seed.clientId, isNull);
      expect(
        seed.household,
        const BookingHousehold(adults: 2, kids: 0, days: 3, meals: [Meal.lunch]),
      );
      expect(seed.locale, ClientLocale.es);
      expect(seed.dates, weeklyDates(tomorrow, 4));
      expect(seed.priceRule.suggestedFor(4), isNull);
      expect(seed.party.displayName, 'Giulia Rossi');
      expect(seed.party.phoneE164, '+393331234567');
      expect(seed.party.zone, 'Città Alta');
    });

    test('sin nombre, con un teléfono inválido o con un texto demasiado largo: null', () async {
      container.listen(newClientFormProvider, (_, _) {});
      final form = container.read(newClientFormProvider.notifier);
      expect(await seedOf(const BookingSource.newClient()), isNull);

      form
        ..setName('Giulia')
        ..setPhone('612');
      expect(await seedOf(const BookingSource.newClient()), isNull);

      form
        ..setPhone('')
        ..setName('a' * 81);
      expect(await seedOf(const BookingSource.newClient()), isNull);
    });
  });

  test('la fuente compara por valor y toString lleva solo ids', () {
    expect(
      const BookingSource.client('x', fromForm: true),
      const BookingSource.client('x', fromForm: true),
    );
    expect(
      const BookingSource.client('x'),
      isNot(const BookingSource.client('x', fromForm: true)),
    );
    expect(const BookingSource.request('r').kind, BookingSourceKind.request);
    expect(const BookingSource.newClient().kind, BookingSourceKind.manual);
    expect(const BookingSource.client('x').toString(), contains('x'));
  });
}

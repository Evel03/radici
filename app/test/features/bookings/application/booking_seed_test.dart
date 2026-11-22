// Lo inicial de la hoja «Conferma prenotazione» según de dónde se abre: un
// pedido (como el PR 5), una ficha existente (con y sin último pedido
// semanal, nunca el de un evento), una ficha elegida desde «Nuova cliente»
// (lo que Evelyn tocó en el formulario va al pedido, no a la ficha), una
// ficha nueva (el borrador) o «Rinnova» (la reserva de una sesión, con el
// destinatario de la ficha). null en cada caso de «no está». "Hoy": lunes
// 19/10/2026.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:radici/core/clock.dart';
import 'package:radici/core/clock_time.dart';
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
import 'package:radici/features/sessions/data/sessions_repository.dart';
import 'package:radici/features/sessions/domain/cooking_session.dart';

import '../../../support/client_fixtures.dart';
import '../../../support/fakes.dart';
import '../../../support/pump_app.dart';
import '../../../support/request_fixtures.dart';
import '../../../support/session_fixtures.dart';

void main() {
  final today = CalendarDate(2026, 10, 19);
  final tomorrow = today.addDays(1);
  final monday = CalendarDate(2026, 11, 23);

  late FakeChefRequestsRepository requests;
  late FakeClientsRepository clients;
  late FakeSessionsRepository sessions;
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
    sessions = FakeSessionsRepository();
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
        sessionsRepositoryProvider.overrideWithValue(sessions),
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
    test('las semanas del pedido desde la preferida, los minutos, porciones y precio de la estimación', () async {
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
      expect(seed.cookMinutes, 360, reason: 'con el tope de la hoja');
      expect(seed.cookFollowsHousehold, isFalse);
      // El precio no se prellena (22/11/2026): la tarifa es solo referencia.
      expect(seed.priceRule.suggestedFor(4), isNull);
      expect(seed.referenceRule.suggestedFor(4), 56000);
      expect(seed.referenceRule.suggestedFor(2), 30000);
      expect(seed.portions, 20);
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

  group('«Rinnova» (la reserva de una sesión)', () {
    // La reserva de prueba: miércoles 25/11, 2/12, 9/12 y 16/12 a las 10:00,
    // 180 min, 4 × 140 €, con la estimación de la web.
    void save(List<CookingSession> booking) {
      for (final session in booking) {
        sessions.sessions[session.id] = session;
      }
    }

    test('las semanas, el precio, la hora y los minutos de la reserva; el destinatario sale de la ficha', () async {
      // El pedido llegó con otro nombre y otro teléfono (su contacto de la
      // web); la ficha no cambió.
      save([
        for (final session in buildBooking(
          locale: ClientLocale.es,
          estimate: fourWeeksEstimate,
        ))
          session.copyWith(
            request: session.request!.copyWith(
              client: session.request!.client.copyWith(
                displayName: 'Giuly Bianchi',
                contactPhone: '+34 612 345 678',
              ),
            ),
          ),
      ]);
      final seed = (await seedOf(BookingSource.renewal(sessionId(4))))!;
      expect(seed.kind, BookingSourceKind.renewal);
      expect(seed.clientId, testClientId);
      expect(seed.request, isNull);
      expect(seed.newClient, isNull);
      expect(seed.clientStatus, ClientStatus.trial);
      expect(
        seed.household,
        const BookingHousehold(adults: 2, kids: 2, days: 5, meals: [Meal.dinner]),
      );
      expect(seed.locale, ClientLocale.es);
      expect(seed.maxWeeks, 8);
      expect(seed.today, today);
      expect(seed.dates, weeklyDates(CalendarDate(2026, 12, 23), 4));
      expect(seed.start, const ClockTime.hm(10, 0));
      expect(seed.startEdited, isTrue, reason: 'el primer dryRun lleva la hora');
      expect(seed.cookMinutes, 180);
      expect(seed.cookFollowsHousehold, isFalse);
      expect(seed.priceRule.suggestedFor(4), 56000);
      expect(seed.priceRule.suggestedFor(2), 30000);
      expect(seed.portions, 20);
      expect(seed.renewedFrom, CalendarDate(2026, 12, 16));
      expect(seed.renewedRequestId, bookingRequestId);
      expect(seed.lastDiffers, isFalse);
      expect(seed.otherRequestPhone, '+34 612 345 678');
      expect(seed.party.displayName, 'Giulia Rossi');
      expect(seed.party.phoneText, '+39 333 123 4567');
      expect(seed.party.phoneE164, '+393331234567');
      expect(seed.party.zone, 'Città Alta');
      expect(seed.initialFailure, isNull);
    });

    test('con la última semana movida, avisa que no todas tenían el mismo día y hora', () async {
      final booking = buildBooking();
      booking[3] = booking[3].copyWith(
        date: CalendarDate(2026, 12, 18),
        start: const ClockTime.hm(11, 0),
      );
      save(booking);
      final seed = (await seedOf(BookingSource.renewal(sessionId(4))))!;
      expect(seed.lastDiffers, isTrue);
      expect(seed.dates.first, CalendarDate(2026, 12, 25));
      expect(seed.start, const ClockTime.hm(11, 0));
      expect(seed.otherRequestPhone, isNull);
    });

    test('desde cualquier semana de la reserva, la última viva manda; sin la estimación de la web, el precio de otras semanas queda vacío', () async {
      save(buildBooking());
      final seed = (await seedOf(BookingSource.renewal(sessionId(2))))!;
      expect(seed.renewedFrom, CalendarDate(2026, 12, 16));
      expect(seed.priceRule.suggestedFor(4), 56000);
      expect(seed.priceRule.suggestedFor(2), isNull);
    });

    test('una sesión que no está, o una que no se puede renovar: null', () async {
      expect(await seedOf(BookingSource.renewal(sessionId(9))), isNull);
      save([buildSession(n: 5, requestId: 'extra', type: RequestType.extra)]);
      expect(await seedOf(BookingSource.renewal(sessionId(5))), isNull);
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
    expect(const BookingSource.renewal('s'), const BookingSource.renewal('s'));
    expect(const BookingSource.renewal('s').kind, BookingSourceKind.renewal);
  });
}

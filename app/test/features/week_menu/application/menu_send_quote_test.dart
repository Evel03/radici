// «Mandar el menú» de la semana 1 de un presupuesto sin aceptar (SPEC 5.8):
// la vista previa lee de menu_sends el presupuesto de su foto (lo que va a
// ver la clienta) y, si no puede, sigue igual (el mensaje ya lo trae); al
// mandarlo, el pedido (que pasa a «Presupuesto enviado») y su presupuesto se
// vuelven a leer, también si la respuesta se pierde (al fallar y al cerrar);
// si el presupuesto se cerró, cambió o la semana no es la primera, lo dice y
// vuelve a leer lo que cambió, sin reintentar el mismo envío. Uno que se
// cerró sin aceptarse llega como la semana cancelada (sessionNotEditable),
// como en la base.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:radici/core/link_launcher.dart';
import 'package:radici/core/platform.dart';
import 'package:radici/features/auth/application/session_controller.dart';
import 'package:radici/features/auth/data/account_repository.dart';
import 'package:radici/features/auth/data/auth_repository.dart';
import 'package:radici/features/quotes/application/quote_providers.dart';
import 'package:radici/features/quotes/data/quotes_repository.dart';
import 'package:radici/features/requests/application/chef_inbox_controller.dart';
import 'package:radici/features/requests/data/chef_requests_repository.dart';
import 'package:radici/features/requests/domain/chef_request.dart';
import 'package:radici/features/sessions/data/sessions_repository.dart';
import 'package:radici/features/sessions/domain/cooking_session.dart';
import 'package:radici/features/week_menu/application/menu_send_controller.dart';
import 'package:radici/features/week_menu/data/menu_sends_repository.dart';
import 'package:radici/features/week_menu/data/session_menus_repository.dart';

import '../../../support/fakes.dart';
import '../../../support/menu_fakes.dart';
import '../../../support/menu_fixtures.dart';
import '../../../support/menu_send_fakes.dart';
import '../../../support/pump_app.dart';
import '../../../support/quote_fakes.dart';
import '../../../support/quote_fixtures.dart';
import '../../../support/request_fixtures.dart';
import '../../../support/session_fixtures.dart';

void main() {
  late FakeChefRequestsRepository requests;
  late FakeSessionMenusRepository menus;
  late FakeMenuSendsRepository sends;
  late FakeQuotesRepository quotes;
  late ProviderContainer container;
  final session = quoteSessionId(1);

  Future<void> setUpFlow() async {
    requests = FakeChefRequestsRepository([
      buildRequest(weeks: 4, seenAt: testNow),
    ]);
    menus = FakeSessionMenusRepository(
      menus: {session: savedLasagneMenu(version: 2)},
      statuses: {session: SessionStatus.held},
    );
    sends = FakeMenuSendsRepository(menus: menus)
      ..previewQuotes[session] = testPreviewQuote;
    final sessions = FakeSessionsRepository([
      for (final week in quoteSessions())
        buildSession(
          id: week.id,
          date: week.date,
          status: SessionStatus.held,
          requestId: 'req-1',
          requestStatus: RequestStatus.newRequest,
        ),
    ]);
    quotes = FakeQuotesRepository(
      requests: requests,
      sessions: sessions,
      quotes: [buildQuote()],
    );
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
        sessionsRepositoryProvider.overrideWithValue(sessions),
        sessionMenusRepositoryProvider.overrideWithValue(menus),
        menuSendsRepositoryProvider.overrideWithValue(sends),
        quotesRepositoryProvider.overrideWithValue(quotes),
        linkLauncherProvider.overrideWithValue(FakeLinkLauncher()),
        isWebProvider.overrideWithValue(true),
      ],
    );
    container
      ..listen(sessionControllerProvider, (_, _) {})
      ..listen(chefInboxProvider, (_, _) {})
      ..listen(requestQuoteProvider('req-1'), (_, _) {})
      ..listen(menuSendProvider(session), (_, _) {});
    await pumpEventQueue();
    await container.read(chefInboxProvider.future);
    await container.read(requestQuoteProvider('req-1').future);
  }

  MenuSendController flow() =>
      container.read(menuSendProvider(session).notifier);

  MenuSendState state() => container.read(menuSendProvider(session));

  test('la vista previa trae el presupuesto de su foto y su pedido', () async {
    await setUpFlow();
    await flow().start(2);

    expect(state().step, MenuSendStep.ready);
    expect(state().quote, testPreviewQuote);
    expect(state().requestId, 'req-1');
    expect(sends.previewQuoteReads, [state().preview!.sendId]);
  });

  test('si no se puede leer el presupuesto de la foto, la vista previa sale igual (el mensaje lo trae)', () async {
    await setUpFlow();
    sends.previewQuoteFailure = const MenuSendFailure(
      MenuSendFailureKind.unavailable,
    );
    await flow().start(2);
    expect(state().step, MenuSendStep.ready);
    expect(state().quote, isNull);
    expect(state().canSend, isTrue);
  });

  test('una semana sin presupuesto: la vista previa de siempre', () async {
    await setUpFlow();
    sends.previewQuotes.clear();
    await flow().start(2);
    expect(state().quote, isNull);
  });

  test('al mandarlo, el pedido pasa a «Presupuesto enviado» y su presupuesto se vuelve a leer', () async {
    await setUpFlow();
    await flow().start(2);
    // Lo que hace la base al marcar el envío (chef_complete_menu_send).
    requests.requests['req-1'] = requests.requests['req-1']!.copyWith(
      status: RequestStatus.quoted,
    );
    final reads = quotes.fetches.length;

    await flow().send();
    await pumpEventQueue();

    expect(state().step, MenuSendStep.sent);
    final request = container
        .read(chefInboxProvider)
        .value!
        .singleWhere((r) => r.id == 'req-1');
    expect(request.status, RequestStatus.quoted);
    // Al mandarlo y, otra vez, porque el pedido cambió de estado.
    expect(quotes.fetches.length, greaterThan(reads));
  });

  test('la respuesta se pierde pero el servidor lo mandó: el presupuesto y el pedido se vuelven a leer, al fallar y al cerrar', () async {
    await setUpFlow();
    await flow().start(2);
    // Lo que hace la base al marcar el envío (chef_complete_menu_send).
    sends
      ..onSent = (_) {
        requests.requests['req-1'] = requests.requests['req-1']!.copyWith(
          status: RequestStatus.quoted,
        );
        quotes.quotes['req-1'] = buildQuote(sent: true);
      }
      ..loseSendResponse = const MenuSendFailure(MenuSendFailureKind.timeout);
    final reads = quotes.fetches.length;

    await flow().send();
    await pumpEventQueue();

    expect(state().step, MenuSendStep.sendFailed);
    expect(quotes.fetches.length, greaterThan(reads));
    final quote = container.read(requestQuoteProvider('req-1')).value!;
    expect(quote.wasSent, isTrue);
    final request = container
        .read(chefInboxProvider)
        .value!
        .singleWhere((r) => r.id == 'req-1');
    expect(request.status, RequestStatus.quoted);

    // Al cerrar la pantalla, otra vez (el servidor pudo terminar después).
    final afterFailure = quotes.fetches.length;
    flow().closed();
    await pumpEventQueue();
    expect(quotes.fetches.length, greaterThan(afterFailure));
  });

  test('un presupuesto que la clienta rechazó (sus semanas, canceladas): la base contesta sessionNotEditable y el presupuesto se vuelve a leer', () async {
    await setUpFlow();
    // Como la base: al rechazarlo, la semana 1 quedó cancelada.
    menus.statuses[session] = SessionStatus.cancelled;
    quotes.quotes['req-1'] = buildQuote(
      sent: true,
      declinedAt: DateTime.utc(2026, 11, 23, 8),
    );
    final reads = quotes.fetches.length;

    await flow().start(2);
    await pumpEventQueue();

    expect(state().step, MenuSendStep.previewFailed);
    expect(state().failure!.kind, MenuSendFailureKind.sessionNotEditable);
    expect(state().failure!.status, SessionStatus.cancelled);
    expect(quotes.fetches.length, reads + 1);
    expect(
      container.read(requestQuoteProvider('req-1')).value!.declinedAt,
      isNotNull,
    );
  });

  for (final kind in [
    MenuSendFailureKind.quoteClosed,
    MenuSendFailureKind.quoteChanged,
    MenuSendFailureKind.quoteWeekNotFirst,
  ]) {
    test(
      '${kind.name} en la vista previa: lo dice y el presupuesto se vuelve a leer',
      () async {
        await setUpFlow();
        sends.previewFailures.add(MenuSendFailure(kind));
        final reads = quotes.fetches.length;
        await flow().start(2);
        await pumpEventQueue();
        expect(state().step, MenuSendStep.previewFailed);
        expect(state().failure!.kind, kind);
        expect(quotes.fetches.length, reads + 1);
      },
    );
  }

  test('el presupuesto cambió desde la vista previa (también con el email ya salido): no reintenta el mismo envío', () async {
    await setUpFlow();
    await flow().start(2);
    sends.sendFailures.add(
      const MenuSendFailure(MenuSendFailureKind.quoteChanged, emailSent: true),
    );
    await flow().send();
    expect(state().step, MenuSendStep.sendFailed);
    expect(state().canResend, isFalse);
    expect(state().canSend, isFalse);

    sends.sendFailures.add(
      const MenuSendFailure(MenuSendFailureKind.quoteClosed, emailSent: true),
    );
    await flow().newPreview();
    await flow().send();
    expect(state().failure!.kind, MenuSendFailureKind.quoteClosed);
    expect(state().canResend, isFalse);
  });

  test('los errores del presupuesto no se reintentan solos', () {
    for (final kind in [
      MenuSendFailureKind.quoteClosed,
      MenuSendFailureKind.quoteChanged,
      MenuSendFailureKind.quoteWeekNotFirst,
    ]) {
      expect(kind.canRetry, isFalse);
    }
  });
}

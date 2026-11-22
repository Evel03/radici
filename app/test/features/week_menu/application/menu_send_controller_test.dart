// «Mandar el menú»: la vista previa con la versión guardada (traducida; si la
// traducción falla, reintentar solo si es pasajera o seguir sin traducir,
// nunca sola), los canales que permite el contacto, el envío (WhatsApp se
// abre solo en el teléfono, con un toque en la web) y cada falla: el menú que
// cambió (otra vista previa, o la de lo guardado, que se vuelve a leer al
// reintentar si no se pudo), la semana que ya no se manda, el email que no
// salió (reintentar o solo WhatsApp), el contacto que cambió, el email que
// salió sin quedar registrado y la respuesta perdida (reintentar no manda dos
// veces: alreadySent y se confirma en menu_sends, con los canales que
// salieron; lo que se muestra vuelve a leer el envío, también al cerrar).
// Un toque doble manda una sola vez.
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:radici/core/link_launcher.dart';
import 'package:radici/core/platform.dart';
import 'package:radici/features/auth/application/session_controller.dart';
import 'package:radici/features/auth/data/account_repository.dart';
import 'package:radici/features/auth/data/auth_repository.dart';
import 'package:radici/features/requests/domain/chef_request.dart'
    show ClientLocale;
import 'package:radici/features/sessions/data/sessions_repository.dart';
import 'package:radici/features/sessions/domain/cooking_session.dart';
import 'package:radici/features/week_menu/application/menu_send_controller.dart';
import 'package:radici/features/week_menu/application/week_menu_summaries.dart';
import 'package:radici/features/week_menu/data/menu_sends_repository.dart';
import 'package:radici/features/week_menu/data/session_menus_repository.dart';
import 'package:radici/features/week_menu/domain/menu_send.dart';
import 'package:radici/features/week_menu/domain/week_menu.dart';

import '../../../support/fakes.dart';
import '../../../support/menu_fakes.dart';
import '../../../support/menu_fixtures.dart';
import '../../../support/menu_send_fakes.dart';
import '../../../support/pump_app.dart';
import '../../../support/request_fixtures.dart';
import '../../../support/session_fixtures.dart';

void main() {
  late FakeSessionMenusRepository menus;
  late FakeMenuSendsRepository sends;
  late FakeLinkLauncher launcher;
  late ProviderContainer container;

  /// La pantalla abierta: escucha el envío (cerrarla es cerrar esto).
  late ProviderSubscription<MenuSendState> screen;
  final session = sessionId(2);

  /// La semana 2 de la reserva, con su menú guardado en la versión 3.
  Future<void> setUpFlow({
    bool web = false,
    MenuSendContact contact = testMenuContact,
    ClientLocale locale = ClientLocale.it,
    int savedVersion = 3,
  }) async {
    menus = FakeSessionMenusRepository(
      menus: {session: savedLasagneMenu(version: savedVersion)},
    );
    sends = FakeMenuSendsRepository(
      menus: menus,
      contact: contact,
      locale: locale,
    );
    launcher = FakeLinkLauncher();
    container = ProviderContainer.test(
      retry: noRetry,
      overrides: [
        authRepositoryProvider.overrideWithValue(
          FakeAuthRepository(user: chefUser),
        ),
        accountRepositoryProvider.overrideWithValue(
          FakeAccountRepository(chefAccountData),
        ),
        sessionsRepositoryProvider.overrideWithValue(
          FakeSessionsRepository(buildBooking()),
        ),
        sessionMenusRepositoryProvider.overrideWithValue(menus),
        menuSendsRepositoryProvider.overrideWithValue(sends),
        linkLauncherProvider.overrideWithValue(launcher),
        isWebProvider.overrideWithValue(web),
      ],
    );
    // La sesión de Evelyn, cargada.
    container.listen(sessionControllerProvider, (_, _) {});
    await pumpEventQueue();
    // Como la pantalla, que lo escucha mientras está abierta.
    screen = container.listen(menuSendProvider(session), (_, _) {});
  }

  MenuSendController flow() =>
      container.read(menuSendProvider(session).notifier);

  MenuSendState state() => container.read(menuSendProvider(session));

  group('la vista previa', () {
    test('con la versión guardada y traducida; elige los dos canales si el contacto los tiene', () async {
      await setUpFlow();
      await flow().start(3);

      expect(state().step, MenuSendStep.ready);
      expect(
        sends.previews.single,
        MenuPreviewRequest(sessionId: session, menuVersion: 3),
      );
      expect(sends.previews.single.translate, isTrue);
      expect(state().preview!.translated, isTrue);
      expect(state().email, isTrue);
      expect(state().whatsapp, isTrue);
      expect(state().canSend, isTrue);
    });

    test('mientras la pide no pide otra (ni con otro toque)', () async {
      await setUpFlow();
      sends.pendingPreview = Completer<void>();
      final first = flow().start(3);
      expect(state().step, MenuSendStep.previewing);
      await flow().start(3);
      await flow().retryPreview();
      expect(sends.previews, hasLength(1));
      sends.pendingPreview!.complete();
      await first;
      expect(state().step, MenuSendStep.ready);
    });

    test('sin teléfono: WhatsApp no se elige ni se puede elegir; sin ningún canal no se manda', () async {
      await setUpFlow(
        contact: const MenuSendContact(
          name: 'Giulia Rossi',
          email: 'giulia@example.test',
        ),
      );
      await flow().start(3);
      expect(state().whatsapp, isFalse);
      expect(state().whatsappAvailable, isFalse);
      flow().setWhatsapp(true);
      expect(state().whatsapp, isFalse);
      flow().setEmail(false);
      expect(state().canSend, isFalse);
      await flow().send();
      expect(sends.sends, isEmpty);
    });

    test('con un email que no sirve, el email no se elige', () async {
      await setUpFlow(
        contact: const MenuSendContact(
          name: 'Giulia',
          email: 'giulia@example',
          phone: '+39 333 123 4567',
        ),
      );
      await flow().start(3);
      expect(state().email, isFalse);
      expect(state().emailAvailable, isFalse);
      expect(state().whatsapp, isTrue);
    });
  });

  group('si la traducción falla, nunca reintenta sola', () {
    test('422: no se ofrece reintentar; «Seguir sin traducir» pide otra sin traducir (y las siguientes tampoco)', () async {
      await setUpFlow();
      sends.previewFailures.add(
        const MenuSendFailure(MenuSendFailureKind.untranslatable),
      );
      await flow().start(3);
      await pumpEventQueue();

      expect(state().step, MenuSendStep.previewFailed);
      expect(state().failure!.kind, MenuSendFailureKind.untranslatable);
      expect(state().failure!.kind.canRetry, isFalse);
      expect(sends.previews, hasLength(1));

      await flow().previewWithoutTranslation();
      expect(sends.previews.last.translate, isFalse);
      expect(state().step, MenuSendStep.ready);
      expect(state().preview!.translated, isFalse);
      expect(state().translate, isFalse);

      await flow().newPreview();
      expect(sends.previews.last.translate, isFalse);
    });

    test('503: se puede reintentar igual (traducida)', () async {
      await setUpFlow();
      sends.previewFailures.add(
        const MenuSendFailure(MenuSendFailureKind.unavailable),
      );
      await flow().start(3);
      await pumpEventQueue();
      expect(state().failure!.kind.canRetry, isTrue);
      expect(sends.previews, hasLength(1));

      await flow().retryPreview();
      expect(sends.previews.last.translate, isTrue);
      expect(state().step, MenuSendStep.ready);
    });

    for (final kind in [
      MenuSendFailureKind.rateLimited,
      MenuSendFailureKind.notConfigured,
      MenuSendFailureKind.timeout,
    ]) {
      test('${kind.name}: lo dice y no vuelve a pedir', () async {
        await setUpFlow();
        sends.previewFailures.add(MenuSendFailure(kind));
        await flow().start(3);
        await pumpEventQueue();
        expect(state().step, MenuSendStep.previewFailed);
        expect(state().failure!.kind, kind);
        expect(sends.previews, hasLength(1));
      });
    }
  });

  group('el menú o la semana cambiaron', () {
    test('otra versión guardada (otro teléfono): menuChanged; «Ver lo guardado» vuelve a leer la versión y pide la vista previa con ella', () async {
      await setUpFlow(savedVersion: 4);
      await flow().start(3);
      expect(state().step, MenuSendStep.previewFailed);
      expect(state().failure!.kind, MenuSendFailureKind.menuChanged);

      await flow().previewSaved();
      expect(menus.summaryCalls.last, [session]);
      expect(sends.previews.last.menuVersion, 4);
      expect(state().menuVersion, 4);
      expect(state().step, MenuSendStep.ready);
    });

    for (final (action, translate) in [
      ('Reintentar', true),
      ('Seguir sin traducir', false),
    ]) {
      test(
        'si «Ver lo guardado» no pudo leer la versión, «$action» la vuelve a leer (no pide la de antes, que ya se rechazó)',
        () async {
          await setUpFlow(savedVersion: 4);
          await flow().start(3);
          expect(state().failure!.kind, MenuSendFailureKind.menuChanged);
          menus.summaryFailure = const MenuFailure(MenuFailureKind.unavailable);
          await flow().previewSaved();
          expect(state().step, MenuSendStep.previewFailed);
          expect(state().failure!.kind, MenuSendFailureKind.unavailable);
          expect(sends.previews, hasLength(1));

          menus.summaryFailure = null;
          if (translate) {
            await flow().retryPreview();
          } else {
            await flow().previewWithoutTranslation();
          }
          expect(sends.previews.last.menuVersion, 4);
          expect(sends.previews.last.translate, translate);
          expect(state().menuVersion, 4);
          expect(state().step, MenuSendStep.ready);

          // Ya leída: otra vista previa no la vuelve a leer.
          final reads = menus.summaryCalls.length;
          await flow().newPreview();
          expect(menus.summaryCalls, hasLength(reads));
          expect(sends.previews.last.menuVersion, 4);
        },
      );
    }

    test('una semana cancelada no se manda: lo dice con su estado', () async {
      await setUpFlow();
      menus.statuses[session] = SessionStatus.cancelled;
      await flow().start(3);
      expect(state().failure!.kind, MenuSendFailureKind.sessionNotEditable);
      expect(state().failure!.status, SessionStatus.cancelled);
    });
  });

  group('el envío', () {
    test('por email y WhatsApp: sale, en el teléfono se abre WhatsApp con el texto y el link, y la ficha vuelve a leer el envío', () async {
      await setUpFlow();
      container.listen(latestMenuSendProvider(session), (_, _) {});
      expect(
        await container.read(latestMenuSendProvider(session).future),
        isNull,
      );
      await flow().start(3);

      await flow().send();

      expect(state().step, MenuSendStep.sent);
      expect(
        sends.sends.single,
        const MenuSendRequest(sendId: 'send-1', email: true, whatsapp: true),
      );
      expect(state().result!.via, [
        MenuSendChannel.email,
        MenuSendChannel.whatsapp,
      ]);
      final link = launcher.launched.single;
      expect(link.host, 'wa.me');
      expect(link.path, '/393331234567');
      expect(link.queryParameters['text'], contains('#t=send-1'));
      expect(state().whatsAppOpened, isTrue);
      expect(state().whatsAppLost, isFalse);
      final latest = await container.read(
        latestMenuSendProvider(session).future,
      );
      expect(latest!.id, 'send-1');
    });

    test('en la web no se abre solo (el navegador lo bloquearía): «Abrir WhatsApp» lo abre', () async {
      await setUpFlow(web: true);
      await flow().start(3);
      await flow().send();
      expect(state().step, MenuSendStep.sent);
      expect(launcher.launched, isEmpty);
      expect(state().whatsAppOpened, isNull);
      expect(await flow().openWhatsApp(), isTrue);
      expect(launcher.launched.single.host, 'wa.me');
    });

    test('solo por email no abre nada', () async {
      await setUpFlow();
      await flow().start(3);
      flow().setWhatsapp(false);
      await flow().send();
      expect(sends.sends.single.whatsapp, isFalse);
      expect(launcher.launched, isEmpty);
      expect(state().whatsAppLink, isNull);
    });

    test('un toque doble manda una sola vez', () async {
      await setUpFlow();
      await flow().start(3);
      sends.pendingSend = Completer<void>();
      final first = flow().send();
      final second = flow().send();
      expect(state().step, MenuSendStep.sending);
      expect(state().canSend, isFalse);
      sends.pendingSend!.complete();
      await Future.wait([first, second]);
      expect(sends.sends, hasLength(1));
      expect(state().step, MenuSendStep.sent);
    });

    test('mientras manda no pide otra vista previa', () async {
      await setUpFlow();
      await flow().start(3);
      sends.pendingSend = Completer<void>();
      final sending = flow().send();
      await flow().newPreview();
      await flow().start(3);
      expect(sends.previews, hasLength(1));
      sends.pendingSend!.complete();
      await sending;
    });

    test('aunque se cierre la pantalla mientras manda, la respuesta se espera y el estado se vuelve a leer', () async {
      await setUpFlow(web: true);
      container.listen(latestMenuSendProvider(session), (_, _) {});
      await container.read(latestMenuSendProvider(session).future);
      await flow().start(3);
      sends.pendingSend = Completer<void>();
      final sending = flow().send();
      // La pantalla se cierra: nadie más escucha el envío.
      screen.close();
      await pumpEventQueue();
      sends.pendingSend!.complete();
      await sending;
      final latest = await container.read(
        latestMenuSendProvider(session).future,
      );
      expect(latest!.id, 'send-1');
      // Con la respuesta, el envío deja de retenerse y se descarta.
      await pumpEventQueue();
      expect(container.exists(menuSendProvider(session)), isFalse);
    });

    test(
      'después de mandar, empezar otra vez arma otra vista previa',
      () async {
        await setUpFlow();
        await flow().start(3);
        await flow().send();
        await flow().start(3);
        expect(sends.previews, hasLength(2));
        expect(state().step, MenuSendStep.ready);
        expect(state().preview!.sendId, 'send-2');
      },
    );
  });

  group('si el envío falla', () {
    test('el email no salió (502): se puede reintentar o mandar solo por WhatsApp, con el mismo envío', () async {
      await setUpFlow();
      await flow().start(3);
      sends.sendFailures.add(
        const MenuSendFailure(MenuSendFailureKind.emailFailed),
      );
      await flow().send();
      expect(state().step, MenuSendStep.sendFailed);
      expect(state().failure!.kind, MenuSendFailureKind.emailFailed);
      expect(state().canResend, isTrue);
      expect(state().canSend, isTrue);
      // La vista previa sigue a la vista.
      expect(state().preview, isNotNull);

      await flow().sendOnly(MenuSendChannel.whatsapp);
      expect(
        sends.sends.last,
        const MenuSendRequest(sendId: 'send-1', email: false, whatsapp: true),
      );
      expect(state().step, MenuSendStep.sent);
      expect(state().result!.via, [MenuSendChannel.whatsapp]);
    });

    test('una respuesta perdida: reintentar no manda dos veces (alreadySent) y se confirma en menu_sends, sin el texto del WhatsApp', () async {
      await setUpFlow();
      await flow().start(3);
      sends.loseSendResponse = const MenuSendFailure(
        MenuSendFailureKind.timeout,
      );
      await flow().send();
      expect(state().step, MenuSendStep.sendFailed);
      expect(state().failure!.kind, MenuSendFailureKind.timeout);
      expect(state().canResend, isTrue);
      launcher.launched.clear();

      await flow().send();

      expect(sends.sends, hasLength(2));
      expect(sends.sends.last.sendId, 'send-1');
      expect(sends.sendFetches, ['send-1']);
      expect(sends.sent, hasLength(1));
      expect(state().step, MenuSendStep.sent);
      expect(state().recovered, isTrue);
      expect(state().whatsAppLink, isNull);
      expect(state().whatsAppLost, isTrue);
      expect(launcher.launched, isEmpty);

      // Otra vista previa para mandarlo por WhatsApp: el email ya le llegó,
      // así que queda elegido solo WhatsApp.
      await flow().newPreview();
      expect(state().preview!.sendId, 'send-2');
      expect(state().email, isFalse);
      expect(state().whatsapp, isTrue);
    });

    test('una respuesta perdida de un envío solo por WhatsApp y un reintento solo por email: dice lo que salió (WhatsApp, sin su texto)', () async {
      await setUpFlow();
      await flow().start(3);
      flow().setEmail(false);
      sends.loseSendResponse = const MenuSendFailure(
        MenuSendFailureKind.timeout,
      );
      await flow().send();
      expect(state().step, MenuSendStep.sendFailed);
      // Cree que falló WhatsApp: elige el email y reintenta.
      flow().setWhatsapp(false);
      flow().setEmail(true);
      await flow().send();

      expect(
        sends.sends.last,
        const MenuSendRequest(sendId: 'send-1', email: true, whatsapp: false),
      );
      expect(sends.sent.single.via, [MenuSendChannel.whatsapp]);
      expect(state().step, MenuSendStep.sent);
      expect(state().recovered, isTrue);
      expect(state().result!.via, [MenuSendChannel.whatsapp]);
      expect(state().whatsAppLost, isTrue);

      // Otra vista previa para mandarlo por WhatsApp, como se había elegido.
      await flow().newPreview();
      expect(state().email, isFalse);
      expect(state().whatsapp, isTrue);
    });

    test('al revés: salió solo por email y el reintento pide también WhatsApp: no avisa de un WhatsApp que nunca salió', () async {
      await setUpFlow();
      await flow().start(3);
      flow().setWhatsapp(false);
      sends.loseSendResponse = const MenuSendFailure(
        MenuSendFailureKind.offline,
      );
      await flow().send();
      flow().setWhatsapp(true);
      await flow().send();

      expect(sends.sends.last.whatsapp, isTrue);
      expect(state().step, MenuSendStep.sent);
      expect(state().recovered, isTrue);
      expect(state().result!.via, [MenuSendChannel.email]);
      expect(state().whatsAppLost, isFalse);
    });

    test('sin respuesta (no se sabe si salió): la ficha, el editor y la reserva vuelven a leer el envío', () async {
      await setUpFlow();
      container.listen(latestMenuSendProvider(session), (_, _) {});
      expect(
        await container.read(latestMenuSendProvider(session).future),
        isNull,
      );
      await flow().start(3);
      final reads = sends.latestCalls.length;
      sends.loseSendResponse = const MenuSendFailure(
        MenuSendFailureKind.timeout,
      );
      await flow().send();
      await pumpEventQueue();
      expect(state().step, MenuSendStep.sendFailed);
      expect(sends.latestCalls.length, greaterThan(reads));
      final latest = await container.read(
        latestMenuSendProvider(session).future,
      );
      expect(latest!.id, 'send-1');
    });

    test('al cerrar la pantalla sin saber si salió, vuelve a leer el envío (el servidor pudo terminar después)', () async {
      await setUpFlow();
      container.listen(latestMenuSendProvider(session), (_, _) {});
      await container.read(latestMenuSendProvider(session).future);
      await flow().start(3);
      sends.loseSendResponse = const MenuSendFailure(
        MenuSendFailureKind.offline,
      );
      await flow().send();
      await pumpEventQueue();
      final reads = sends.latestCalls.length;

      flow().closed();
      await pumpEventQueue();
      expect(sends.latestCalls.length, greaterThan(reads));
    });

    test('al cerrar después de una falla con respuesta (el email no salió), no vuelve a leer nada', () async {
      await setUpFlow();
      container.listen(latestMenuSendProvider(session), (_, _) {});
      await container.read(latestMenuSendProvider(session).future);
      await flow().start(3);
      sends.sendFailures.add(
        const MenuSendFailure(MenuSendFailureKind.emailFailed),
      );
      await flow().send();
      await pumpEventQueue();
      final reads = sends.latestCalls.length;

      flow().closed();
      await pumpEventQueue();
      expect(sends.latestCalls, hasLength(reads));
    });

    test('si después de alreadySent no se puede leer menu_sends, lo dice y reintentar lo confirma', () async {
      await setUpFlow();
      await flow().start(3);
      sends.loseSendResponse = const MenuSendFailure(
        MenuSendFailureKind.offline,
      );
      await flow().send();
      sends.readFailure = const MenuSendFailure(
        MenuSendFailureKind.unavailable,
      );
      await flow().send();
      expect(state().step, MenuSendStep.sendFailed);
      expect(state().failure!.kind, MenuSendFailureKind.unavailable);
      sends.readFailure = null;
      await flow().send();
      expect(state().step, MenuSendStep.sent);
      expect(state().recovered, isTrue);
      expect(sends.sent, hasLength(1));
    });

    test('el email salió pero el envío no quedó registrado: lo dice, se puede reintentar y el estado se vuelve a leer', () async {
      await setUpFlow();
      container.listen(latestMenuSendProvider(session), (_, _) {});
      await container.read(latestMenuSendProvider(session).future);
      await flow().start(3);
      final reads = sends.latestCalls.length;
      sends.sendFailures.add(
        const MenuSendFailure(MenuSendFailureKind.unavailable, emailSent: true),
      );
      await flow().send();
      await pumpEventQueue();
      expect(state().step, MenuSendStep.sendFailed);
      expect(state().failure!.emailSent, isTrue);
      expect(state().canResend, isTrue);
      expect(sends.latestCalls.length, greaterThan(reads));
    });

    test(
      'el email salió y justo cambió el menú: con este envío ya no se puede',
      () async {
        await setUpFlow();
        await flow().start(3);
        sends.sendFailures.add(
          const MenuSendFailure(
            MenuSendFailureKind.menuChanged,
            emailSent: true,
          ),
        );
        await flow().send();
        expect(state().canResend, isFalse);
        expect(state().canSend, isFalse);
      },
    );

    test('cambió algo desde la vista previa: no se reintenta con ese envío; otra vista previa es otro envío', () async {
      await setUpFlow();
      await flow().start(3);
      sends.sendFailures.add(
        const MenuSendFailure(MenuSendFailureKind.menuChanged),
      );
      await flow().send();
      expect(state().canResend, isFalse);
      await flow().send();
      expect(sends.sends, hasLength(1));

      await flow().newPreview();
      expect(state().preview!.sendId, 'send-2');
      await flow().send();
      expect(sends.sends.last.sendId, 'send-2');
      expect(state().step, MenuSendStep.sent);
    });

    test('el contacto de ahora no tiene email: no salió nada; solo por WhatsApp sale', () async {
      await setUpFlow();
      await flow().start(3);
      sends.contact = const MenuSendContact(
        name: 'Giulia Rossi',
        phone: '+39 333 123 4567',
      );
      await flow().send();
      expect(state().failure!.kind, MenuSendFailureKind.noEmail);
      expect(sends.sent, isEmpty);
      expect(state().canResend, isTrue);
      await flow().sendOnly(MenuSendChannel.whatsapp);
      expect(state().step, MenuSendStep.sent);
    });

    test(
      'la semana se canceló desde la vista previa: ya no se manda',
      () async {
        await setUpFlow();
        await flow().start(3);
        menus.statuses[session] = SessionStatus.cancelled;
        await flow().send();
        expect(state().failure!.kind, MenuSendFailureKind.sessionNotEditable);
        expect(state().canResend, isFalse);
      },
    );

    test('el email no está configurado: solo por WhatsApp', () async {
      await setUpFlow();
      await flow().start(3);
      sends.sendFailures.add(
        const MenuSendFailure(MenuSendFailureKind.emailUnavailable),
      );
      await flow().send();
      expect(state().failure!.kind, MenuSendFailureKind.emailUnavailable);
      await flow().sendOnly(MenuSendChannel.whatsapp);
      expect(state().step, MenuSendStep.sent);
    });
  });

  test('guardar, mandar y «Ricarica» suben la revisión que mira Hoy', () async {
    await setUpFlow();
    final before = container.read(weekMenusRevisionProvider);
    await flow().start(3);
    await flow().send();
    expect(container.read(weekMenusRevisionProvider), greaterThan(before));
  });

  test('el estado no imprime nada de la clienta', () async {
    await setUpFlow();
    await flow().start(3);
    expect(state().toString(), 'MenuSendState($session, ready)');
  });

  test('sin menú guardado: la vista previa no sale', () async {
    await setUpFlow();
    menus.menus.remove(session);
    await flow().start(3);
    expect(state().failure!.kind, MenuSendFailureKind.menuNotFound);
    expect(menus.menus[session], isNull);
    expect(const WeekMenuSummary().version, isNull);
  });
}

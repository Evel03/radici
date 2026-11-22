// «Mandar el menú» en la app: desde el editor («Mandar», con el menú
// guardado; con cambios sin guardar, primero pide guardarlos) y desde la
// ficha («Mandar a la clienta», después «Mandar de nuevo»). La vista previa
// dice a quién va, en qué idioma y si la lista se tradujo, deja elegir email
// y WhatsApp (deshabilitados con el porqué) y muestra el WhatsApp y el email
// con el texto de reemplazo del link. Cada falla lo dice y ofrece lo que se
// puede hacer: seguir sin traducir, reintentar, solo por WhatsApp, volver al
// menú (desde el editor) o ver lo guardado (desde la ficha). Al mandar con
// WhatsApp se abre solo en el teléfono y con «Abrir WhatsApp» en la web.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:radici/features/sessions/presentation/cooking_session_screen.dart';
import 'package:radici/features/week_menu/data/menu_sends_repository.dart';
import 'package:radici/features/week_menu/domain/menu_send.dart';
import 'package:radici/features/week_menu/domain/week_menu.dart';
import 'package:radici/features/week_menu/presentation/menu_send_screen.dart';
import 'package:radici/features/week_menu/presentation/week_menu_screen.dart';

import '../../../support/chef_app.dart';
import '../../../support/fakes.dart';
import '../../../support/menu_fakes.dart';
import '../../../support/menu_fixtures.dart';
import '../../../support/menu_send_fakes.dart';
import '../../../support/plain_text.dart';
import '../../../support/recipe_fixtures.dart';
import '../../../support/session_fixtures.dart';

void main() {
  Finder byKey(String key) => find.byKey(ValueKey(key));

  String textOf(WidgetTester tester, String key) =>
      plainSpaces(tester.widget<Text>(byKey(key)).data!);

  String selectableOf(WidgetTester tester, String key) =>
      tester.widget<SelectableText>(byKey(key)).data!;

  String buttonText(WidgetTester tester, String key) => plainSpaces(
    tester
        .widget<Text>(
          find.descendant(of: byKey(key), matching: find.byType(Text)),
        )
        .data!,
  );

  VoidCallback? onPressedOf(WidgetTester tester, String key) =>
      tester.widget<ButtonStyleButton>(byKey(key)).onPressed;

  Future<void> tapVisible(WidgetTester tester, Finder finder) async {
    await tester.ensureVisible(finder);
    await tester.pumpAndSettle();
    await tester.tap(finder);
    await tester.pumpAndSettle();
  }

  final session = sessionId(2);

  /// La semana 2 de una reserva de 4, con el menú guardado (versión 2), en
  /// español: el editor ([location] por defecto) o la ficha.
  Future<ChefApp> open(
    WidgetTester tester, {
    String? location,
    FakeSessionMenusRepository? menus,
    MenuSendContact contact = testMenuContact,
    bool isWeb = false,
  }) async {
    final weekMenus =
        menus ??
        FakeSessionMenusRepository(
          menus: {session: savedLasagneMenu(version: 2)},
        );
    return pumpChefApp(
      tester,
      requests: FakeChefRequestsRepository(const []),
      sessions: FakeSessionsRepository(buildBooking()),
      recipes: FakeRecipesRepository(sampleRecipes()),
      menus: weekMenus,
      menuSends: FakeMenuSendsRepository(menus: weekMenus, contact: contact),
      location: location ?? '/sessioni/$session/menu',
      deviceLocales: const [Locale('es')],
      isWeb: isWeb,
    );
  }

  group('desde el editor', () {
    testWidgets(
      'el estado dice que no se mandó; «Mandar» abre la vista previa del menú guardado: a quién, el idioma, la lista traducida, los dos canales y lo que le llega',
      (tester) async {
        final app = await open(tester);
        expect(
          textOf(tester, 'week-menu-status-not-sent'),
          'Todavía no se mandó a la clienta.',
        );

        await tapVisible(tester, byKey('week-menu-send'));
        expect(find.byType(MenuSendScreen), findsOneWidget);
        expect(
          app.menuSends.previews.single,
          MenuPreviewRequest(sessionId: session, menuVersion: 2),
        );
        expect(textOf(tester, 'menu-send-to'), 'Para Giulia Rossi');
        expect(
          textOf(tester, 'menu-send-language'),
          'Va en el idioma de la clienta: Italiano.',
        );
        expect(
          textOf(tester, 'menu-send-translation'),
          'Los nombres de la lista se tradujeron solos.',
        );
        expect(
          tester.widget<CheckboxListTile>(byKey('menu-send-email')).value,
          isTrue,
        );
        expect(
          tester.widget<CheckboxListTile>(byKey('menu-send-whatsapp')).value,
          isTrue,
        );
        expect(textOf(tester, 'menu-send-email-detail'), 'giulia@example.test');
        expect(
          textOf(tester, 'menu-send-whatsapp-detail'),
          '+39 333 123 4567 · se abre WhatsApp con el mensaje listo para mandar.',
        );
        // El WhatsApp, con el texto de reemplazo del link tal como viene.
        final whatsapp = selectableOf(tester, 'menu-send-message');
        expect(whatsapp, contains('*Il menù*'));
        expect(whatsapp, contains(testLinkPlaceholder));
        expect(byKey('menu-send-subject'), findsNothing);
        expect(
          buttonText(tester, 'menu-send-submit'),
          'Mandar por email y WhatsApp',
        );

        // El email, con su asunto.
        await tapVisible(
          tester,
          find.descendant(
            of: byKey('menu-send-view'),
            matching: find.text('Email'),
          ),
        );
        expect(
          selectableOf(tester, 'menu-send-subject'),
          'Asunto: Radici: il menù della settimana',
        );
        expect(
          selectableOf(tester, 'menu-send-message'),
          contains('Evelyn ha preparato il menù.'),
        );
      },
    );

    testWidgets(
      'por los dos: sale, en el teléfono se abre WhatsApp, y al volver el editor dice cuándo y por dónde salió',
      (tester) async {
        final app = await open(tester);
        await tapVisible(tester, byKey('week-menu-send'));
        await tapVisible(tester, byKey('menu-send-submit'));

        expect(
          textOf(tester, 'menu-send-done-text'),
          'Mandado a Giulia Rossi el 22/11 a las 14:32 por email y WhatsApp.',
        );
        final link = app.launcher.launched.single;
        expect(link.host, 'wa.me');
        expect(link.path, '/393331234567');
        expect(
          textOf(tester, 'menu-send-whatsapp-next'),
          'Falta tocar «Enviar» en WhatsApp: ahí está el mensaje con el enlace.',
        );

        await tapVisible(tester, byKey('menu-send-done'));
        expect(find.byType(WeekMenuScreen), findsOneWidget);
        expect(
          textOf(tester, 'week-menu-status-sent'),
          'Mandado el 22/11 a las 14:32 por email y WhatsApp.',
        );
      },
    );

    testWidgets(
      'en la web no se abre solo: «Abrir WhatsApp» lo abre con el toque',
      (tester) async {
        final app = await open(tester, isWeb: true);
        await tapVisible(tester, byKey('week-menu-send'));
        await tapVisible(tester, byKey('menu-send-submit'));
        expect(app.launcher.launched, isEmpty);
        expect(
          textOf(tester, 'menu-send-whatsapp-next'),
          'Toca «Abrir WhatsApp» y manda el mensaje: lleva el enlace para confirmar.',
        );
        await tapVisible(tester, byKey('menu-send-open-whatsapp'));
        expect(app.launcher.launched.single.host, 'wa.me');
      },
    );

    testWidgets(
      'con cambios sin guardar, «Mandar» pide guardarlos: «Cancelar» no manda nada; «Guardar y seguir» guarda y abre la vista previa con la versión nueva',
      (tester) async {
        final app = await open(tester);
        await tapVisible(tester, byKey('week-menu-dish-more-$lasagneId'));

        await tapVisible(tester, byKey('week-menu-send'));
        expect(byKey('week-menu-save-first-dialog'), findsOneWidget);
        expect(find.text('¿Guardar antes de mandar?'), findsOneWidget);
        await tapVisible(tester, byKey('week-menu-save-first-cancel'));
        expect(app.menus.saves, isEmpty);
        expect(find.byType(MenuSendScreen), findsNothing);

        await tapVisible(tester, byKey('week-menu-send'));
        await tapVisible(tester, byKey('week-menu-save-first-confirm'));
        expect(app.menus.saves, hasLength(1));
        expect(find.byType(MenuSendScreen), findsOneWidget);
        expect(app.menuSends.previews.single.menuVersion, 3);
      },
    );

    testWidgets('sin platos, «Mandar» no se puede tocar', (tester) async {
      await open(
        tester,
        menus: FakeSessionMenusRepository(
          menus: {session: const SavedWeekMenu(version: 1)},
        ),
      );
      expect(onPressedOf(tester, 'week-menu-send'), isNull);
    });

    testWidgets(
      'sin teléfono: WhatsApp deshabilitado con el porqué, y el botón dice por dónde sale',
      (tester) async {
        await open(
          tester,
          contact: const MenuSendContact(
            name: 'Giulia Rossi',
            email: 'giulia@example.test',
          ),
        );
        await tapVisible(tester, byKey('week-menu-send'));
        expect(
          tester
              .widget<CheckboxListTile>(byKey('menu-send-whatsapp'))
              .onChanged,
          isNull,
        );
        expect(
          textOf(tester, 'menu-send-whatsapp-detail'),
          'No hay teléfono en el pedido ni en la ficha.',
        );
        expect(buttonText(tester, 'menu-send-submit'), 'Mandar por email');
        // Sin ningún canal elegido, no se manda.
        await tapVisible(tester, byKey('menu-send-email'));
        expect(onPressedOf(tester, 'menu-send-submit'), isNull);
        expect(
          buttonText(tester, 'menu-send-submit'),
          'Elige por dónde mandarlo',
        );
      },
    );

    testWidgets(
      'la traducción no salió (422): lo dice, sin «Reintentar», y «Seguir sin traducir» arma la vista previa sin traducir',
      (tester) async {
        final app = await open(tester);
        app.menuSends.previewFailures.add(
          const MenuSendFailure(MenuSendFailureKind.untranslatable),
        );
        await tapVisible(tester, byKey('week-menu-send'));
        expect(
          textOf(tester, 'menu-send-preview-error'),
          'La traducción automática no pudo traducir la lista.',
        );
        expect(byKey('menu-send-retry-preview'), findsNothing);
        await tapVisible(tester, byKey('menu-send-without-translation'));
        expect(app.menuSends.previews.last.translate, isFalse);
        expect(
          textOf(tester, 'menu-send-translation'),
          'La lista va como la escribiste, sin traducir.',
        );
      },
    );

    testWidgets(
      'sin respuesta (503): «Reintentar» y «Seguir sin traducir»; reintentar la arma',
      (tester) async {
        final app = await open(tester);
        app.menuSends.previewFailures.add(
          const MenuSendFailure(MenuSendFailureKind.unavailable),
        );
        await tapVisible(tester, byKey('week-menu-send'));
        expect(
          textOf(tester, 'menu-send-preview-error'),
          'No se pudo armar la vista previa. Revisa la conexión y vuelve a intentarlo.',
        );
        expect(byKey('menu-send-without-translation'), findsOneWidget);
        expect(app.menuSends.previews, hasLength(1));
        await tapVisible(tester, byKey('menu-send-retry-preview'));
        expect(app.menuSends.previews, hasLength(2));
        expect(app.menuSends.previews.last.translate, isTrue);
        expect(byKey('menu-send-preview'), findsOneWidget);
      },
    );

    testWidgets(
      'el email no salió: lo dice y «Mandar solo por WhatsApp» lo manda con el mismo envío',
      (tester) async {
        final app = await open(tester);
        await tapVisible(tester, byKey('week-menu-send'));
        app.menuSends.sendFailures.add(
          const MenuSendFailure(MenuSendFailureKind.emailFailed),
        );
        await tapVisible(tester, byKey('menu-send-submit'));
        expect(
          textOf(tester, 'menu-send-error'),
          'El email no salió: no se mandó nada.',
        );
        expect(byKey('menu-send-retry'), findsOneWidget);
        await tapVisible(tester, byKey('menu-send-only-whatsapp'));
        expect(app.menuSends.sends.last.sendId, 'send-1');
        expect(
          textOf(tester, 'menu-send-done-text'),
          'Mandado a Giulia Rossi el 22/11 a las 14:32 por WhatsApp.',
        );
      },
    );

    testWidgets(
      'el email salió pero el envío no quedó registrado: lo dice, y que reintentar manda otro email',
      (tester) async {
        final app = await open(tester);
        await tapVisible(tester, byKey('week-menu-send'));
        app.menuSends.sendFailures.add(
          const MenuSendFailure(
            MenuSendFailureKind.unavailable,
            emailSent: true,
          ),
        );
        await tapVisible(tester, byKey('menu-send-submit'));
        expect(
          textOf(tester, 'menu-send-error'),
          'El email salió, pero el envío no quedó registrado: en la página de la clienta no aparece como mandado. '
          'Si reintentas, le llega otro email con otro enlace (los dos sirven).',
        );
        expect(byKey('menu-send-retry'), findsOneWidget);
      },
    );

    testWidgets(
      'una respuesta perdida: lo dice y «Reintentar» no lo manda dos veces',
      (tester) async {
        final app = await open(tester);
        await tapVisible(tester, byKey('week-menu-send'));
        app.menuSends.loseSendResponse = const MenuSendFailure(
          MenuSendFailureKind.timeout,
        );
        await tapVisible(tester, byKey('menu-send-submit'));
        expect(
          textOf(tester, 'menu-send-error'),
          'No se sabe si salió: se cortó la conexión o el servidor no respondió. '
          'Reintentar es seguro: si ya salió, no se manda dos veces.',
        );
        await tapVisible(tester, byKey('menu-send-retry'));
        expect(app.menuSends.sent, hasLength(1));
        expect(
          textOf(tester, 'menu-send-recovered'),
          'Ya había salido: la respuesta del primer intento se había perdido.',
        );
        expect(byKey('menu-send-whatsapp-lost'), findsOneWidget);
        expect(byKey('menu-send-open-whatsapp'), findsNothing);
      },
    );

    testWidgets(
      'el menú se guardó en otro teléfono: «Volver al menú» vuelve al editor, que carga lo guardado',
      (tester) async {
        final app = await open(tester);
        // Otro teléfono guarda 6 porciones.
        app.menus.menus[session] = savedLasagneMenu(version: 3, portions: 6);
        await tapVisible(tester, byKey('week-menu-send'));
        expect(
          textOf(tester, 'menu-send-preview-error'),
          'El menú cambió: se guardó en otro teléfono después de que lo abriste.',
        );
        await tapVisible(tester, byKey('menu-send-back-to-menu'));
        expect(find.byType(MenuSendScreen), findsNothing);
        expect(
          textOf(tester, 'week-menu-dish-portions-$lasagneId'),
          '6 porciones',
        );
      },
    );
  });

  group('desde la ficha', () {
    testWidgets(
      '«Mandar a la clienta» abre la vista previa; después, el estado y «Mandar de nuevo»',
      (tester) async {
        await open(tester, location: '/sessioni/$session');
        expect(find.byType(CookingSessionScreen), findsOneWidget);
        await tester.ensureVisible(byKey('session-menu-send'));
        expect(
          textOf(tester, 'session-menu-status-not-sent'),
          'Todavía no se mandó a la clienta.',
        );
        expect(buttonText(tester, 'session-menu-send'), 'Mandar a la clienta');

        await tapVisible(tester, byKey('session-menu-send'));
        await tapVisible(tester, byKey('menu-send-submit'));
        await tapVisible(tester, byKey('menu-send-done'));

        expect(find.byType(CookingSessionScreen), findsOneWidget);
        await tester.ensureVisible(byKey('session-menu-send'));
        expect(
          textOf(tester, 'session-menu-status-sent'),
          'Mandado el 22/11 a las 14:32 por email y WhatsApp.',
        );
        expect(buttonText(tester, 'session-menu-send'), 'Mandar de nuevo');
      },
    );

    testWidgets(
      'el menú se guardó en otro teléfono: «Ver lo guardado» arma la vista previa con la versión de ahora',
      (tester) async {
        final app = await open(tester, location: '/sessioni/$session');
        app.menus.menus[session] = savedLasagneMenu(version: 3, portions: 6);
        await tapVisible(tester, byKey('session-menu-send'));
        expect(app.menuSends.previews.single.menuVersion, 2);
        await tapVisible(tester, byKey('menu-send-preview-saved'));
        expect(app.menuSends.previews.last.menuVersion, 3);
        expect(byKey('menu-send-preview'), findsOneWidget);
      },
    );

    testWidgets('sin menú guardado, «Mandar a la clienta» no se puede tocar', (
      tester,
    ) async {
      await open(
        tester,
        location: '/sessioni/$session',
        menus: FakeSessionMenusRepository(),
      );
      await tester.ensureVisible(byKey('session-menu-send'));
      expect(onPressedOf(tester, 'session-menu-send'), isNull);
      expect(byKey('session-menu-status-not-sent'), findsNothing);
    });
  });

  testWidgets('la X se habilita de nuevo después de mandar y cierra', (
    tester,
  ) async {
    await open(tester);
    await tapVisible(tester, byKey('week-menu-send'));
    await tapVisible(tester, byKey('menu-send-submit'));
    await tapVisible(tester, byKey('menu-send-close'));
    expect(find.byType(MenuSendScreen), findsNothing);
    expect(find.byType(WeekMenuScreen), findsOneWidget);
    expect(MenuSendExit.values, hasLength(2));
  });
}

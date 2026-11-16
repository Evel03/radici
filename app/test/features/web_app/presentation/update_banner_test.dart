// Aviso «C'è una nuova versione · Aggiorna», arriba de cualquier pantalla de
// /gestione/ (también del login): al abrir y al volver a primer plano, como
// mucho cada 5 minutos. Solo recarga con «Aggiorna».
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:radici/core/browser.dart';
import 'package:radici/core/build_id.dart';
import 'package:radici/features/auth/data/account_repository.dart';
import 'package:radici/features/auth/data/auth_repository.dart';
import 'package:radici/features/auth/presentation/login_screen.dart';
import 'package:radici/features/requests/data/chef_requests_repository.dart';
import 'package:radici/features/requests/presentation/inbox_screen.dart';
import 'package:radici/features/requests/presentation/new_request_alert_listener.dart';
import 'package:radici/features/web_app/data/published_build_repository.dart';

import '../../../support/browser_fakes.dart';
import '../../../support/chef_app.dart';
import '../../../support/fakes.dart';
import '../../../support/pump_app.dart';
import '../../../support/request_fixtures.dart';

void main() {
  late FakePublishedBuildRepository published;
  late FakeBrowser browser;
  late DateTime now;

  List<Override> web({String buildId = 'abc1234'}) => [
    buildIdProvider.overrideWithValue(buildId),
    publishedBuildRepositoryProvider.overrideWithValue(published),
    browserProvider.overrideWithValue(browser),
  ];

  Future<ChefApp> openInbox(
    WidgetTester tester, {
    String buildId = 'abc1234',
    Size size = const Size(400, 900),
  }) => pumpChefApp(
    tester,
    requests: FakeChefRequestsRepository([buildRequest()]),
    size: size,
    clock: () => now,
    overrides: web(buildId: buildId),
  );

  /// Como cuando Evelyn vuelve a la app desde otra (la web pasa por hidden).
  Future<void> backToForeground(WidgetTester tester) async {
    for (final state in const [
      AppLifecycleState.inactive,
      AppLifecycleState.hidden,
      AppLifecycleState.inactive,
      AppLifecycleState.resumed,
    ]) {
      tester.binding.handleAppLifecycleStateChanged(state);
    }
    await tester.pumpAndSettle();
  }

  Finder banner() => find.byKey(const ValueKey('update-banner'));
  Finder reloadButton() => find.byKey(const ValueKey('update-banner-reload'));

  setUp(() {
    published = FakePublishedBuildRepository('def5678');
    browser = FakeBrowser();
    now = testNow;
  });

  testWidgets('versión nueva: aviso arriba de la bandeja; recarga solo con «Aggiorna»', (
    tester,
  ) async {
    await openInbox(tester, size: const Size(375, 667));

    expect(find.byType(InboxScreen), findsOneWidget);
    expect(banner(), findsOneWidget);
    expect(find.text("C'è una nuova versione"), findsOneWidget);
    expect(find.text('Aggiorna'), findsOneWidget);
    expect(browser.reloads, 0);
    // Arriba de la barra de título; la barra de navegación sigue abajo.
    expect(
      tester.getBottomLeft(banner()).dy,
      lessThanOrEqualTo(tester.getTopLeft(find.byType(AppBar)).dy),
    );
    expect(
      tester.getBottomLeft(find.byKey(const ValueKey('chef-nav-bar'))).dy,
      667,
    );
    expect(tester.getSize(reloadButton()).height, greaterThanOrEqualTo(48));

    await tester.tap(reloadButton());
    await tester.pump();
    expect(browser.reloads, 1);
  });

  testWidgets('también en el login (el botón del email abre Safari sin sesión), en español', (
    tester,
  ) async {
    await pumpRadiciApp(
      tester,
      isWeb: true,
      deviceLocales: const [Locale('es', 'AR')],
      clock: () => now,
      overrides: [
        authRepositoryProvider.overrideWithValue(FakeAuthRepository()),
        accountRepositoryProvider.overrideWithValue(
          FakeAccountRepository(chefAccountData),
        ),
        chefRequestsRepositoryProvider.overrideWithValue(
          FakeChefRequestsRepository(const []),
        ),
        ...web(),
      ],
    );

    expect(find.byType(LoginScreen), findsOneWidget);
    expect(find.text('Hay una versión nueva'), findsOneWidget);
    expect(find.text('Actualizar'), findsOneWidget);
  });

  testWidgets('la misma versión: sin aviso', (tester) async {
    published.published = 'abc1234';
    await openInbox(tester);
    expect(published.calls, 1);
    expect(banner(), findsNothing);
  });

  testWidgets('sin id compilado (flutter run, tests): ni siquiera pide build.json', (
    tester,
  ) async {
    await openInbox(tester, buildId: '');
    expect(published.calls, 0);
    expect(banner(), findsNothing);
  });

  testWidgets('al volver a primer plano mira otra vez, como mucho cada 5 minutos', (
    tester,
  ) async {
    published.published = 'abc1234';
    await openInbox(tester);
    expect(published.calls, 1);

    published.published = 'def5678';
    now = testNow.add(const Duration(minutes: 2));
    await backToForeground(tester);
    expect(published.calls, 1);
    expect(banner(), findsNothing);

    now = testNow.add(const Duration(minutes: 5));
    await backToForeground(tester);
    expect(published.calls, 2);
    expect(banner(), findsOneWidget);
    expect(browser.reloads, 0);
  });

  testWidgets('cuando aparece el aviso, la pantalla de abajo sigue como estaba '
      '(en la pestaña elegida y en el mismo lugar del árbol)', (tester) async {
    published.published = 'abc1234';
    await openInbox(tester);
    await tester.tap(find.byKey(const ValueKey('inbox-tab-seen')));
    await tester.pumpAndSettle();
    int selectedTab() =>
        DefaultTabController.of(tester.element(find.byType(TabBar))).index;
    expect(selectedTab(), 1);
    final below = tester.element(find.byType(NewRequestAlertListener));

    published.published = 'def5678';
    now = testNow.add(const Duration(minutes: 5));
    await backToForeground(tester);
    expect(banner(), findsOneWidget);
    expect(selectedTab(), 1);
    // No se volvió a armar: es el mismo Element.
    expect(
      identical(tester.element(find.byType(NewRequestAlertListener)), below),
      isTrue,
    );
  });

  testWidgets('VoiceOver lee el aviso (región viva) y puede tocar «Aggiorna»; '
      'la pantalla de abajo sigue a su alcance', (tester) async {
    final semantics = tester.ensureSemantics();
    await openInbox(tester, size: const Size(375, 667));

    final notice = tester.getSemantics(
      find.bySemanticsLabel("C'è una nuova versione"),
    );
    expect(
      notice,
      isSemantics(label: "C'è una nuova versione", isLiveRegion: true),
    );
    // Un nodo propio, sin nada adentro: no la raíz de la app con su contenido.
    expect(notice.childrenCount, 0);
    expect(find.bySemanticsLabel('Aggiorna'), findsOneWidget);
    expect(find.bySemanticsLabel(RegExp('Giulia Rossi')), findsWidgets);

    tester.semantics.tap(find.semantics.byLabel('Aggiorna'));
    await tester.pump();
    expect(browser.reloads, 1);
    semantics.dispose();
  });

  testWidgets('«Aggiorna» queda a 8 px o más de lo que hay abajo (lo más cerca: '
      'las acciones de la barra, como «Salva» del calendario)', (tester) async {
    // 800 px: el texto entra en un renglón también con la letra de los tests
    // (cada letra es un cuadrado), así el aviso tiene su alto mínimo, el caso
    // más justo. Con la letra real pasa a 375 px: notices_spacing_test.dart.
    await openInbox(tester, size: const Size(800, 667));
    final below = tester.getTopLeft(find.byType(AppBar)).dy;
    expect(below, tester.getBottomLeft(banner()).dy);
    expect(
      below - tester.getRect(reloadButton()).bottom,
      greaterThanOrEqualTo(8),
    );
  });

  testWidgets('con margen arriba (muesca): el aviso lo toma y la barra de abajo '
      'no lo repite', (tester) async {
    tester.view
      ..padding = const FakeViewPadding(top: 47)
      ..viewPadding = const FakeViewPadding(top: 47);
    await openInbox(tester, size: const Size(375, 667));

    expect(tester.getTopLeft(banner()).dy, 47);
    expect(
      tester.getTopLeft(find.byType(NavigationToolbar)).dy,
      tester.getBottomLeft(banner()).dy,
    );
  });
}

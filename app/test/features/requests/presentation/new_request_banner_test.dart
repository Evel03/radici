// Aviso emergente en tiempo real: "Nuova richiesta da …" con botón para
// abrirla, desde cualquier pantalla de la cocinera.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:radici/features/requests/data/chef_requests_repository.dart';
import 'package:radici/features/requests/presentation/agenda_screen.dart';
import 'package:radici/features/requests/presentation/request_detail_screen.dart';

import '../../../support/chef_app.dart';
import '../../../support/fakes.dart';
import '../../../support/request_fixtures.dart';

void main() {
  final arrived = buildRequest(
    id: 'arrived',
    name: 'Marco Bianchi',
    createdAt: DateTime.utc(2026, 10, 19, 12),
  );
  const banner = ValueKey('new-request-banner');

  String bannerText(WidgetTester tester) => tester
      .widget<Text>(find.byKey(const ValueKey('new-request-banner-text')))
      .data!;

  testWidgets('llega un pedido: aviso con el nombre y "Apri" abre el detalle', (
    tester,
  ) async {
    final app = await pumpChefApp(
      tester,
      requests: FakeChefRequestsRepository([buildRequest()]),
    );
    expect(find.byKey(banner), findsNothing);

    app.requests.insertFromRealtime(arrived);
    await tester.pumpAndSettle();

    expect(find.byKey(banner), findsOneWidget);
    expect(bannerText(tester), 'Nuova richiesta da Marco Bianchi');
    // La lista y el contador ya se actualizaron.
    expect(find.byKey(const ValueKey('request-arrived')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('new-request-banner-open')));
    await tester.pumpAndSettle();

    expect(find.byType(RequestDetailScreen), findsOneWidget);
    expect(find.byKey(banner), findsNothing);
    expect(app.requests.markedSeen, ['arrived']);
  });

  testWidgets('el aviso aparece aunque esté en la agenda o en otro detalle', (
    tester,
  ) async {
    final app = await pumpChefApp(
      tester,
      requests: FakeChefRequestsRepository([buildRequest()]),
      location: '/agenda',
    );
    expect(find.byType(AgendaScreen), findsOneWidget);

    app.requests.insertFromRealtime(arrived);
    await tester.pumpAndSettle();
    expect(bannerText(tester), 'Nuova richiesta da Marco Bianchi');

    await tester.tap(find.byKey(const ValueKey('new-request-banner-close')));
    await tester.pumpAndSettle();
    expect(find.byKey(banner), findsNothing);

    // Con el detalle de otro pedido abierto.
    app.go('/richieste/req-1');
    await tester.pumpAndSettle();
    app.requests.insertFromRealtime(
      buildRequest(id: 'third', name: 'Anna Verdi', createdAt: DateTime.utc(2026, 10, 19, 13)),
    );
    await tester.pumpAndSettle();
    expect(bannerText(tester), 'Nuova richiesta da Anna Verdi');
  });

  testWidgets('varios pedidos: un aviso con la cantidad que abre la bandeja', (
    tester,
  ) async {
    final app = await pumpChefApp(
      tester,
      requests: FakeChefRequestsRepository([buildRequest()]),
      location: '/agenda',
    );
    app.requests
      ..insertFromRealtime(arrived)
      ..insertFromRealtime(
        buildRequest(id: 'second', name: 'Anna Verdi', createdAt: DateTime.utc(2026, 10, 19, 13)),
      );
    await tester.pumpAndSettle();
    expect(bannerText(tester), '2 nuove richieste');

    await tester.tap(find.byKey(const ValueKey('new-request-banner-open')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('request-second')), findsOneWidget);
    expect(find.byKey(const ValueKey('request-arrived')), findsOneWidget);
  });

  testWidgets('al reconectar avisa lo que llegó sin conexión', (tester) async {
    final app = await pumpChefApp(
      tester,
      requests: FakeChefRequestsRepository([buildRequest()]),
    );
    app.requests.emitRealtime(const RealtimeConnected());
    await tester.pumpAndSettle();
    app.requests
      ..emitRealtime(const RealtimeDisconnected())
      ..insertSilently(arrived)
      ..emitRealtime(const RealtimeConnected());
    await tester.pumpAndSettle();

    expect(bannerText(tester), 'Nuova richiesta da Marco Bianchi');
  });

  testWidgets('abrir el pedido desde la lista cierra su aviso', (tester) async {
    final app = await pumpChefApp(
      tester,
      requests: FakeChefRequestsRepository([buildRequest()]),
    );
    app.requests.insertFromRealtime(arrived);
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('request-arrived')));
    await tester.pumpAndSettle();
    expect(find.byKey(banner), findsNothing);
  });

  testWidgets('en español', (tester) async {
    final app = await pumpChefApp(
      tester,
      requests: FakeChefRequestsRepository([buildRequest()]),
      deviceLocales: const [Locale('es', 'ES')],
    );
    app.requests.insertFromRealtime(arrived);
    await tester.pumpAndSettle();
    expect(bannerText(tester), 'Nueva solicitud de Marco Bianchi');
    expect(find.text('Abrir'), findsOneWidget);
  });

  // Pestaña «Menù» de la web: el aviso dice cuántos platos eligió.
  group('con platos elegidos en la web', () {
    final withMenu = buildRequest(
      id: 'arrived',
      name: 'Marco Bianchi',
      createdAt: DateTime.utc(2026, 10, 19, 12),
      wishes: const ['dish-1', 'dish-2'],
    );

    testWidgets('el aviso lo menciona, con cuántos platos', (tester) async {
      final app = await pumpChefApp(
        tester,
        requests: FakeChefRequestsRepository([buildRequest()]),
      );
      app.requests.insertFromRealtime(withMenu);
      await tester.pumpAndSettle();
      expect(bannerText(tester), 'Nuova richiesta da Marco Bianchi, con 2 piatti scelti dal menù');
    });

    testWidgets('un solo plato', (tester) async {
      final app = await pumpChefApp(
        tester,
        requests: FakeChefRequestsRepository([buildRequest()]),
      );
      app.requests.insertFromRealtime(withMenu.copyWith(wishes: const ['dish-1']));
      await tester.pumpAndSettle();
      expect(bannerText(tester), 'Nuova richiesta da Marco Bianchi, con 1 piatto scelto dal menù');
    });

    testWidgets('varios pedidos: cuántos traen menú', (tester) async {
      final app = await pumpChefApp(
        tester,
        requests: FakeChefRequestsRepository([buildRequest()]),
      );
      app.requests
        ..insertFromRealtime(withMenu)
        ..insertFromRealtime(
          buildRequest(id: 'second', name: 'Anna Verdi', createdAt: DateTime.utc(2026, 10, 19, 13)),
        );
      await tester.pumpAndSettle();
      expect(bannerText(tester), '2 nuove richieste (1 con menù)');
    });

    testWidgets('en español', (tester) async {
      final app = await pumpChefApp(
        tester,
        requests: FakeChefRequestsRepository([buildRequest()]),
        deviceLocales: const [Locale('es', 'ES')],
      );
      app.requests.insertFromRealtime(withMenu);
      await tester.pumpAndSettle();
      expect(bannerText(tester), 'Nueva solicitud de Marco Bianchi, con 2 platos elegidos del menú');
    });
  });
}

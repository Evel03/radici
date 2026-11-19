// Bandeja: pestañas, contador, lista y navegación al detalle.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:radici/features/requests/domain/chef_request.dart';
import 'package:radici/features/requests/presentation/inbox_screen.dart';
import 'package:radici/features/requests/presentation/request_detail_screen.dart';

import '../../../support/chef_app.dart';
import '../../../support/fakes.dart';
import '../../../support/recipe_fixtures.dart';
import '../../../support/request_fixtures.dart';

void main() {
  FakeChefRequestsRepository sample() => FakeChefRequestsRepository([
    // Con platos elegidos en la web y restricciones: las dos marcas en la fila.
    buildRequest(
      id: 'new-1',
      name: 'Giulia Rossi',
      createdAt: DateTime.utc(2026, 10, 19, 9),
      wishes: const [lasagneId, minestroneId],
      restrictions: const RequestRestrictions(allergens: [Allergen.milk]),
    ),
    buildRequest(
      id: 'new-2',
      name: 'Marco Bianchi',
      noDate: true,
      weeks: 4,
      createdAt: DateTime.utc(2026, 10, 19, 8),
    ),
    buildRequest(
      id: 'seen-1',
      name: 'Anna Verdi',
      seenAt: DateTime.utc(2026, 10, 18, 10),
      createdAt: DateTime.utc(2026, 10, 18, 9),
    ),
    buildRequest(
      id: 'rejected-1',
      name: 'Luca Neri',
      status: RequestStatus.rejected,
      seenAt: DateTime.utc(2026, 10, 17, 10),
      createdAt: DateTime.utc(2026, 10, 17, 9),
    ),
  ]);

  Finder tile(String id) => find.byKey(ValueKey('request-$id'));

  testWidgets('nuevas primero, con contador en la pestaña y en la navegación', (
    tester,
  ) async {
    await pumpChefApp(tester, requests: sample());

    expect(find.byType(InboxScreen), findsOneWidget);
    expect(tile('new-1'), findsOneWidget);
    expect(tile('new-2'), findsOneWidget);
    expect(tile('seen-1'), findsNothing);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('inbox-new-count')),
        matching: find.text('2'),
      ),
      findsOneWidget,
    );
    final badge = tester.widget<Badge>(
      find.byKey(const ValueKey('new-requests-badge')).first,
    );
    expect(badge.isLabelVisible, isTrue);

    // Resumen y fecha preferida.
    expect(
      find.descendant(
        of: tile('new-1'),
        matching: find.textContaining('Settimana di pasti · 4 persone · 5 giorni · Cena'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(of: tile('new-2'), matching: find.textContaining('Senza data')),
      findsOneWidget,
    );
    // Un pedido de varias semanas lo dice; uno de una semana, no.
    expect(
      find.descendant(
        of: tile('new-2'),
        matching: find.textContaining('Settimana di pasti · 4 settimane · 4 persone'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(of: tile('new-1'), matching: find.textContaining('settimane')),
      findsNothing,
    );
  });

  // El aviso que pidió Evelyn: se ve en la lista, sin abrir el pedido.
  testWidgets('la fila de un pedido con platos elegidos en la web lleva la marca «menù»', (tester) async {
    await pumpChefApp(tester, requests: sample());

    final mark = find.byKey(const ValueKey('request-menu-new-1'));
    expect(find.descendant(of: tile('new-1'), matching: mark), findsOneWidget);
    expect(find.descendant(of: mark, matching: find.text('menù')), findsOneWidget);
    expect(find.descendant(of: mark, matching: find.byIcon(Icons.restaurant_menu)), findsOneWidget);
    expect(find.byKey(const ValueKey('request-menu-new-2')), findsNothing);
    expect(find.descendant(of: tile('new-2'), matching: find.text('menù')), findsNothing);

    // Lo que lee el lector de pantalla (el árbol semántico): la fila es un solo
    // botón y la marca dice la frase entera, debajo del resumen, no «menù».
    expect(
      tester.getSemantics(tile('new-1')),
      isSemantics(
        label:
            'GR\nGiulia Rossi\nSettimana di pasti · 4 persone · 5 giorni · Cena\n'
            'mer 21 ott · Mattina\nMenù scelto dal cliente\n19/10/2026\nRestrizioni alimentari',
        isButton: true,
      ),
    );
    expect(tester.getSemantics(tile('new-2')).label, isNot(contains('Menù scelto dal cliente')));
  });

  // Texto grande: en el iPhone, los tamaños de accesibilidad empiezan en
  // ≈1.65. ListTile le da al trailing hasta 56 px de alto: la marca no entraba.
  testWidgets('con el texto al doble, a 375 px, la marca entra con y sin restricciones', (tester) async {
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await pumpChefApp(
      tester,
      size: const Size(375, 812),
      requests: FakeChefRequestsRepository([
        buildRequest(
          id: 'menu-restr',
          createdAt: DateTime.utc(2026, 10, 19, 9),
          wishes: const [lasagneId],
          restrictions: const RequestRestrictions(allergens: [Allergen.milk]),
        ),
        buildRequest(
          id: 'menu-only',
          name: 'Marco Bianchi',
          createdAt: DateTime.utc(2026, 10, 19, 8),
          wishes: const [lasagneId],
        ),
      ]),
    );

    expect(tester.takeException(), isNull);
    for (final id in ['menu-restr', 'menu-only']) {
      expect(find.descendant(of: tile(id), matching: find.byKey(ValueKey('request-menu-$id'))), findsOneWidget);
    }
  });

  testWidgets('la marca en español', (tester) async {
    await pumpChefApp(tester, requests: sample(), deviceLocales: const [Locale('es', 'ES')]);
    final mark = find.byKey(const ValueKey('request-menu-new-1'));
    expect(find.descendant(of: mark, matching: find.text('menú')), findsOneWidget);
    final row = tester.getSemantics(tile('new-1')).label.split('\n');
    expect(row, contains('Menú elegido por el cliente'));
    expect(row, isNot(contains('menú')));
  });

  testWidgets('pestañas Viste y Rifiutate', (tester) async {
    await pumpChefApp(tester, requests: sample());

    await tester.tap(find.byKey(const ValueKey('inbox-tab-seen')));
    await tester.pumpAndSettle();
    expect(tile('seen-1'), findsOneWidget);
    expect(tile('new-1'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('inbox-tab-rejected')));
    await tester.pumpAndSettle();
    expect(tile('rejected-1'), findsOneWidget);
  });

  testWidgets('pestañas vacías', (tester) async {
    await pumpChefApp(tester, requests: FakeChefRequestsRepository(const []));
    expect(find.text('Nessuna richiesta nuova.'), findsOneWidget);
    final badge = tester.widget<Badge>(
      find.byKey(const ValueKey('new-requests-badge')).first,
    );
    expect(badge.isLabelVisible, isFalse);
  });

  testWidgets('abrir un pedido lo marca visto y baja el contador', (tester) async {
    final app = await pumpChefApp(tester, requests: sample());

    await tester.tap(tile('new-1'));
    await tester.pumpAndSettle();
    expect(find.byType(RequestDetailScreen), findsOneWidget);
    expect(app.requests.markedSeen, ['new-1']);

    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(tile('new-1'), findsNothing);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('inbox-new-count')),
        matching: find.text('1'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('error al cargar: mensaje y reintentar', (tester) async {
    final requests = sample()..failFetch = true;
    await pumpChefApp(tester, requests: requests);
    expect(
      find.text(
        'Impossibile caricare le richieste. Controlla la connessione e riprova.',
      ),
      findsOneWidget,
    );

    requests.failFetch = false;
    await tester.tap(find.byKey(const ValueKey('load-error-retry')));
    await tester.pumpAndSettle();
    expect(tile('new-1'), findsOneWidget);
  });

  testWidgets('deslizar para actualizar trae pedidos nuevos', (tester) async {
    final app = await pumpChefApp(tester, requests: sample());
    app.requests.insertSilently(
      buildRequest(id: 'late', name: 'Sara Gialli', createdAt: DateTime.utc(2026, 10, 19, 11)),
    );

    await tester.fling(find.byKey(const ValueKey('inbox-list-fresh')), const Offset(0, 400), 1000);
    await tester.pumpAndSettle();
    expect(tile('late'), findsOneWidget);
  });

  testWidgets('pantalla ancha (web en computadora): riel lateral', (tester) async {
    await pumpChefApp(tester, requests: sample(), size: const Size(1200, 800));
    expect(find.byKey(const ValueKey('chef-nav-rail')), findsOneWidget);
    expect(find.byKey(const ValueKey('chef-nav-bar')), findsNothing);
  });

  for (final locale in const [Locale('it'), Locale('es'), Locale('en')]) {
    testWidgets('teléfono angosto sin desbordes (${locale.languageCode})', (
      tester,
    ) async {
      await pumpChefApp(
        tester,
        requests: sample(),
        size: const Size(320, 640),
        deviceLocales: [locale],
      );
      expect(tester.takeException(), isNull);
      expect(tile('new-1'), findsOneWidget);
    });
  }
}

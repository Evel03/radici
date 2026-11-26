// La lista de ofertas de la cocina: el CSV, el repositorio contra la API
// simulada y la pantalla (contar, copiar, descargar y quitar).
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:radici/core/browser.dart';
import 'package:radici/core/router.dart';
import 'package:radici/core/routes.dart';
import 'package:radici/features/auth/data/account_repository.dart';
import 'package:radici/features/auth/data/auth_repository.dart';
import 'package:radici/features/auth/domain/auth_models.dart';
import 'package:radici/features/marketing/data/marketing_contacts_repository.dart';
import 'package:radici/features/marketing/domain/marketing_contact.dart';
import 'package:radici/features/marketing/presentation/marketing_contacts_screen.dart';

import '../../support/browser_fakes.dart';
import '../../support/fakes.dart';
import '../../support/pump_app.dart';
import '../../support/request_fixtures.dart';
import '../../support/supabase_http_fake.dart';

MarketingContact contact(
  String email, {
  MarketingContactStatus status = MarketingContactStatus.confirmed,
  String? name = 'Giulia',
  String locale = 'it',
}) => MarketingContact(
  email: email,
  firstName: name,
  locale: locale,
  status: status,
  requestedAt: DateTime.utc(2026, 11, 26, 9),
  confirmedAt: status == MarketingContactStatus.confirmed
      ? DateTime.utc(2026, 11, 26, 23, 30) // ya 27 en Roma
      : null,
);

class FakeMarketingContactsRepository implements MarketingContactsRepository {
  FakeMarketingContactsRepository(this.contacts);

  List<MarketingContact> contacts;
  bool fail = false;
  final List<String> withdrawn = [];
  int fetches = 0;

  @override
  Future<List<MarketingContact>> fetchContacts({required String chefId}) async {
    fetches++;
    if (fail) throw const MarketingContactsFailure();
    return [...contacts];
  }

  @override
  Future<bool> withdraw(String email) async {
    withdrawn.add(email);
    contacts = contacts.where((c) => c.email != email).toList();
    return true;
  }
}

void main() {
  group('CSV', () {
    test('solo los confirmados, con encabezados, fecha de Roma y CRLF', () {
      final csv = marketingContactsCsv(
        [
          contact('una@example.it'),
          contact('pend@example.it', status: MarketingContactStatus.pending),
          contact('dos@example.it', name: null, locale: 'es'),
        ],
        header: ['Email', 'Nombre', 'Idioma', 'Confirmado el'],
      );
      expect(
        csv,
        'Email,Nombre,Idioma,Confirmado el\r\n'
        'una@example.it,Giulia,it,2026-11-27\r\n'
        'dos@example.it,,es,2026-11-27\r\n',
      );
    });

    test('comillas donde hace falta y nunca una fórmula de planilla', () {
      final csv = marketingContactsCsv(
        [contact('x@example.it', name: '=HYPERLINK("a, b")')],
        header: ['Email', 'Nome', 'Lingua', 'Confermato il'],
      );
      expect(csv.split('\r\n')[1], 'x@example.it,"\'=HYPERLINK(""a, b"")",it,2026-11-27');
    });
  });

  group('repositorio', () {
    test('lee la tabla con la RLS de la cocina: sin el hash ni el pedido, sin las bajas', () async {
      final server = FakeSupabaseHttp(
        (_) async => jsonResponse([
          {
            'email': 'una@example.it',
            'first_name': 'Giulia',
            'locale': 'it',
            'status': 'confirmed',
            'requested_at': '2026-11-26T09:00:00Z',
            'confirmed_at': '2026-11-26T10:00:00Z',
          },
        ]),
      );
      addTearDown(server.dispose);
      final list = await SupabaseMarketingContactsRepository(server.client).fetchContacts(chefId: 'chef-1');
      expect(list.single.email, 'una@example.it');
      expect(list.single.status, MarketingContactStatus.confirmed);
      final url = server.last.url;
      expect(url.path, '/rest/v1/marketing_contacts');
      expect(url.queryParameters['select'], 'email,first_name,locale,status,requested_at,confirmed_at');
      expect(url.queryParameters['select'], isNot(contains('token')));
      expect(url.queryParameters['chef_id'], 'eq.chef-1');
      expect(url.queryParameters['status'], 'in.("pending","confirmed")');
    });

    test('quitar: la rpc de la cocina con el email', () async {
      final server = FakeSupabaseHttp((_) async => http.Response('true', 200, headers: {'content-type': 'application/json'}));
      addTearDown(server.dispose);
      expect(await SupabaseMarketingContactsRepository(server.client).withdraw('una@example.it'), isTrue);
      expect(server.last.url.path, '/rest/v1/rpc/chef_marketing_withdraw');
      expect(jsonBodyOf(server.last), {'p_email': 'una@example.it'});
    });

    test('un error de la API: MarketingContactsFailure', () async {
      final server = FakeSupabaseHttp((_) async => jsonResponse({'message': 'boom'}, status: 500));
      addTearDown(server.dispose);
      await expectLater(
        SupabaseMarketingContactsRepository(server.client).fetchContacts(chefId: 'c'),
        throwsA(isA<MarketingContactsFailure>()),
      );
    });
  });

  group('pantalla', () {
    late FakeMarketingContactsRepository repo;
    late FakeBrowser browser;
    String? clipboard;

    Future<void> pumpScreen(WidgetTester tester, {bool isWeb = true}) async {
      setSurfaceSize(tester, const Size(500, 1200));
      browser = FakeBrowser();
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') {
          clipboard = (call.arguments as Map)['text'] as String?;
        }
        return null;
      });
      addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
      final container = await pumpRadiciApp(
        tester,
        isWeb: isWeb,
        overrides: [
          authRepositoryProvider.overrideWithValue(
            FakeAuthRepository(user: const AppUser(id: 'chef-user', email: 'evelyn@example.test')),
          ),
          accountRepositoryProvider.overrideWithValue(FakeAccountRepository(chefAccountData)),
          marketingContactsRepositoryProvider.overrideWithValue(repo),
          browserProvider.overrideWithValue(browser),
        ],
      );
      container.read(routerProvider).go(AppRoutes.more);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('more-marketing')));
      await tester.pumpAndSettle();
      expect(find.byType(MarketingContactsScreen), findsOneWidget);
    }

    testWidgets('cuenta confirmados y pendientes, copia los confirmados para Ccn y descarga el CSV', (tester) async {
      repo = FakeMarketingContactsRepository([
        contact('una@example.it'),
        contact('dos@example.it'),
        contact('pend@example.it', status: MarketingContactStatus.pending),
      ]);
      await pumpScreen(tester);
      expect(find.text('2 confermati · 1 in attesa di conferma'), findsOneWidget);
      expect(find.text('Giulia · IT · confermato il 27/11/2026'), findsNWidgets(2));

      await tester.tap(find.byKey(const ValueKey('marketing-copy')));
      await tester.pumpAndSettle();
      expect(clipboard, 'una@example.it, dos@example.it', reason: 'sin el pendiente');
      expect(find.text('2 indirizzi copiati'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('marketing-download')));
      await tester.pumpAndSettle();
      final (name, text, mime) = browser.downloads.single;
      expect(name, startsWith('radici-contatti-'));
      expect(name, endsWith('.csv'));
      expect(mime, 'text/csv;charset=utf-8');
      expect(text, startsWith('Email,Nome,Lingua,Confermato il\r\n'));
      expect(text, isNot(contains('pend@example.it')));
    });

    testWidgets('en el teléfono no hay «Scarica CSV» (sí copiar)', (tester) async {
      repo = FakeMarketingContactsRepository([contact('una@example.it')]);
      await pumpScreen(tester, isWeb: false);
      expect(find.byKey(const ValueKey('marketing-download')), findsNothing);
      expect(find.byKey(const ValueKey('marketing-copy')), findsOneWidget);
    });

    testWidgets('quitar a alguien: pide confirmación, llama a la rpc y vuelve a leer', (tester) async {
      repo = FakeMarketingContactsRepository([contact('una@example.it'), contact('dos@example.it')]);
      await pumpScreen(tester);
      final before = repo.fetches;
      await tester.tap(find.byKey(const ValueKey('marketing-withdraw-una@example.it')));
      await tester.pumpAndSettle();
      expect(find.text('Togliere una@example.it dalla lista?'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('marketing-withdraw-confirm')));
      await tester.pumpAndSettle();
      expect(repo.withdrawn, ['una@example.it']);
      expect(repo.fetches, greaterThan(before));
      expect(find.byKey(const ValueKey('marketing-contact-una@example.it')), findsNothing);
      expect(find.text('Tolto dalla lista.'), findsOneWidget);
    });

    testWidgets('vacía: lo dice, y sin nada que copiar', (tester) async {
      repo = FakeMarketingContactsRepository([]);
      await pumpScreen(tester);
      expect(find.byKey(const ValueKey('marketing-empty')), findsOneWidget);
      expect(tester.widget<ButtonStyleButton>(find.byKey(const ValueKey('marketing-copy'))).onPressed, isNull);
    });

    testWidgets('si no carga: el aviso y «Riprova»', (tester) async {
      repo = FakeMarketingContactsRepository([contact('una@example.it')])..fail = true;
      await pumpScreen(tester);
      expect(find.byKey(const ValueKey('marketing-load-failed')), findsOneWidget);
      repo.fail = false;
      await tester.tap(find.text('Riprova'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('marketing-contact-una@example.it')), findsOneWidget);
    });
  });
}

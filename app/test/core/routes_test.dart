// Redirecciones según la sesión (core/routes.dart).
import 'package:flutter_test/flutter_test.dart';
import 'package:radici/core/rome_time.dart';
import 'package:radici/core/routes.dart';
import 'package:radici/features/auth/application/session_controller.dart';
import 'package:radici/features/auth/domain/auth_models.dart';

import '../support/request_fixtures.dart';

String? _redirect(SessionState session, String location, {bool isWeb = false}) =>
    resolveRedirect(session: session, location: Uri.parse(location), isWeb: isWeb);

void main() {
  const signedOut = SessionState.signedOut();
  const loading = SessionState.loading(chefUser);
  const failed = SessionState.failed(chefUser, AccountFailureKind.unavailable);
  const chef = SessionState.chef(chefUser, chefAccount);
  const client = SessionState.client(AppUser(id: 'client', email: 'c@x.test'));

  group('sin sesión', () {
    test('el área de la cocinera pide login y recuerda a dónde iba', () {
      expect(_redirect(signedOut, '/richieste'), '/accedi?from=%2Frichieste');
      expect(
        _redirect(signedOut, '/richieste/abc'),
        '/accedi?from=%2Frichieste%2Fabc',
      );
      expect(_redirect(signedOut, '/agenda'), '/accedi?from=%2Fagenda');
      expect(
        _redirect(signedOut, '/impostazioni'),
        '/accedi?from=%2Fimpostazioni',
      );
    });

    test('móvil: el inicio y la calculadora son públicos', () {
      expect(_redirect(signedOut, '/'), isNull);
      expect(_redirect(signedOut, '/preventivo'), isNull);
      expect(_redirect(signedOut, '/accedi'), isNull);
      expect(_redirect(signedOut, '/area-clienti'), '/');
      expect(_redirect(signedOut, '/caricamento'), '/');
    });

    test('web (/gestione/): no hay inicio público, `/` es el login', () {
      expect(_redirect(signedOut, '/', isWeb: true), '/accedi');
      expect(_redirect(signedOut, '/caricamento', isWeb: true), '/accedi');
      expect(_redirect(signedOut, '/accedi', isWeb: true), isNull);
    });
  });

  group('cargando la cuenta o con error', () {
    test('todo va a la pantalla de carga, conservando el destino', () {
      for (final session in [loading, failed]) {
        expect(_redirect(session, '/caricamento'), isNull);
        expect(_redirect(session, '/'), '/caricamento');
        expect(
          _redirect(session, '/accedi?from=%2Frichieste%2Fabc'),
          '/caricamento?from=%2Frichieste%2Fabc',
        );
        expect(
          _redirect(session, '/richieste/abc'),
          '/caricamento?from=%2Frichieste%2Fabc',
        );
      }
    });
  });

  group('cocinera', () {
    test('se queda en su área', () {
      expect(_redirect(chef, '/oggi'), isNull);
      expect(_redirect(chef, '/richieste'), isNull);
      expect(_redirect(chef, '/richieste/abc'), isNull);
      expect(_redirect(chef, '/agenda'), isNull);
      expect(_redirect(chef, '/impostazioni'), isNull);
      expect(_redirect(chef, '/accedi?from=%2Fimpostazioni'), '/impostazioni');
    });

    test('la pestaña «Altro» y el catálogo de platos son de su área', () {
      for (final path in [
        '/altro',
        '/altro/piatti',
        '/altro/piatti/nuovo',
        '/altro/piatti/nuovo?copia=abc',
        '/altro/piatti/abc',
      ]) {
        expect(_redirect(chef, path), isNull, reason: path);
        expect(
          _redirect(signedOut, path),
          '/accedi?from=${Uri.encodeQueryComponent(path)}',
          reason: path,
        );
        expect(_redirect(client, path), '/area-clienti', reason: path);
      }
      expect(_redirect(chef, '/accedi?from=%2Faltro%2Fpiatti'), '/altro/piatti');
      expect(_redirect(chef, '/altrove'), '/oggi');
    });

    test('desde el inicio, el login o la carga va a Hoy (o a donde iba)', () {
      for (final web in [false, true]) {
        expect(_redirect(chef, '/', isWeb: web), '/oggi');
        expect(_redirect(chef, '/accedi', isWeb: web), '/oggi');
        expect(_redirect(chef, '/caricamento', isWeb: web), '/oggi');
        expect(_redirect(chef, '/area-clienti', isWeb: web), '/oggi');
      }
      // El botón del email abre el pedido, también después del login.
      expect(
        _redirect(chef, '/caricamento?from=%2Frichieste%2Fabc'),
        '/richieste/abc',
      );
      expect(
        _redirect(chef, '/accedi?from=%2Frichieste%2Fabc'),
        '/richieste/abc',
      );
      expect(_redirect(chef, '/accedi?from=%2Fagenda'), '/agenda');
    });

    test('`from` solo acepta rutas internas de la cocinera', () {
      expect(
        _redirect(chef, '/accedi?from=https%3A%2F%2Fevil.example%2Frichieste'),
        '/oggi',
      );
      expect(_redirect(chef, '/accedi?from=%2F%2Fevil.example'), '/oggi');
      expect(_redirect(chef, '/accedi?from=%2Fpreventivo'), '/oggi');
    });

    test('Hoy (/oggi) es del área de la cocinera', () {
      expect(AppRoutes.today, '/oggi');
      expect(isChefPath('/oggi'), isTrue);
      expect(isChefPath('/oggi/abc'), isFalse);
      expect(_redirect(signedOut, '/oggi'), '/accedi?from=%2Foggi');
      expect(_redirect(loading, '/oggi'), '/caricamento?from=%2Foggi');
      expect(_redirect(client, '/oggi'), '/area-clienti');
      expect(_redirect(chef, '/accedi?from=%2Foggi'), '/oggi');
    });
  });

  group('cliente', () {
    test('siempre al área de clientes (salvo la calculadora)', () {
      expect(_redirect(client, '/area-clienti'), isNull);
      expect(_redirect(client, '/'), '/area-clienti');
      expect(_redirect(client, '/richieste'), '/area-clienti');
      expect(_redirect(client, '/impostazioni'), '/area-clienti');
      expect(_redirect(client, '/accedi'), '/area-clienti');
      expect(_redirect(client, '/preventivo'), isNull);
    });
  });

  test('requestDetail codifica el id', () {
    expect(AppRoutes.requestDetail('abc'), '/richieste/abc');
    expect(AppRoutes.requestDetail('a/b'), '/richieste/a%2Fb');
  });

  test('la ficha de una sesión y su hoja «Sposta» son del área de la cocinera', () {
    expect(AppRoutes.sessionDetail('abc'), '/sessioni/abc');
    expect(AppRoutes.sessionDetail('a/b'), '/sessioni/a%2Fb');
    expect(AppRoutes.sessionMove('abc'), '/sessioni/abc/sposta');
    expect(
      AppRoutes.sessionMove('a/b', date: CalendarDate(2026, 12, 3)),
      '/sessioni/a%2Fb/sposta?data=2026-12-03',
    );
    for (final path in ['/sessioni/abc', '/sessioni/abc/sposta']) {
      expect(isChefPath(path), isTrue, reason: path);
      expect(_redirect(chef, path), isNull, reason: path);
    }
    // Con la fecha en la URL, también vuelve ahí después de entrar.
    expect(
      _redirect(signedOut, '/sessioni/abc/sposta?data=2026-12-03'),
      '/accedi?from=%2Fsessioni%2Fabc%2Fsposta%3Fdata%3D2026-12-03',
    );
    expect(
      _redirect(chef, '/accedi?from=%2Fsessioni%2Fabc'),
      '/sessioni/abc',
    );
    // Sin id no es una ruta (ni del área).
    expect(isChefPath('/sessioni'), isFalse);
    expect(_redirect(client, '/sessioni/abc'), '/area-clienti');
  });

  test('la hoja «Conferma prenotazione» cuelga del detalle y es del área de la cocinera', () {
    expect(AppRoutes.requestBooking('abc'), '/richieste/abc/prenota');
    expect(AppRoutes.requestBooking('a/b'), '/richieste/a%2Fb/prenota');
    expect(isChefPath('/richieste/abc/prenota'), isTrue);
    expect(_redirect(chef, '/richieste/abc/prenota'), isNull);
    expect(
      _redirect(signedOut, '/richieste/abc/prenota'),
      '/accedi?from=%2Frichieste%2Fabc%2Fprenota',
    );
  });

  test('«Nuova prenotazione»: el elegir, «Nuova cliente» y la hoja a mano, con solo ids en la URL', () {
    expect(AppRoutes.newBooking, '/richieste/nuova');
    expect(AppRoutes.newBookingNewClient, '/richieste/nuova/cliente');
    expect(AppRoutes.newBookingSheet(), '/richieste/nuova/prenota');
    expect(
      AppRoutes.newBookingSheet(clientId: 'x'),
      '/richieste/nuova/prenota?cliente=x',
    );
    expect(
      AppRoutes.newBookingSheet(clientId: 'x', fromForm: true),
      '/richieste/nuova/prenota?cliente=x&modulo=1',
    );
    for (final path in [
      AppRoutes.newBooking,
      AppRoutes.newBookingNewClient,
      AppRoutes.newBookingSheet(),
      AppRoutes.newBookingSheet(clientId: 'x', fromForm: true),
    ]) {
      expect(isChefPath(Uri.parse(path).path), isTrue, reason: path);
      expect(_redirect(chef, path), isNull, reason: path);
    }
    expect(
      _redirect(signedOut, '/richieste/nuova/prenota?cliente=x'),
      '/accedi?from=%2Frichieste%2Fnuova%2Fprenota%3Fcliente%3Dx',
    );
    expect(
      _redirect(signedOut, '/richieste/nuova'),
      '/accedi?from=%2Frichieste%2Fnuova',
    );
  });

  test('rutas del catálogo de platos', () {
    expect(AppRoutes.more, '/altro');
    expect(AppRoutes.recipes, '/altro/piatti');
    expect(AppRoutes.recipeNew, '/altro/piatti/nuovo');
    expect(AppRoutes.recipeEdit('abc'), '/altro/piatti/abc');
    expect(AppRoutes.recipeEdit('a/b'), '/altro/piatti/a%2Fb');
    expect(AppRoutes.recipeCopy('abc'), '/altro/piatti/nuovo?copia=abc');
  });
}

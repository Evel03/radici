// Redirecciones según la sesión (core/routes.dart).
import 'package:flutter_test/flutter_test.dart';
import 'package:mestolo/core/routes.dart';
import 'package:mestolo/features/auth/application/session_controller.dart';
import 'package:mestolo/features/auth/domain/auth_models.dart';

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
      expect(_redirect(chef, '/richieste'), isNull);
      expect(_redirect(chef, '/richieste/abc'), isNull);
      expect(_redirect(chef, '/agenda'), isNull);
    });

    test('desde el inicio, el login o la carga va a la bandeja (o a donde iba)', () {
      expect(_redirect(chef, '/'), '/richieste');
      expect(_redirect(chef, '/accedi'), '/richieste');
      expect(_redirect(chef, '/area-clienti'), '/richieste');
      expect(
        _redirect(chef, '/caricamento?from=%2Frichieste%2Fabc'),
        '/richieste/abc',
      );
      expect(_redirect(chef, '/accedi?from=%2Fagenda'), '/agenda');
    });

    test('`from` solo acepta rutas internas de la cocinera', () {
      expect(
        _redirect(chef, '/accedi?from=https%3A%2F%2Fevil.example%2Frichieste'),
        '/richieste',
      );
      expect(_redirect(chef, '/accedi?from=%2F%2Fevil.example'), '/richieste');
      expect(_redirect(chef, '/accedi?from=%2Fpreventivo'), '/richieste');
    });
  });

  group('cliente', () {
    test('siempre al área de clientes (salvo la calculadora)', () {
      expect(_redirect(client, '/area-clienti'), isNull);
      expect(_redirect(client, '/'), '/area-clienti');
      expect(_redirect(client, '/richieste'), '/area-clienti');
      expect(_redirect(client, '/accedi'), '/area-clienti');
      expect(_redirect(client, '/preventivo'), isNull);
    });
  });

  test('requestDetail codifica el id', () {
    expect(AppRoutes.requestDetail('abc'), '/richieste/abc');
    expect(AppRoutes.requestDetail('a/b'), '/richieste/a%2Fb');
  });
}

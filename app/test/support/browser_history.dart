// El historial del navegador de /gestione/, como MultiEntriesBrowserHistory
// del motor web: cada `routeInformationUpdated` sin `replace` apila una
// entrada y con `replace` reemplaza la última; el atrás saca la última y manda
// `pushRouteInformation` con la ubicación y el estado de la anterior (lo mismo
// que onPopState). Así llega a la app el atrás del navegador (el botón, el
// gesto de Safari o el atrás de Android en la PWA): por
// GoRouterDelegate.setNewRoutePath, sin pasar por PopScope.
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

class FakeBrowserHistory {
  /// Las entradas del historial, la última es la actual.
  final List<({String uri, Object? state})> entries = [];

  /// Empieza a anotar lo que informa el router (hasta el final del test).
  void install(WidgetTester tester) {
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.navigation, (call) async {
      if (call.method == 'routeInformationUpdated') {
        final args = call.arguments as Map<Object?, Object?>;
        final entry = (uri: args['uri']! as String, state: args['state']);
        if (args['replace'] == true && entries.isNotEmpty) {
          entries[entries.length - 1] = entry;
        } else {
          entries.add(entry);
        }
      }
      return null;
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(SystemChannels.navigation, null),
    );
  }

  /// El atrás del navegador. Con [settle] en false no espera a que la
  /// pantalla se asiente (una rueda que gira no se asienta nunca).
  Future<void> back(WidgetTester tester, {bool settle = true}) async {
    entries.removeLast();
    final previous = entries.last;
    await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
      SystemChannels.navigation.name,
      const JSONMethodCodec().encodeMethodCall(
        MethodCall('pushRouteInformation', <String, Object?>{
          'location': previous.uri,
          'state': previous.state,
        }),
      ),
      (_) {},
    );
    if (settle) {
      await tester.pumpAndSettle();
    } else {
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
    }
  }
}

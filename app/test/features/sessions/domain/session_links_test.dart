// «Cómo llegar»: el enlace a Mapas (Apple Maps en el iPhone, Google Maps en
// el resto) hasta la dirección de la ficha, como está, o, si no tiene, hasta
// la zona del pedido con la ciudad (Bergamo, una sola vez), y hasta dónde
// lleva. Ni la dirección ni la zona se imprimen.
import 'package:flutter_test/flutter_test.dart';
import 'package:radici/features/sessions/domain/session_links.dart';

void main() {
  group('el enlace', () {
    const address = 'Via Gombito 12, 24129 Bergamo';

    test('en el iPhone, Apple Maps con el camino hasta la dirección', () {
      expect(
        directionsUri(destination: address, apple: true).toString(),
        'https://maps.apple.com/?daddr=Via%20Gombito%2012%2C%2024129%20Bergamo',
      );
    });

    test('en Android y en el resto, Google Maps', () {
      expect(
        directionsUri(destination: address, apple: false).toString(),
        'https://www.google.com/maps/dir/?api=1&destination=Via%20Gombito%2012%2C%2024129%20Bergamo',
      );
    });

    test('sin destino, nada que abrir', () {
      expect(directionsUri(destination: null, apple: true), isNull);
      expect(directionsUri(destination: '   ', apple: false), isNull);
    });

    test(
      'un & o un # no cortan el enlace, en Apple Maps ni en Google Maps',
      () {
        const destination = 'Via A & B #3';
        expect(
          directionsUri(
            destination: destination,
            apple: true,
          )!.queryParameters['daddr'],
          destination,
        );
        final google = directionsUri(destination: destination, apple: false)!;
        expect(google.queryParameters['destination'], destination);
        expect(google.queryParameters['api'], '1');
      },
    );
  });

  group('la zona como destino: con la ciudad, una sola vez', () {
    test('suma «, Bergamo» a una zona que no la nombra', () {
      expect(serviceCity, 'Bergamo');
      expect(zoneDestination('Città Alta'), 'Città Alta, Bergamo');
      expect(
        zoneDestination('Via Gabriele Camozzi 50'),
        'Via Gabriele Camozzi 50, Bergamo',
      );
    });

    test('si ya la nombra, con mayúsculas o sin ellas, queda como está', () {
      for (final zone in [
        'Bergamo',
        'Città Alta, Bergamo',
        'bergamo bassa',
        'Via Roma 1, 24121 BERGAMO',
      ]) {
        expect(zoneDestination(zone), zone);
      }
    });

    test('sin espacios de más; vacía o null, ninguna', () {
      expect(zoneDestination('  Loreto  '), 'Loreto, Bergamo');
      expect(zoneDestination('   '), isNull);
      expect(zoneDestination(null), isNull);
    });
  });

  group('hasta dónde: la dirección de la ficha o, sin ella, la zona', () {
    test('con dirección, hasta la dirección, como está: la zona no cuenta', () {
      for (final apple in [false, true]) {
        final directions = sessionDirections(
          address: 'Via Pignolo 5',
          zone: 'Città Alta',
          apple: apple,
        )!;
        expect(directions.target, DirectionsTarget.address);
        expect(
          directions.uri.host,
          apple ? 'maps.apple.com' : 'www.google.com',
        );
        // Sin la ciudad: la dirección va como está en la ficha.
        expect(
          directions.uri.queryParameters[apple ? 'daddr' : 'destination'],
          'Via Pignolo 5',
        );
      }
    });

    test('sin dirección, hasta la zona con la ciudad, en Apple Maps o en Google Maps', () {
      for (final apple in [false, true]) {
        final directions = sessionDirections(
          address: null,
          zone: 'Via Gabriele Camozzi 50',
          apple: apple,
        )!;
        expect(directions.target, DirectionsTarget.zone);
        expect(
          directions.uri.toString(),
          apple
              ? 'https://maps.apple.com/?daddr=Via%20Gabriele%20Camozzi%2050%2C%20Bergamo'
              : 'https://www.google.com/maps/dir/?api=1&destination=Via%20Gabriele%20Camozzi%2050%2C%20Bergamo',
        );
      }
    });

    test('una zona que ya nombra Bergamo no la repite', () {
      expect(
        sessionDirections(
          address: null,
          zone: 'Borgo Palazzo, Bergamo',
          apple: false,
        )!.uri.queryParameters['destination'],
        'Borgo Palazzo, Bergamo',
      );
    });

    test('una dirección en blanco es como no tenerla', () {
      expect(
        sessionDirections(address: '  ', zone: 'Loreto', apple: false)!.target,
        DirectionsTarget.zone,
      );
    });

    test('un & o un # en la zona no cortan el enlace', () {
      expect(
        sessionDirections(
          address: null,
          zone: 'Borgo Palazzo & C. #2',
          apple: true,
        )!.uri.queryParameters['daddr'],
        'Borgo Palazzo & C. #2, Bergamo',
      );
    });

    test('sin dirección ni zona, nada que abrir', () {
      expect(sessionDirections(address: null, zone: null, apple: true), isNull);
      expect(sessionDirections(address: ' ', zone: '  ', apple: false), isNull);
    });

    test('no se imprime: ni la dirección ni la zona', () {
      final toAddress = sessionDirections(
        address: 'Via Gombito 12',
        zone: null,
        apple: false,
      );
      final toZone = sessionDirections(
        address: null,
        zone: 'Città Alta',
        apple: false,
      );
      expect('$toAddress', 'SessionDirections(address)');
      expect('$toZone', 'SessionDirections(zone)');
    });
  });
}

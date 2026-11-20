// Búsqueda de fichas en «Nuova prenotazione»: por nombre (sin mayúsculas,
// acentos ni apóstrofos) o por teléfono (también pegado del iPhone), el orden
// (las que no son prospecto primero, después el pedido semanal más reciente),
// el teléfono repetido y lo que se prellena en «Nuova cliente».
import 'package:flutter_test/flutter_test.dart';
import 'package:radici/features/clients/domain/chef_client.dart';
import 'package:radici/features/clients/domain/client_search.dart';
import 'package:radici/features/requests/domain/chef_request.dart';

import '../../../support/client_fixtures.dart';

void main() {
  final giulia = buildClient(
    id: 'c-giulia',
    name: 'Giulia Rossi',
    phone: '+39 333 123 4567',
  );
  final nicolo = buildClient(id: 'c-nicolo', name: 'Nicolò Bianchi', phone: null);
  final damico = buildClient(id: 'c-damico', name: "Anna D'Amico", phone: null);
  final dangelo = buildClient(
    id: 'c-dangelo',
    name: 'Marta D\u2019Angelo',
    phone: null,
  );
  final dashed = buildClient(id: 'c-dashed', name: 'Sara Verdi', phone: '333-123-4567');

  List<String> idsMatching(String query, [List<ChefClient>? clients]) => [
    for (final client in clients ?? [giulia, nicolo, damico, dangelo])
      if (clientMatchesQuery(client, query)) client.id,
  ];

  group('por nombre', () {
    test('vacía: todas', () {
      expect(idsMatching(''), hasLength(4));
      expect(idsMatching('   '), hasLength(4));
      expect(idsMatching('\u200e'), hasLength(4));
    });

    test('sin mayúsculas ni acentos, con varias palabras en cualquier orden', () {
      expect(idsMatching('giu ros'), ['c-giulia']);
      expect(idsMatching('ROSSI giulia'), ['c-giulia']);
      expect(idsMatching('nicolo'), ['c-nicolo']);
      expect(idsMatching('giulia verdi'), isEmpty);
    });

    test('sin apóstrofos: el \u2019 del iPhone, el \' y sin ninguno', () {
      expect(idsMatching('d\u2019amico'), ['c-damico']);
      expect(idsMatching('damico'), ['c-damico']);
      expect(idsMatching("d'amico"), ['c-damico']);
      expect(idsMatching("d'angelo"), ['c-dangelo']);
      expect(idsMatching('dangelo'), ['c-dangelo']);
    });
  });

  group('por teléfono', () {
    test('con 3 dígitos o más, con o sin prefijo', () {
      for (final query in ['333 123', '+39 333123', '0039 333', '4567']) {
        expect(idsMatching(query), ['c-giulia'], reason: query);
      }
    });

    test('uno guardado con guiones', () {
      expect(idsMatching('3331234567', [dashed, nicolo]), ['c-dashed']);
    });

    test('pegado entre marcas invisibles: modo teléfono', () {
      expect(idsMatching('\u202a+39 333 123 4567\u202c'), ['c-giulia']);
      expect(idsMatching('\u200e333 123'), ['c-giulia']);
    });

    test('con 2 dígitos busca por nombre', () {
      expect(idsMatching('33'), isEmpty);
      final agency = buildClient(id: 'c-33', name: 'Studio 33', phone: null);
      expect(idsMatching('33', [giulia, agency]), ['c-33']);
    });

    test('una ficha sin teléfono no coincide con un número', () {
      expect(idsMatching('333 123', [nicolo]), isEmpty);
    });
  });

  group('orden', () {
    test('una ficha que no es prospecto va antes que su prospecto gemelo', () {
      final twin = buildClient(
        id: 'a-twin',
        name: 'Giulia Rossi',
        status: ClientStatus.prospect,
        latestWeekly: buildLatestWeekly(createdAt: DateTime.utc(2026, 11, 15)),
      );
      final view = clientPickerView([twin, giulia]);
      expect([for (final c in view.matches) c.id], ['c-giulia', 'a-twin']);
    });

    test('entre iguales, el pedido semanal más reciente primero; después nombre plegado e id', () {
      final older = buildClient(
        id: 'p-older',
        name: 'Anna Bianchi',
        status: ClientStatus.prospect,
        latestWeekly: buildLatestWeekly(createdAt: DateTime.utc(2026, 11, 1)),
      );
      final newer = buildClient(
        id: 'p-newer',
        name: 'Zoe Neri',
        status: ClientStatus.prospect,
        latestWeekly: buildLatestWeekly(createdAt: DateTime.utc(2026, 11, 10)),
      );
      final none = buildClient(id: 'p-none', name: 'Bea Conti', status: ClientStatus.prospect);
      final accented = buildClient(id: 'p-acc', name: 'Èlia Conti', status: ClientStatus.prospect);
      final sameB = buildClient(id: 'p-b', name: 'Elia Conti', status: ClientStatus.prospect);
      final view = clientPickerView([none, sameB, older, accented, newer]);
      expect([for (final c in view.matches) c.id], [
        'p-newer',
        'p-older',
        'p-none',
        // «Èlia» y «Elia» se pliegan igual: decide el id.
        'p-acc',
        'p-b',
      ]);
    });

    test('total: todas las fichas, coincidan o no', () {
      final view = clientPickerView([giulia, nicolo, damico], query: 'giulia');
      expect([for (final c in view.matches) c.id], ['c-giulia']);
      expect(view.total, 3);
      expect(clientPickerView(const []).total, 0);
    });
  });

  group('findClientByPhone', () {
    test('igualdad exacta del E.164, también guardado de otra forma', () {
      expect(findClientByPhone([nicolo, dashed], '+393331234567')?.id, 'c-dashed');
      expect(findClientByPhone([giulia], '+39333123456'), isNull);
      expect(findClientByPhone([nicolo], '+393331234567'), isNull);
      final invalid = buildClient(id: 'c-bad', phone: '612 345 678');
      expect(findClientByPhone([invalid], '+34612345678'), isNull);
    });

    test('con una ficha y su prospecto gemelo, la que no es prospecto', () {
      for (final twinId in ['0-before', 'z-after']) {
        final twin = buildClient(
          id: twinId,
          name: 'Aaa Rossi',
          phone: '333 123 4567',
          status: ClientStatus.prospect,
          latestWeekly: buildLatestWeekly(createdAt: DateTime.utc(2026, 11, 16)),
        );
        expect(findClientByPhone([twin, giulia], '+393331234567')?.id, 'c-giulia');
        expect(findClientByPhone([giulia, twin], '+393331234567')?.id, 'c-giulia');
      }
    });
  });

  group('newClientPrefill', () {
    test('un nombre va al nombre, con los espacios colapsados', () {
      expect(newClientPrefill('Giulia'), (name: 'Giulia', phone: null));
      expect(newClientPrefill('  Giulia   Rossi '), (name: 'Giulia Rossi', phone: null));
    });

    test('lo que parece un teléfono va al teléfono, nunca al nombre', () {
      for (final query in ['333 123 4567', '333 12', '+39']) {
        expect(newClientPrefill(query), (name: null, phone: query), reason: query);
      }
      expect(
        newClientPrefill('\u202a+39 333 123 4567\u202c'),
        (name: null, phone: '+39 333 123 4567'),
      );
    });

    test('vacía: nada', () {
      expect(newClientPrefill('  '), (name: null, phone: null));
      expect(newClientPrefill(''), (name: null, phone: null));
    });
  });
}

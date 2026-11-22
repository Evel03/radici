// El envío del menú en Dart puro: las filas de menu_sends (y el último que
// salió de cada semana, como en la base), el estado de una semana (sin
// mandar, mandado, confirmado, cambios pedidos y «cambió después de
// mandarlo»), el contacto (qué canal sirve), y lo que la app manda y lee de
// POST chef/menus/preview y chef/menus/send (contrato chef-api §13). Nada se
// imprime: ni el contacto, ni el mensaje, ni lo que escribió la clienta.
import 'package:flutter_test/flutter_test.dart';
import 'package:radici/features/requests/domain/chef_request.dart'
    show ClientLocale;
import 'package:radici/features/sessions/domain/cooking_session.dart';
import 'package:radici/features/week_menu/domain/menu_send.dart';
import 'package:radici/features/week_menu/domain/week_menu.dart';

import '../../../support/menu_send_fakes.dart';
import '../../../support/session_fixtures.dart';

void main() {
  Map<String, dynamic> row({
    String id = 'aaaaaaaa-0000-4000-8000-000000000001',
    Object? session,
    Object? version = 2,
    Object? sentAt = '2026-11-22T13:32:00.123456+00:00',
    Object? via = const ['email', 'whatsapp'],
    Object? confirmedAt,
    Object? changesAt,
    Object? changesText,
  }) => {
    'id': id,
    'session_id': session ?? sessionId(1),
    'menu_version': version,
    'sent_at': sentAt,
    'sent_via': via,
    'client_confirmed_at': confirmedAt,
    'changes_requested_at': changesAt,
    'changes_text': changesText,
  };

  group('MenuSendRecord.fromRow', () {
    test('lee la fila: la versión, cuándo (UTC) y por dónde, en el orden de la base', () {
      final record = MenuSendRecord.fromRow(
        row(via: const ['whatsapp', 'email']),
      );
      expect(record.id, 'aaaaaaaa-0000-4000-8000-000000000001');
      expect(record.sessionId, sessionId(1));
      expect(record.menuVersion, 2);
      expect(record.sentAt, DateTime.utc(2026, 11, 22, 13, 32, 0, 123, 456));
      expect(record.via, [MenuSendChannel.email, MenuSendChannel.whatsapp]);
      expect(record.confirmedAt, isNull);
      expect(record.changesRequestedAt, isNull);
    });

    test(
      'la respuesta de la clienta: confirmado o cambios pedidos con su mensaje',
      () {
        final confirmed = MenuSendRecord.fromRow(
          row(confirmedAt: '2026-11-23T08:15:00+00:00'),
        );
        expect(confirmed.confirmedAt, DateTime.utc(2026, 11, 23, 8, 15));
        final changes = MenuSendRecord.fromRow(
          row(
            changesAt: '2026-11-23T08:15:00+00:00',
            changesText: 'Sin cebolla, por favor.\nY más verduras.',
          ),
        );
        expect(changes.changesRequestedAt, DateTime.utc(2026, 11, 23, 8, 15));
        expect(changes.changesText, 'Sin cebolla, por favor.\nY más verduras.');
      },
    );

    final broken = <(String, Map<String, dynamic>)>[
      ('sin sent_at (no salió)', row(sentAt: null)),
      ('una fecha que no es fecha', row(sentAt: 'ayer')),
      ('sin canales', row(via: const <String>[])),
      ('un canal que no existe', row(via: const ['sms'])),
      ('un canal repetido', row(via: const ['email', 'email'])),
      ('tres canales', row(via: const ['email', 'whatsapp', 'email'])),
      ('versión 0', row(version: 0)),
      ('versión que no es entera', row(version: '2')),
      (
        'cambios pedidos sin el mensaje',
        row(changesAt: '2026-11-23T08:15:00+00:00'),
      ),
      ('un mensaje sin cambios pedidos', row(changesText: 'Hola')),
      ('una sesión que no es texto', row(session: 7)),
    ];
    for (final (name, value) in broken) {
      test('rechaza una fila rota: $name', () {
        expect(
          () => MenuSendRecord.fromRow(value),
          throwsA(isA<FormatException>()),
        );
      });
    }

    test('toString no muestra el mensaje de la clienta', () {
      final record = MenuSendRecord.fromRow(
        row(changesAt: '2026-11-23T08:15:00+00:00', changesText: 'Secreto'),
      );
      expect(record.toString(), isNot(contains('Secreto')));
    });
  });

  group('latestSendsBySession', () {
    test('el último que salió de cada semana; con el mismo sent_at, el de id mayor', () {
      final early = sentMenu(id: 'send-a', sessionId: sessionId(1));
      final late = sentMenu(
        id: 'send-b',
        sessionId: sessionId(1),
        sentAt: testSentAt.add(const Duration(hours: 1)),
      );
      final tieLow = sentMenu(id: 'send-c', sessionId: sessionId(2));
      final tieHigh = sentMenu(id: 'send-d', sessionId: sessionId(2));
      expect(latestSendsBySession([late, early, tieHigh, tieLow]), {
        sessionId(1): late,
        sessionId(2): tieHigh,
      });
      expect(latestSendsBySession([early, late, tieLow, tieHigh]), {
        sessionId(1): late,
        sessionId(2): tieHigh,
      });
    });
  });

  group('WeekMenuSendStatus', () {
    final base = sentMenu(sessionId: sessionId(1), menuVersion: 2);

    test('sin envío: nunca salió (aunque el menú esté guardado)', () {
      const status = WeekMenuSendStatus(savedVersion: 3);
      expect(status.phase, MenuSendPhase.notSent);
      expect(status.changedSinceSent, isFalse);
    });

    test('mandado, confirmado o con cambios pedidos', () {
      expect(WeekMenuSendStatus(send: base).phase, MenuSendPhase.sent);
      expect(
        WeekMenuSendStatus(send: base.copyWith(confirmedAt: testSentAt)).phase,
        MenuSendPhase.confirmed,
      );
      expect(
        WeekMenuSendStatus(
          send: base.copyWith(
            changesRequestedAt: testSentAt,
            changesText: 'Otra cosa',
          ),
        ).phase,
        MenuSendPhase.changesRequested,
      );
    });

    test('cambió después de mandarlo: la versión guardada es más nueva que la mandada', () {
      expect(
        WeekMenuSendStatus(send: base, savedVersion: 3).changedSinceSent,
        isTrue,
      );
      expect(
        WeekMenuSendStatus(send: base, savedVersion: 2).changedSinceSent,
        isFalse,
      );
      expect(WeekMenuSendStatus(send: base).changedSinceSent, isFalse);
    });
  });

  group('MenuSendContact', () {
    test('qué canal sirve: un email con forma de email y un teléfono que se normaliza', () {
      expect(testMenuContact.usableEmail, 'giulia@example.test');
      expect(testMenuContact.phoneE164, '+393331234567');
      expect(testMenuContact.emailIssue, isNull);
      expect(testMenuContact.phoneIssue, isNull);

      const missing = MenuSendContact(name: 'Giulia');
      expect(missing.emailIssue, ContactIssue.missing);
      expect(missing.phoneIssue, ContactIssue.missing);

      const invalid = MenuSendContact(
        name: 'Giulia',
        email: 'giulia@example',
        phone: '12345',
      );
      expect(invalid.usableEmail, isNull);
      expect(invalid.phoneE164, isNull);
      expect(invalid.emailIssue, ContactIssue.invalid);
      expect(invalid.phoneIssue, ContactIssue.invalid);
      // Un móvil italiano sin prefijo, como la función (normalizePhone).
      expect(
        const MenuSendContact(name: 'G', phone: '333 123 4567').phoneE164,
        '+393331234567',
      );
    });

    test('toString no muestra nada del contacto', () {
      expect(testMenuContact.toString(), isNot(contains('giulia')));
      expect(testMenuContact.toString(), isNot(contains('333')));
    });
  });

  group('POST chef/menus/preview', () {
    test('el cuerpo lleva siempre las tres claves', () {
      expect(
        MenuPreviewRequest(sessionId: sessionId(2), menuVersion: 3).toBody(),
        {'sessionId': sessionId(2), 'menuVersion': 3, 'translate': true},
      );
      expect(
        MenuPreviewRequest(
          sessionId: sessionId(2),
          menuVersion: 3,
          translate: false,
        ).toBody()['translate'],
        isFalse,
      );
    });

    Map<String, Object?> response({
      Object? locale = 'it',
      Object? email = 'maria@example.com',
      Object? phone = '+393331234567',
      Object? whatsappText = 'Ciao Maria!\n[link personale per confermare]',
    }) => {
      'sendId': 'bbbbbbbb-0000-4000-8000-000000000001',
      'locale': locale,
      'translated': true,
      'contact': {'name': 'Maria Rossi', 'email': email, 'phone': phone},
      'message': {
        'subject': 'Radici: il menù della settimana 1 di 4 (30 nov)',
        'emailText': 'Ciao Maria!\n\n…',
        'whatsappText': whatsappText,
      },
    };

    test('lee la respuesta: el envío, el idioma, el contacto y el mensaje', () {
      final preview = MenuPreview.fromResponse(response());
      expect(preview.sendId, 'bbbbbbbb-0000-4000-8000-000000000001');
      expect(preview.locale, ClientLocale.it);
      expect(preview.translated, isTrue);
      expect(
        preview.contact,
        const MenuSendContact(
          name: 'Maria Rossi',
          email: 'maria@example.com',
          phone: '+393331234567',
        ),
      );
      expect(
        preview.subject,
        'Radici: il menù della settimana 1 di 4 (30 nov)',
      );
      expect(preview.whatsappText, contains('[link personale per confermare]'));
      expect(preview.toString(), isNot(contains('Maria')));
    });

    test('un contacto sin email ni teléfono (null o vacío)', () {
      final preview = MenuPreview.fromResponse(
        response(email: null, phone: '  '),
      );
      expect(preview.contact.email, isNull);
      expect(preview.contact.phone, isNull);
    });

    final broken = <(String, Object?)>[
      ('no es un objeto', 'ok'),
      ('un idioma que no existe', response(locale: 'fr')),
      ('un email que no es texto', response(email: 7)),
      ('un mensaje vacío', response(whatsappText: '  ')),
      ('sin mensaje', {...response(), 'message': null}),
    ];
    for (final (name, value) in broken) {
      test('rechaza una respuesta rota: $name', () {
        expect(
          () => MenuPreview.fromResponse(value),
          throwsA(isA<FormatException>()),
        );
      });
    }
  });

  group('POST chef/menus/send', () {
    test('el cuerpo: el envío y por dónde', () {
      expect(
        const MenuSendRequest(
          sendId: 'send-1',
          email: true,
          whatsapp: false,
        ).toBody(),
        {'sendId': 'send-1', 'email': true, 'whatsapp': false},
      );
    });

    test(
      'lee la respuesta con WhatsApp: el link de wa.me sin el + y con el texto',
      () {
        final result = MenuSendResult.fromResponse({
          'sentAt': '2026-11-21T21:42:26.123456+00:00',
          'sentVia': ['email', 'whatsapp'],
          'whatsappText':
              'Ciao Maria!\nhttps://radicicucina.app/prenotazione/#t=abc',
          'whatsappPhone': '+393331234567',
        });
        expect(result.sentAt, DateTime.utc(2026, 11, 21, 21, 42, 26, 123, 456));
        expect(result.via, [MenuSendChannel.email, MenuSendChannel.whatsapp]);
        final link = result.whatsAppLink!;
        expect(link.host, 'wa.me');
        expect(link.path, '/393331234567');
        expect(
          link.queryParameters['text'],
          'Ciao Maria!\nhttps://radicicucina.app/prenotazione/#t=abc',
        );
        // El link (con el token) no se imprime.
        expect(result.toString(), isNot(contains('prenotazione')));
      },
    );

    test('sin WhatsApp no hay link', () {
      final result = MenuSendResult.fromResponse({
        'sentAt': '2026-11-21T21:42:26+00:00',
        'sentVia': ['email'],
      });
      expect(result.whatsAppLink, isNull);
    });

    final broken = <(String, Object?)>[
      (
        'sin sentAt',
        {
          'sentVia': ['email'],
        },
      ),
      (
        'sin canales',
        {'sentAt': '2026-11-21T21:42:26+00:00', 'sentVia': <String>[]},
      ),
      (
        'el texto sin el teléfono',
        {
          'sentAt': '2026-11-21T21:42:26+00:00',
          'sentVia': ['whatsapp'],
          'whatsappText': 'Ciao',
        },
      ),
    ];
    for (final (name, value) in broken) {
      test('rechaza una respuesta rota: $name', () {
        expect(
          () => MenuSendResult.fromResponse(value),
          throwsA(isA<FormatException>()),
        );
      });
    }
  });

  test('se manda el menú de una semana que todavía se arma y tiene pedido', () {
    expect(isMenuSendable(buildSession()), isTrue);
    expect(isMenuSendable(buildSession(status: SessionStatus.held)), isTrue);
    expect(isMenuSendable(buildSession(requestId: null)), isFalse);
    for (final status in [
      SessionStatus.cooked,
      SessionStatus.paid,
      SessionStatus.cancelled,
    ]) {
      expect(isMenuSendable(buildSession(status: status)), isFalse);
    }
  });

  test('menuSendChannels: en el orden de la base', () {
    expect(menuSendChannels(email: true, whatsapp: true), [
      MenuSendChannel.email,
      MenuSendChannel.whatsapp,
    ]);
    expect(menuSendChannels(email: false, whatsapp: true), [
      MenuSendChannel.whatsapp,
    ]);
  });
}

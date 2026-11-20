// Cuerpos de POST chef/sessions/move y chef/sessions/cancel y lectura de sus
// respuestas (contrato docs/contracts/chef-api.md §5 y §6).
import 'package:flutter_test/flutter_test.dart';
import 'package:radici/core/clock_time.dart';
import 'package:radici/core/rome_time.dart';
import 'package:radici/features/sessions/domain/session_api.dart';

import '../../../support/session_fixtures.dart';

void main() {
  group('MoveSessionRequest.toBody', () {
    test('con fecha y hora; sin minutos (quedan los guardados)', () {
      expect(
        MoveSessionRequest(
          sessionId: sessionId(1),
          date: CalendarDate(2026, 12, 3),
          start: const ClockTime.hm(11, 0),
          dryRun: true,
        ).toBody(),
        {
          'sessionId': sessionId(1),
          'date': '2026-12-03',
          'start': '11:00',
          'dryRun': true,
        },
      );
    });

    test('sin hora: queda la guardada', () {
      expect(
        MoveSessionRequest(
          sessionId: sessionId(1),
          date: CalendarDate(2026, 12, 3),
          cookMinutes: 200,
        ).toBody(),
        {
          'sessionId': sessionId(1),
          'date': '2026-12-03',
          'cookMinutes': 200,
          'dryRun': false,
        },
      );
    });
  });

  group('MoveSessionResult.fromResponse', () {
    Map<String, Object?> body() => {
      'dryRun': true,
      'sessionId': sessionId(1),
      'requestId': bookingRequestId,
      'date': '2026-12-03',
      'start': '11:00',
      'cookMinutes': 200,
      'status': 'blocked',
      'suggestedStart': '10:00',
      'weekTaken': true,
    };

    test('lee el chequeo de la fecha', () {
      final result = MoveSessionResult.fromResponse(body());
      expect(result.dryRun, isTrue);
      expect(result.sessionId, sessionId(1));
      expect(result.requestId, bookingRequestId);
      expect(result.date, CalendarDate(2026, 12, 3));
      expect(result.start, const ClockTime.hm(11, 0));
      expect(result.cookMinutes, 200);
      expect(result.status, BookingDayStatus.blocked);
      expect(result.suggestedStart, const ClockTime.hm(10, 0));
      expect(result.weekTaken, isTrue);
    });

    test('sin llegada sugerida (día sin horario) y sin pedido', () {
      final result = MoveSessionResult.fromResponse({
        ...body(),
        'suggestedStart': null,
        'requestId': null,
        'status': 'closed',
      });
      expect(result.suggestedStart, isNull);
      expect(result.requestId, isNull);
      expect(result.status, BookingDayStatus.closed);
    });

    test('con otra forma, FormatException', () {
      for (final broken in <Object?>[
        null,
        'ok',
        {...body(), 'weekTaken': 'no'},
        {...body(), 'status': 'raro'},
        {...body(), 'start': '25:00'},
        {...body(), 'suggestedStart': 10},
        {...body(), 'date': '3/12/2026'},
      ]) {
        expect(
          () => MoveSessionResult.fromResponse(broken),
          throwsFormatException,
          reason: '$broken',
        );
      }
    });
  });

  group('CancelSessionsRequest.toBody', () {
    test('las sesiones sin repetir, el código del motivo y sin permiso para las cobradas', () {
      expect(
        CancelSessionsRequest(
          sessionIds: [sessionId(2), sessionId(3), sessionId(2)],
          reason: CancelReason.clientCancelled,
        ).toBody(),
        {
          'sessionIds': [sessionId(2), sessionId(3)],
          'reason': 'client_cancelled',
          'allowWithPayments': false,
        },
      );
    });

    test(
      'los motivos son la lista cerrada del contrato, nunca texto libre',
      () {
        expect(
          [for (final r in CancelReason.values) r.code],
          ['chef_cancelled', 'client_cancelled', 'chef_unavailable'],
        );
        expect(
          CancelSessionsRequest(sessionIds: [sessionId(1)]).toBody()['reason'],
          'chef_cancelled',
        );
        expect(
          CancelReason.fromCode('chef_unavailable'),
          CancelReason.chefUnavailable,
        );
        expect(CancelReason.fromCode('hold_expired'), isNull);
      },
    );
  });

  group('CancelSessionsResult.fromResponse', () {
    test('lee las canceladas, las que ya lo estaban y las cobradas', () {
      final result = CancelSessionsResult.fromResponse({
        'cancelled': [sessionId(2)],
        'alreadyCancelled': [sessionId(3)],
        'withPayments': <String>[],
        'hadPayments': false,
      });
      expect(result.cancelled, [sessionId(2)]);
      expect(result.alreadyCancelled, [sessionId(3)]);
      expect(result.allCancelled, {sessionId(2), sessionId(3)});
      expect(result.hadPayments, isFalse);
    });

    test('con otra forma, FormatException', () {
      const none = <String>[];
      for (final broken in <Object?>[
        null,
        {
          'cancelled': 'x',
          'alreadyCancelled': none,
          'withPayments': none,
          'hadPayments': false,
        },
        {
          'cancelled': [1],
          'alreadyCancelled': none,
          'withPayments': none,
          'hadPayments': false,
        },
        {'cancelled': none, 'alreadyCancelled': none, 'withPayments': none},
      ]) {
        expect(
          () => CancelSessionsResult.fromResponse(broken),
          throwsFormatException,
          reason: '$broken',
        );
      }
    });
  });
}

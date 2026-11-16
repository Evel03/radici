// Textos de las sesiones: cada estado, las horas, los motivos de cancelación
// y cada falla de mover y cancelar. arb_keys_test vigila que las claves
// existan en los tres idiomas; esto, qué texto sale en cada caso.
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:radici/core/rome_time.dart';
import 'package:radici/features/sessions/data/sessions_repository.dart';
import 'package:radici/features/sessions/domain/cooking_session.dart';
import 'package:radici/features/sessions/domain/session_api.dart';
import 'package:radici/features/sessions/presentation/session_labels.dart';
import 'package:radici/l10n/app_localizations.dart';

import '../../../support/session_fixtures.dart';

void main() {
  late AppLocalizations it;
  late AppLocalizations es;
  final thursday = CalendarDate(2026, 12, 3);

  setUpAll(() async {
    it = await AppLocalizations.delegate.load(const Locale('it'));
    es = await AppLocalizations.delegate.load(const Locale('es'));
  });

  String date(CalendarDate day) => day.toIso();

  test('cada estado tiene su texto', () {
    expect(
      [for (final s in SessionStatus.values) it.sessionStatus(s)],
      [
        'In attesa di conferma',
        'Confermata',
        'Spesa fatta',
        'Cucinata',
        'Pagata',
        'Annullata',
      ],
    );
    expect(es.sessionStatus(SessionStatus.paid), 'Cobrada');
  });

  test('las horas de la sesión, en italiano y en español', () {
    final session = buildSession();
    expect(
      it.sessionTimesLine(session),
      'Spesa dalle 09:15 · Arrivo 10:00 · fino alle 13:00',
    );
    expect(
      es.sessionTimesLine(session),
      'Compra desde 09:15 · Llega 10:00 · hasta 13:00',
    );
  });

  test('los motivos: los de la app tienen texto; los de otros caminos, no', () {
    expect(
      [for (final r in CancelReason.values) it.cancelReason(r)],
      ['Altro motivo', "L'ha chiesto la cliente", 'Non posso andare'],
    );
    expect(es.cancelReasonOf('client_cancelled'), 'La pidió la clienta');
    expect(it.cancelReasonOf('hold_expired'), isNull);
    expect(it.cancelReasonOf(null), isNull);
  });

  group('fallas', () {
    String move(SessionFailure failure) => it.sessionFailure(
      failure,
      operation: SessionOperation.move,
      formatDate: date,
    );
    String cancel(SessionFailure failure) => it.sessionFailure(
      failure,
      operation: SessionOperation.cancel,
      formatDate: date,
    );

    test('choques con la fecha', () {
      expect(
        move(SessionFailure(SessionFailureKind.slotTaken, date: thursday)),
        "2026-12-03 si sovrappone a un'altra sessione: non è stato spostato niente.",
      );
      expect(
        move(SessionFailure(SessionFailureKind.weekTaken, date: thursday)),
        'La settimana di 2026-12-03 ha già una sessione di questa prenotazione: '
        'non è stato spostato niente.',
      );
      // Sin fecha, el genérico.
      expect(
        move(const SessionFailure(SessionFailureKind.slotTaken)),
        'Non è stato possibile per un conflitto: aggiorna e riprova.',
      );
      expect(
        move(const SessionFailure(SessionFailureKind.conflict)),
        'Non è stato possibile per un conflitto: aggiorna e riprova.',
      );
    });

    test('estados que no lo permiten', () {
      expect(
        move(
          const SessionFailure(
            SessionFailureKind.notMovable,
            status: SessionStatus.paid,
          ),
        ),
        'Questa sessione è «Pagata»: non si può più spostare.',
      );
      expect(
        move(const SessionFailure(SessionFailureKind.notMovable)),
        'Questa sessione non si può più spostare.',
      );
      expect(
        cancel(const SessionFailure(SessionFailureKind.invalidTransition)),
        'Una delle sessioni è già cucinata o pagata: non ne è stata annullata nessuna.',
      );
      expect(
        cancel(
          const SessionFailure(
            SessionFailureKind.hasPayments,
            sessionIds: ['a', 'b'],
          ),
        ),
        startsWith('2 di queste settimane sono già pagate'),
      );
    });

    test('permisos, datos y sin conexión (distinto al mover y al cancelar)', () {
      expect(
        move(const SessionFailure(SessionFailureKind.notFound)),
        'La sessione non esiste più.',
      );
      expect(
        move(const SessionFailure(SessionFailureKind.forbidden)),
        'Il tuo account non può modificare le sessioni.',
      );
      expect(
        move(const SessionFailure(SessionFailureKind.unauthorized)),
        it.bookingErrorUnauthorized,
      );
      expect(
        move(const SessionFailure(SessionFailureKind.invalid)),
        it.bookingErrorInvalid,
      );
      expect(
        move(const SessionFailure(SessionFailureKind.unavailable)),
        'Non è stato possibile spostarla. Controlla la connessione e riprova.',
      );
      expect(
        cancel(const SessionFailure(SessionFailureKind.unavailable)),
        startsWith('Non è stato possibile annullarla.'),
      );
    });
  });
}

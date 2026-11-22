// Textos de las sesiones: cada estado (shopping_done, sin uso desde el
// 19/11/2026, como confirmada), las horas sin compra (dónde se puede partir el
// renglón), las fechas dentro de una frase, los motivos de cancelación y cada
// falla de mover y cancelar. arb_keys_test vigila que las claves existan en
// los tres idiomas; esto, qué texto sale en cada caso.
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:radici/core/rome_time.dart';
import 'package:radici/features/sessions/data/sessions_repository.dart';
import 'package:radici/features/sessions/domain/cooking_session.dart';
import 'package:radici/features/sessions/domain/session_api.dart';
import 'package:radici/features/sessions/presentation/session_labels.dart';
import 'package:radici/l10n/app_localizations.dart';

import '../../../support/plain_text.dart';
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

  test('cada estado tiene su texto; shopping_done, el de confirmada', () {
    expect(
      [for (final s in SessionStatus.values) it.sessionStatus(s)],
      [
        'In attesa di conferma',
        'Confermata',
        // shopping_done: una sesión vieja no dice que la cocinera compró.
        'Confermata',
        'Cucinata',
        'Pagata',
        'Annullata',
      ],
    );
    expect(es.sessionStatus(SessionStatus.paid), 'Cobrada');
  });

  test('las horas de la sesión, en italiano y en español: la llegada y el fin, sin compra', () {
    final session = buildSession();
    expect(
      plainSpaces(it.sessionTimesLine(session)),
      'Arrivo 10:00 · fino alle 13:00',
    );
    expect(
      plainSpaces(es.sessionTimesLine(session)),
      'Llega 10:00 · hasta 13:00',
    );
    // Una de antes del 19/11/2026 guarda 45 min de compra: no se muestran.
    expect(
      plainSpaces(it.sessionTimesLine(buildSession(shopMinutes: 45))),
      'Arrivo 10:00 · fino alle 13:00',
    );
  });

  test('las horas solo se pueden partir después de un «·»: nunca «hasta» y la hora en dos renglones', () {
    final line = es.sessionTimesLine(buildSession());
    // Cada tramo con espacios que no cortan; el «·» pegado al tramo de antes
    // y un solo espacio común después (ahí se parte el renglón).
    expect(line, ['Llega${nbsp}10:00$nbsp·', 'hasta${nbsp}13:00'].join(' '));
    expect(' '.allMatches(line), hasLength(1));
  });

  test('los motivos: los de la app y los de un presupuesto tienen texto; los demás, no', () {
    expect(
      [for (final r in CancelReason.values) it.cancelReason(r)],
      ['Altro motivo', "L'ha chiesto la cliente", 'Non posso andare'],
    );
    expect(es.cancelReasonOf('client_cancelled'), 'La pidió la clienta');
    // Las semanas de un presupuesto retirado, vencido o rechazado (SPEC 5.8).
    expect(es.cancelReasonOf('quote_withdrawn'), 'Presupuesto retirado');
    expect(it.cancelReasonOf('hold_expired'), 'Preventivo scaduto');
    expect(es.cancelReasonOf('declined'), 'Presupuesto rechazado');
    expect(it.cancelReasonOf('otro_motivo'), isNull);
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
      // shopping_done se muestra como confirmada: sin el estado, que no se
      // entendería («è «Confermata»: non si può più spostare»).
      expect(
        move(
          const SessionFailure(
            SessionFailureKind.notMovable,
            status: SessionStatus.shoppingDone,
          ),
        ),
        'Questa sessione non si può più spostare.',
      );
      expect(
        cancel(const SessionFailure(SessionFailureKind.invalidTransition)),
        'Una delle sessioni è già cucinata o pagata: non ne è stata annullata nessuna.',
      );
      // El aviso con las fechas y qué hacer lo arma la ficha (has_payments_
      // dialog); este es el de cuando no puede.
      expect(
        cancel(
          const SessionFailure(
            SessionFailureKind.hasPayments,
            sessionIds: ['a', 'b'],
          ),
        ),
        'Una delle settimane è già pagata: non ne è stata annullata nessuna.',
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

  testWidgets(
    'las fechas dentro de una frase: en español sin la coma de intl («Mover al mié 2 de dic»)',
    (tester) async {
      Future<SessionFormats> formatsFor(Locale locale) async {
        late SessionFormats formats;
        await tester.pumpWidget(
          Localizations(
            locale: locale,
            delegates: AppLocalizations.localizationsDelegates,
            child: Builder(
              builder: (context) {
                formats = SessionFormats(context);
                return const SizedBox();
              },
            ),
          ),
        );
        return formats;
      }

      final wednesday = CalendarDate(2026, 12, 2);
      final spanish = await formatsFor(const Locale('es'));
      expect(spanish.inText(wednesday), 'mié 2 de dic');
      expect(
        spanish.listInText([wednesday, wednesday.addDays(7)]),
        'mié${nbsp}2${nbsp}de${nbsp}dic$nbsp· mié${nbsp}9${nbsp}de${nbsp}dic',
      );
      // En italiano y en inglés, la fecha corta de siempre.
      expect((await formatsFor(const Locale('it'))).inText(wednesday), 'mer 2 dic');
      expect((await formatsFor(const Locale('en'))).inText(wednesday), 'Wed, Dec 2');
      expect(
        es.moveConfirm(spanish.inText(thursday)),
        'Mover al jue 3 de dic',
      );
    },
  );
}

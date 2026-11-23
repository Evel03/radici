// Presupuestos de ejemplo para los tests (SPEC 5.8). Datos inventados.
import 'package:radici/core/clock_time.dart';
import 'package:radici/core/rome_time.dart';
import 'package:radici/features/quotes/domain/request_quote.dart';
import 'package:radici/features/sessions/domain/cooking_session.dart';
import 'package:radici/features/week_menu/domain/menu_send.dart';

import 'request_fixtures.dart';

/// El presupuesto de los tests.
const String testQuoteId = 'f0000000-0000-4000-8000-000000000001';

/// Id de la semana [n] de un presupuesto (de 1 a 99).
String quoteSessionId(int n) =>
    'e0000000-0000-4000-8000-0000000000${n.toString().padLeft(2, '0')}';

/// "Ahora" de los presupuestos: lunes 23/11/2026 a las 10:00 en Roma.
final DateTime quoteNow = DateTime.utc(2026, 11, 23, 9);

/// Las [weeks] semanas de un presupuesto, cada 7 días desde [first] (lunes
/// 30/11/2026) a las 10:00, con 180 minutos y el precio repartido como la
/// base (140 € cada una por defecto); [statuses] va por semana, desde 1.
List<QuoteSession> quoteSessions({
  int weeks = 4,
  CalendarDate? first,
  ClockTime start = const ClockTime.hm(10, 0),
  int serviceCents = 14000,
  Map<int, SessionStatus> statuses = const {},
}) {
  final day = first ?? CalendarDate(2026, 11, 30);
  return [
    for (var week = 1; week <= weeks; week++)
      QuoteSession(
        id: quoteSessionId(week),
        date: day.addDays(7 * (week - 1)),
        start: start,
        cookMinutes: 180,
        serviceCents: serviceCents,
        status: statuses[week] ?? SessionStatus.held,
      ),
  ];
}

/// Los términos de [sessions] (las vivas), como `private.quote_terms`.
QuoteTerms termsOf(
  List<QuoteSession> sessions, {
  String quoteId = testQuoteId,
}) => QuoteTerms(
  quoteId: quoteId,
  weeks: [
    for (final session in sessions)
      if (session.isLive) session.week,
  ],
);

/// El envío de la semana 1 que llevó el presupuesto, con lo que contestó la
/// clienta.
MenuSendRecord quoteSend({
  String id = 'send-quote-1',
  String sessionId = 'e0000000-0000-4000-8000-000000000001',
  DateTime? sentAt,
  DateTime? changesRequestedAt,
  String? changesText,
  DateTime? confirmedAt,
}) => MenuSendRecord(
  id: id,
  sessionId: sessionId,
  menuVersion: 1,
  sentAt: sentAt ?? DateTime.utc(2026, 11, 22, 13, 32),
  via: const [MenuSendChannel.email, MenuSendChannel.whatsapp],
  changesRequestedAt: changesRequestedAt,
  changesText: changesText,
  confirmedAt: confirmedAt,
);

/// Un presupuesto del pedido [requestId]: por defecto, un borrador de 4
/// semanas de 140 € creado el domingo 22/11 a las 14:32 (Roma), que retiene
/// las fechas 24 h. [sent]: salió una vez el 22/11 a las 14:32 y vence el
/// 24/11 a las 14:32, con los términos de ahora (o [sentTerms]).
RequestQuote buildQuote({
  String id = testQuoteId,
  String requestId = 'req-1',
  int version = 1,
  List<QuoteSession>? sessions,
  bool sent = false,
  QuoteTerms? sentTerms,
  MenuSendRecord? lastSend,
  DateTime? holdUntil,
  DateTime? acceptedAt,
  DateTime? declinedAt,
  DateTime? withdrawnAt,
  DateTime? expiredAt,
}) {
  final weeks = sessions ?? quoteSessions();
  final sentAt = sent ? DateTime.utc(2026, 11, 22, 13, 32) : null;
  return RequestQuote(
    id: id,
    requestId: requestId,
    version: version,
    serviceCents: weeks
        .where((s) => s.isLive)
        .fold<int>(0, (sum, s) => sum + s.serviceCents),
    holdUntil:
        holdUntil ??
        (sent
            ? DateTime.utc(2026, 11, 24, 13, 32)
            : DateTime.utc(2026, 11, 23, 13, 32)),
    sentAt: sentAt,
    lastSentAt: sentAt,
    acceptedAt: acceptedAt,
    declinedAt: declinedAt,
    withdrawnAt: withdrawnAt,
    expiredAt: expiredAt,
    createdAt: DateTime.utc(2026, 11, 22, 13, 32),
    sessions: weeks,
    lastSend: sent ? (lastSend ?? quoteSend()) : lastSend,
    sentTerms: sent ? (sentTerms ?? termsOf(weeks, quoteId: id)) : sentTerms,
  );
}

/// La fila de `quotes` como la devuelve `select(requestQuoteColumns)` (con
/// sus semanas y, de sus envíos, el último que salió).
Map<String, dynamic> quoteRow({
  String id = testQuoteId,
  String requestId = 'req-1',
  int version = 1,
  int serviceCents = 56000,
  String? holdUntil = '2026-11-23T13:32:00+00:00',
  String? sentAt,
  String? lastSentAt,
  String? acceptedAt,
  String? declinedAt,
  String? withdrawnAt,
  String? expiredAt,
  List<Map<String, dynamic>>? weeks,
  List<Map<String, dynamic>> sends = const [],
}) => {
  'id': id,
  'request_id': requestId,
  'version': version,
  'service_cents': serviceCents,
  'hold_until': holdUntil,
  'sent_at': sentAt,
  'last_sent_at': lastSentAt,
  'accepted_at': acceptedAt,
  'declined_at': declinedAt,
  'withdrawn_at': withdrawnAt,
  'expired_at': expiredAt,
  'created_at': '2026-11-22T13:32:00.123456+00:00',
  'weeks':
      weeks ??
      [
        for (var week = 1; week <= 4; week++)
          quoteSessionRow(
            id: quoteSessionId(week),
            date: CalendarDate(2026, 11, 30).addDays(7 * (week - 1)).toIso(),
          ),
      ],
  'sends': sends,
};

/// Una semana de un presupuesto como la embebe [quoteRow].
Map<String, dynamic> quoteSessionRow({
  required String id,
  String date = '2026-11-30',
  String startTime = '10:00:00',
  int cookMinutes = 180,
  int serviceCents = 14000,
  String status = 'held',
}) => {
  'id': id,
  'date': date,
  'start_time': startTime,
  'cook_minutes': cookMinutes,
  'service_cents': serviceCents,
  'status': status,
};

/// Los términos como los guarda la base (`private.quote_terms`).
Map<String, dynamic> quoteTermsJson({
  String quoteId = testQuoteId,
  List<({String sessionId, String date, String start, int cents})>? weeks,
}) {
  final list =
      weeks ??
      [
        for (var week = 1; week <= 4; week++)
          (
            sessionId: quoteSessionId(week),
            date: CalendarDate(2026, 11, 30).addDays(7 * (week - 1)).toIso(),
            start: '10:00',
            cents: 14000,
          ),
      ];
  return {
    'quoteId': quoteId,
    'totalCents': list.fold<int>(0, (sum, week) => sum + week.cents),
    'weeks': [
      for (final week in list)
        {
          'sessionId': week.sessionId,
          'date': week.date,
          'start': week.start,
          'cookMinutes': 180,
          'serviceCents': week.cents,
        },
    ],
  };
}

/// El presupuesto de una foto de envío (`snapshot.quote`, quote_snapshot.ts).
Map<String, dynamic> snapshotQuoteJson({
  int version = 1,
  int holdHours = 48,
  List<({String date, String start, int cents})>? weeks,
}) {
  final list =
      weeks ??
      [
        (date: '2026-11-30', start: '10:00', cents: 14000),
        (date: '2026-12-07', start: '10:00', cents: 14000),
      ];
  return {
    'version': version,
    'totalCents': list.fold<int>(0, (sum, week) => sum + week.cents),
    'weeks': [
      for (final week in list)
        {'date': week.date, 'start': week.start, 'serviceCents': week.cents},
    ],
    'holdHours': holdHours,
    'firstStart': '${list.first.date}T${list.first.start}',
  };
}

/// Un presupuesto de foto ya leído: 2 semanas de 140 €, 48 horas.
final PreviewQuote testPreviewQuote = PreviewQuote.tryParse(
  snapshotQuoteJson(),
)!;

/// El cliente de los presupuestos (el de los pedidos de los tests).
const String quoteClientId = testClientId;

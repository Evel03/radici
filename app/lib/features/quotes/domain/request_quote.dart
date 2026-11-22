// El presupuesto de un pedido como lo ve la cocina (SPEC 5.8, «Presupuesto»;
// migración 20261121120000_quotes.sql): la fila de `quotes`, sus semanas (las
// sesiones que crea chef_create_quote, `sessions.quote_id`) y el último envío
// del menú que lo llevó (`menu_sends.quote_id`, con los términos que salieron
// y la respuesta de la clienta), leídos con la RLS de la cocina. De ahí sale su
// estado, como lo calcula la base para la página de la clienta
// (client_link_view): borrador, mandado, con cambios pedidos, cambiado sin
// reenviar, aceptado, rechazado, retirado o vencido. Dart puro.
//
// No confundir con features/quote/: la calculadora de la web (calcQuote).
// Dinero en centavos enteros; fechas y horas de Roma. El mensaje de la
// clienta al pedir cambios (`changes_text`) se ve solo en la app (SPEC §6):
// ningún toString lo muestra.
import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:radici/core/clock_time.dart';
import 'package:radici/core/money.dart';
import 'package:radici/core/rome_time.dart';
import 'package:radici/features/availability/domain/availability.dart'
    show parsePgTime;
import 'package:radici/features/quotes/domain/preview_quote.dart';
import 'package:radici/features/sessions/domain/cooking_session.dart'
    show SessionStatus;
import 'package:radici/features/week_menu/domain/menu_send.dart';

export 'package:radici/features/quotes/domain/preview_quote.dart';

part 'request_quote.freezed.dart';

/// En qué está el presupuesto de un pedido.
enum QuoteStatus {
  /// Preparado y todavía sin mandar: retiene las fechas hasta `hold_until`
  /// (24 h, nunca más allá de la primera llegada).
  draft,

  /// Salió con el menú de la semana 1 y espera a la clienta, a tiempo.
  sent,

  /// La clienta pidió cambios en el último envío (con su mensaje).
  changesRequested,

  /// Cambió (el precio, una fecha o una semana) después de mandarlo: la
  /// clienta no lo puede aceptar hasta que se lo manden de nuevo.
  changed,

  /// La clienta lo aceptó: sus semanas son una reserva.
  accepted,

  /// La clienta lo rechazó.
  declined,

  /// Evelyn lo retiró (o se retiró solo: el pedido se rechazó o se confirmó
  /// sin presupuesto).
  withdrawn,

  /// Pasó el plazo sin que la clienta lo aceptara: sin respuesta, o después
  /// de pedir cambios que no le llegaron (o el borrador, sin mandarse).
  /// También mientras el cron de la base todavía no lo cerró, como la página
  /// de la clienta.
  expired;

  /// Se puede mandar, cambiar o retirar.
  bool get isOpen => switch (this) {
    draft || sent || changesRequested || changed => true,
    accepted || declined || withdrawn || expired => false,
  };
}

/// Una semana del presupuesto: su sesión, el día y la llegada (Roma), los
/// minutos de cocina y el servicio de esa semana, como los arma
/// `private.quote_terms`.
@Freezed(fromJson: false, toJson: false)
abstract class QuoteWeek with _$QuoteWeek {
  const factory QuoteWeek({
    required String sessionId,
    required CalendarDate date,
    required ClockTime start,
    required int cookMinutes,
    required int serviceCents,
  }) = _QuoteWeek;
}

/// Los términos de un presupuesto (`private.quote_terms`): sus semanas vivas
/// por fecha, llegada e id, y el total (la suma de los servicios). Son los
/// que guarda `menu_sends.quote_terms` en cada envío y los que la clienta
/// acepta.
@Freezed(fromJson: false, toJson: false)
abstract class QuoteTerms with _$QuoteTerms {
  const factory QuoteTerms({
    required String quoteId,
    required List<QuoteWeek> weeks,
  }) = _QuoteTerms;

  const QuoteTerms._();

  /// El servicio de todas las semanas, en centavos.
  int get totalCents =>
      weeks.fold<int>(0, (sum, week) => sum + week.serviceCents);

  /// `{quoteId, totalCents, weeks: [{sessionId, date, start, cookMinutes,
  /// serviceCents}]}`; null si tiene otra forma (el total que no es la suma,
  /// semanas fuera de orden, una hora que no es "HH:MM"…): nunca unos
  /// términos a medias.
  static QuoteTerms? tryParse(Object? json) {
    if (json is! Map) return null;
    final quoteId = json['quoteId'];
    final total = json['totalCents'];
    final raw = json['weeks'];
    if (quoteId is! String ||
        quoteId.isEmpty ||
        !_isCents(total) ||
        raw is! List ||
        raw.length > maxQuoteWeeks) {
      return null;
    }
    final weeks = <QuoteWeek>[];
    for (final item in raw) {
      if (item is! Map) return null;
      final sessionId = item['sessionId'];
      final date = _dateOrNull(item['date']);
      final start = ClockTime.tryParse(item['start']);
      final cookMinutes = item['cookMinutes'];
      final cents = item['serviceCents'];
      if (sessionId is! String ||
          sessionId.isEmpty ||
          date == null ||
          start == null ||
          cookMinutes is! int ||
          cookMinutes < 1 ||
          !_isCents(cents)) {
        return null;
      }
      final week = QuoteWeek(
        sessionId: sessionId,
        date: date,
        start: start,
        cookMinutes: cookMinutes,
        serviceCents: cents as int,
      );
      if (weeks.isNotEmpty && _compareWeeks(week, weeks.last) < 0) return null;
      weeks.add(week);
    }
    final terms = QuoteTerms(quoteId: quoteId, weeks: weeks);
    return terms.totalCents == total ? terms : null;
  }
}

/// Una sesión del presupuesto, viva o cancelada (las de un presupuesto
/// cerrado sin aceptar quedan canceladas).
@Freezed(fromJson: false, toJson: false)
abstract class QuoteSession with _$QuoteSession {
  const factory QuoteSession({
    required String id,
    required CalendarDate date,
    required ClockTime start,
    required int cookMinutes,
    required int serviceCents,
    required SessionStatus status,
  }) = _QuoteSession;

  const QuoteSession._();

  /// Una fila de `sessions` con [quoteSessionColumns]. Lanza
  /// [FormatException] si está rota.
  factory QuoteSession.fromRow(Map<String, dynamic> row) {
    final id = row['id'];
    final date = row['date'];
    final start = row['start_time'];
    final cookMinutes = row['cook_minutes'];
    final cents = row['service_cents'];
    final status = SessionStatus.fromDb(row['status']);
    if (id is! String ||
        date is! String ||
        start is! String ||
        cookMinutes is! int ||
        cents is! int ||
        cents < 0 ||
        status == null) {
      throw const FormatException('Semana del presupuesto inválida');
    }
    final minutes = parsePgTime(start).inMinutes;
    if (minutes >= ClockTime.minutesPerDay) {
      throw FormatException('Hora inválida', start);
    }
    return QuoteSession(
      id: id,
      date: CalendarDate.parse(date),
      start: ClockTime(minutes),
      cookMinutes: cookMinutes,
      serviceCents: cents,
      status: status,
    );
  }

  /// No está cancelada: cuenta para los términos.
  bool get isLive => status != SessionStatus.cancelled;

  QuoteWeek get week => QuoteWeek(
    sessionId: id,
    date: date,
    start: start,
    cookMinutes: cookMinutes,
    serviceCents: serviceCents,
  );
}

/// Columnas de las semanas de un presupuesto (`sessions`).
const String quoteSessionColumns =
    'id, date, start_time, cook_minutes, service_cents, status';

/// Columnas que la app lee de `quotes`, con sus semanas (`sessions`, por la FK
/// `sessions (quote_id, chef_id) → quotes`) y sus envíos (`menu_sends`, por
/// `menu_sends_quote_fk`, con los términos que salieron). `quotes` también
/// apunta a `sessions` (`session_id`): por eso va el nombre de la FK. Sin
/// `pricing_snapshot`: los términos que salieron son los del último envío.
const String requestQuoteColumns =
    'id, request_id, version, service_cents, hold_until, sent_at, '
    'last_sent_at, accepted_at, declined_at, withdrawn_at, expired_at, '
    'created_at, '
    'weeks:sessions!sessions_quote_id_chef_id_fkey($quoteSessionColumns), '
    'sends:menu_sends!menu_sends_quote_fk($menuSendColumns, quote_terms)';

/// El presupuesto de un pedido, con sus semanas y el último envío que lo
/// llevó.
@Freezed(fromJson: false, toJson: false, toStringOverride: false)
abstract class RequestQuote with _$RequestQuote {
  const factory RequestQuote({
    required String id,
    required String requestId,

    /// La versión: 1 al prepararlo; cada envío después del primero la sube.
    /// Después de mandarlo, la que tiene la clienta.
    required int version,

    /// El servicio de todas las semanas de ahora.
    required int serviceCents,

    /// Hasta cuándo retiene las fechas: el borrador, 24 h; mandado, el plazo
    /// de la clienta (48 h), nunca más allá de la primera llegada.
    DateTime? holdUntil,

    /// El primer envío y el último.
    DateTime? sentAt,
    DateTime? lastSentAt,
    DateTime? acceptedAt,
    DateTime? declinedAt,
    DateTime? withdrawnAt,
    DateTime? expiredAt,
    required DateTime createdAt,

    /// Sus semanas, también las canceladas.
    @Default(<QuoteSession>[]) List<QuoteSession> sessions,

    /// El último envío del menú que lo llevó (el de la semana 1), si salió.
    MenuSendRecord? lastSend,

    /// Los términos que salieron en [lastSend] (null sin envío o si no se
    /// pueden leer).
    QuoteTerms? sentTerms,
  }) = _RequestQuote;

  const RequestQuote._();

  /// Una fila de `quotes` con [requestQuoteColumns] (y, de sus envíos, solo
  /// el último que salió). Lanza [FormatException] si está rota.
  factory RequestQuote.fromRow(Map<String, dynamic> row) {
    final id = row['id'];
    final requestId = row['request_id'];
    final version = row['version'];
    final cents = row['service_cents'];
    final createdAt = _instantOrNull(row['created_at']);
    final weeks = row['weeks'];
    final sends = row['sends'];
    if (id is! String ||
        requestId is! String ||
        version is! int ||
        version < 1 ||
        cents is! int ||
        cents < 0 ||
        createdAt == null ||
        (weeks != null && weeks is! List) ||
        (sends != null && sends is! List)) {
      throw const FormatException('Fila de quotes inválida');
    }
    final records = [
      for (final send in (sends as List?) ?? const <Object?>[])
        if (send is Map) send.cast<String, dynamic>(),
    ];
    // La consulta trae solo el último que salió; por las dudas, el más nuevo.
    Map<String, dynamic>? latest;
    MenuSendRecord? latestRecord;
    for (final send in records) {
      final record = MenuSendRecord.fromRow(send);
      if (latestRecord == null || latestRecord.isOlderThan(record)) {
        latest = send;
        latestRecord = record;
      }
    }
    return RequestQuote(
      id: id,
      requestId: requestId,
      version: version,
      serviceCents: cents,
      holdUntil: _instantOrNull(row['hold_until']),
      sentAt: _instantOrNull(row['sent_at']),
      lastSentAt: _instantOrNull(row['last_sent_at']),
      acceptedAt: _instantOrNull(row['accepted_at']),
      declinedAt: _instantOrNull(row['declined_at']),
      withdrawnAt: _instantOrNull(row['withdrawn_at']),
      expiredAt: _instantOrNull(row['expired_at']),
      createdAt: createdAt,
      sessions: [
        for (final week in (weeks as List?) ?? const <Object?>[])
          if (week is Map)
            QuoteSession.fromRow(week.cast<String, dynamic>())
          else
            throw const FormatException('Semana del presupuesto inválida'),
      ],
      lastSend: latestRecord,
      sentTerms: latest == null
          ? null
          : QuoteTerms.tryParse(latest['quote_terms']),
    );
  }

  /// Abierto para la base: sin aceptar, rechazar, retirar ni vencer (aunque
  /// el plazo ya haya pasado y el cron todavía no lo haya cerrado). Mientras
  /// tanto el pedido no admite otro.
  bool get isOpen =>
      acceptedAt == null &&
      declinedAt == null &&
      withdrawnAt == null &&
      expiredAt == null;

  /// Salió al menos una vez.
  bool get wasSent => sentAt != null;

  /// El último envío (el primero en los de antes, que salían una vez).
  DateTime? get lastSentOn => lastSentAt ?? sentAt;

  /// Las semanas vivas, por fecha, llegada e id (el orden de la base).
  List<QuoteSession> get liveSessions =>
      sessions.where((session) => session.isLive).toList()
        ..sort((a, b) => _compareWeeks(a.week, b.week));

  /// Los términos de ahora, como `private.quote_terms`.
  QuoteTerms get currentTerms => QuoteTerms(
    quoteId: id,
    weeks: [for (final session in liveSessions) session.week],
  );

  /// Ya salió y sus términos de ahora no son los que salieron (otro precio,
  /// una semana movida o cancelada): la clienta tiene que recibirlo de nuevo.
  bool get changedSinceSent {
    final sent = sentTerms;
    return wasSent && sent != null && sent != currentTerms;
  }

  /// La clienta pidió cambios en el último envío.
  bool get changesRequested => lastSend?.changesRequestedAt != null;

  /// El plazo ya pasó en [now] (la base lo da por vencido: `hold_until <=
  /// now()`).
  bool holdPassed(DateTime now) {
    final hold = holdUntil;
    return hold != null && !now.isBefore(hold);
  }

  /// El estado en [now], con la prioridad de la base: lo cerrado primero
  /// (aceptado, rechazado, retirado o vencido, también si pasó el plazo);
  /// abierto, sin mandar; mandado y cambiado después; con cambios pedidos;
  /// mandado.
  QuoteStatus statusAt(DateTime now) {
    if (acceptedAt != null) return QuoteStatus.accepted;
    if (declinedAt != null) return QuoteStatus.declined;
    if (withdrawnAt != null) return QuoteStatus.withdrawn;
    if (expiredAt != null || holdPassed(now)) return QuoteStatus.expired;
    if (!wasSent) return QuoteStatus.draft;
    if (changedSinceSent) return QuoteStatus.changed;
    if (changesRequested) return QuoteStatus.changesRequested;
    return QuoteStatus.sent;
  }

  /// La semana 1 de ahora: la que lleva el presupuesto (su menú sale con él).
  QuoteWeek? get firstWeek => currentTerms.weeks.firstOrNull;

  /// Las semanas que se muestran con [status]: abierto, las de ahora;
  /// cerrado, las que salieron (null si nunca salió: sus semanas ya se
  /// liberaron).
  QuoteTerms? termsFor(QuoteStatus status) =>
      status.isOpen ? currentTerms : sentTerms;

  /// Cuántas semanas tiene con [status], para los textos (con una sola, se
  /// habla de una fecha): las de [termsFor]; si nunca salió y se cerró, todas
  /// las que tuvo.
  int weekCountFor(QuoteStatus status) =>
      termsFor(status)?.weeks.length ?? sessions.length;

  /// Cuándo se cerró (aceptado, rechazado, retirado o vencido; vencido sin
  /// el cron, el plazo); null si está abierto y a tiempo.
  DateTime? closedOn(QuoteStatus status) => switch (status) {
    QuoteStatus.accepted => acceptedAt,
    QuoteStatus.declined => declinedAt,
    QuoteStatus.withdrawn => withdrawnAt,
    QuoteStatus.expired => expiredAt ?? holdUntil,
    _ => null,
  };

  /// Solo el id y la versión: nunca el mensaje de la clienta.
  @override
  String toString() => 'RequestQuote($id, v$version)';
}

/// Lo que el bloque «Presupuesto» ofrece con [status]: mandarlo (la primera
/// vez o de nuevo; [sendIsPrimary]: es el paso que falta y va abajo), el menú
/// de la semana 1, otro precio y retirarlo. Sin semanas vivas (las cancelaron
/// todas) no sale ni cambia de precio (`quote_empty`): solo se retira.
typedef QuoteActions = ({
  bool send,
  bool resend,
  bool sendIsPrimary,
  bool editMenu,
  bool changePrice,
  bool withdraw,
});

const QuoteActions _noActions = (
  send: false,
  resend: false,
  sendIsPrimary: false,
  editMenu: false,
  changePrice: false,
  withdraw: false,
);

QuoteActions quoteActionsFor(QuoteStatus status, {required bool hasWeeks}) {
  if (!status.isOpen) return _noActions;
  if (!hasWeeks) {
    return (
      withdraw: true,
      send: false,
      resend: false,
      sendIsPrimary: false,
      editMenu: false,
      changePrice: false,
    );
  }
  return (
    send: status == QuoteStatus.draft,
    resend: status != QuoteStatus.draft,
    // Mandado y sin novedades, mandarlo de nuevo no es el paso que falta.
    sendIsPrimary: status != QuoteStatus.sent,
    editMenu: true,
    changePrice: true,
    withdraw: true,
  );
}

/// Por qué no se puede usar el precio escrito para un presupuesto.
enum QuotePriceIssue {
  /// Vacío.
  required,

  /// No es un importe ("560", "560,50"…).
  invalid,

  /// Más del tope (100.000 €).
  tooHigh,
}

/// El precio del servicio de todo el presupuesto escrito en [text] (euros,
/// como lo lee parseEuroCents), en centavos, o por qué no sirve.
({int? cents, QuotePriceIssue? issue}) readQuotePrice(String text) {
  if (text.trim().isEmpty) {
    return (cents: null, issue: QuotePriceIssue.required);
  }
  final cents = parseEuroCents(text);
  if (cents == null) return (cents: null, issue: QuotePriceIssue.invalid);
  if (cents > maxQuoteCents) {
    return (cents: null, issue: QuotePriceIssue.tooHigh);
  }
  return (cents: cents, issue: null);
}

// ---------------------------------------------------------------------
// Lectura
// ---------------------------------------------------------------------

/// El plazo de cada presupuesto abierto, por pedido, de las filas
/// `{request_id, hold_until}` de `quotes`. Una sin plazo no está. Lanza
/// [FormatException] si una fila está rota.
Map<String, DateTime> openQuoteHoldsFromRows(
  Iterable<Map<String, dynamic>> rows,
) {
  final holds = <String, DateTime>{};
  for (final row in rows) {
    final requestId = row['request_id'];
    final hold = row['hold_until'];
    if (requestId is! String ||
        (hold != null && _instantOrNull(hold) == null)) {
      throw const FormatException('Fila de quotes inválida');
    }
    if (_instantOrNull(hold) case final until?) holds[requestId] = until;
  }
  return holds;
}

bool _isCents(Object? value) =>
    value is int && value >= 0 && value <= maxQuoteCents;

CalendarDate? _dateOrNull(Object? value) {
  if (value is! String) return null;
  try {
    return CalendarDate.parse(value);
  } on FormatException {
    return null;
  }
}

DateTime? _instantOrNull(Object? value) =>
    value is String ? DateTime.tryParse(value) : null;

int _compareWeeks(QuoteWeek a, QuoteWeek b) {
  final byDate = a.date.compareTo(b.date);
  if (byDate != 0) return byDate;
  final byStart = a.start.compareTo(b.start);
  return byStart != 0 ? byStart : a.sessionId.compareTo(b.sessionId);
}

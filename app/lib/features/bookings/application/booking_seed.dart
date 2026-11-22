// De dónde se abre la hoja «Conferma prenotazione» y lo que trae al abrirse:
// un pedido de la bandeja (como el PR 5), una ficha existente elegida en
// «Nuova prenotazione» (o desde «Nuova cliente», si el teléfono ya era de una
// ficha), una ficha nueva (el borrador del formulario), «Rinnova» (la
// reserva de una sesión, con lo que copia renewalPlan) o «Preparar
// presupuesto» (un pedido nuevo, como el primero: SPEC 5.8). El seed tiene el
// destinatario (para el encabezado y el WhatsApp), el destino del POST
// (requestId, clientId o newClient) y lo inicial de la hoja. El controller
// toma el primero y no mira los siguientes.
//
// En la URL van solo ids: los datos de una ficha nueva viven en el borrador
// (newClientFormProvider), nunca en la ruta. Nada de esto se loguea.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:radici/core/clock.dart';
import 'package:radici/core/clock_time.dart';
import 'package:radici/core/phone.dart';
import 'package:radici/core/rome_time.dart';
import 'package:radici/features/bookings/application/new_client_form_controller.dart';
import 'package:radici/features/bookings/data/bookings_repository.dart';
import 'package:radici/features/bookings/domain/booking.dart';
import 'package:radici/features/bookings/domain/booking_draft.dart';
import 'package:radici/features/bookings/domain/renewal.dart';
import 'package:radici/features/clients/application/client_directory_controller.dart';
import 'package:radici/features/clients/domain/chef_client.dart';
import 'package:radici/features/quotes/application/quote_providers.dart';
import 'package:radici/features/quotes/domain/request_quote.dart';
import 'package:radici/features/requests/application/chef_inbox_controller.dart';
import 'package:radici/features/requests/domain/chef_request.dart';
import 'package:radici/features/sessions/application/sessions_controller.dart';
import 'package:radici/features/sessions/domain/cooking_session.dart';
import 'package:radici/features/week_menu/application/week_menu_summaries.dart';

part 'booking_seed.freezed.dart';

/// De dónde se abre la hoja. Compara por valor (es la clave de la familia del
/// controller) y su toString lleva solo ids.
@freezed
sealed class BookingSource with _$BookingSource {
  const BookingSource._();

  /// Un pedido nuevo de la bandeja.
  const factory BookingSource.request(String requestId) = RequestBookingSource;

  /// Una ficha existente. [fromForm]: elegida desde «Nuova cliente» (el
  /// teléfono escrito ya era de esa ficha); lo que Evelyn tocó ahí en el hogar
  /// o el idioma va al pedido.
  const factory BookingSource.client(
    String clientId, {
    @Default(false) bool fromForm,
  }) = ClientBookingSource;

  /// Una ficha nueva, con los datos del borrador de «Nuova cliente».
  const factory BookingSource.newClient() = NewClientBookingSource;

  /// «Rinnova»: la reserva de la sesión [sessionId], para la misma ficha.
  const factory BookingSource.renewal(String sessionId) =
      RenewalBookingSource;

  /// «Preparar presupuesto» de un pedido nuevo de la bandeja (SPEC 5.8): la
  /// misma hoja, con el precio de todo el presupuesto; crea sus semanas
  /// retenidas (POST chef/quotes) en lugar de confirmarlas.
  const factory BookingSource.quote(String requestId) = QuoteBookingSource;

  BookingSourceKind get kind => switch (this) {
    RequestBookingSource() => BookingSourceKind.request,
    ClientBookingSource() || NewClientBookingSource() =>
      BookingSourceKind.manual,
    RenewalBookingSource() => BookingSourceKind.renewal,
    QuoteBookingSource() => BookingSourceKind.quote,
  };
}

/// Desde un pedido, a mano (ficha existente o nueva), «Rinnova» o el
/// presupuesto de un pedido.
enum BookingSourceKind { request, manual, renewal, quote }

/// El presupuesto abierto de un pedido que «Confirmar sin presupuesto»
/// retira (la base lo hace en la misma transacción, SPEC 5.8).
enum QuoteToWithdraw {
  /// Un borrador que nunca salió: se retira y sus semanas retenidas se
  /// cancelan.
  draft,

  /// Uno que ya salió: además, la clienta ya no lo puede aceptar desde su
  /// enlace.
  sent,
}

/// El presupuesto abierto que «Confirmar sin presupuesto» retiraría: si ya
/// salió ([kind]), cuántas semanas retenidas tiene ([weeks]; 0 si no se
/// sabe) y si la semana 1 tiene un menú guardado ([hasMenu]): se va con esa
/// semana cancelada y hay que volver a armarlo y mandarlo.
typedef OpenQuoteToWithdraw = ({QuoteToWithdraw kind, int weeks, bool hasMenu});

/// A quién es la reserva: el encabezado de la hoja y el WhatsApp final. Tiene
/// datos de contacto: toString no los muestra.
final class BookingParty {
  const BookingParty({
    required this.displayName,
    this.phoneText,
    this.phoneE164,
    this.zone,
  });

  /// La clienta de un pedido (el contacto que llegó con el pedido o, si
  /// falta, el de la ficha).
  factory BookingParty.fromRequest(ChefRequest request) => BookingParty(
    displayName: request.client.displayName,
    phoneText: request.client.contactPhone,
    phoneE164: request.client.phoneE164,
    zone: request.client.zone,
  );

  /// Una ficha del directorio.
  factory BookingParty.fromClient(ChefClient client) => BookingParty(
    displayName: client.displayName,
    phoneText: client.contactPhone,
    phoneE164: client.phoneE164,
    zone: client.zone,
  );

  /// La ficha de una sesión: en una renovación, el encabezado y el WhatsApp
  /// salen de ahí (el pedido de la renovación no lleva contacto propio, así
  /// que las sesiones nuevas muestran el de la ficha).
  factory BookingParty.fromSessionClient(SessionClient client) {
    final phone = client.contactPhone;
    return BookingParty(
      displayName: client.displayName,
      phoneText: phone,
      phoneE164: phone == null ? null : phoneFromInput(phone),
      zone: client.zone,
    );
  }

  final String displayName;

  /// Como está guardado o como se escribió.
  final String? phoneText;

  /// Para WhatsApp; null sin un teléfono válido.
  final String? phoneE164;
  final String? zone;

  /// Primer nombre, para saludar ("Giulia Rossi" → "Giulia").
  String get firstName {
    final trimmed = displayName.trim();
    if (trimmed.isEmpty) return '';
    return trimmed.split(RegExp(r'\s+')).first;
  }

  @override
  String toString() => 'BookingParty(<oculto>)';
}

/// Cómo propone la hoja el precio del servicio según las semanas, mientras
/// Evelyn no lo escriba.
sealed class BookingPriceRule {
  const BookingPriceRule();

  /// El precio de [weeks] semanas, o null (vacío: lo escribe Evelyn).
  int? suggestedFor(int weeks);
}

/// Desde un pedido: el de su estimación o sus tarifas guardadas.
final class EstimatePriceRule extends BookingPriceRule {
  const EstimatePriceRule(this.estimate);

  final RequestEstimate? estimate;

  @override
  int? suggestedFor(int weeks) =>
      suggestedServiceCents(estimate, weeks: weeks);
}

/// A mano: ninguno. Evelyn escribe el precio que acordó.
final class NoSuggestedPrice extends BookingPriceRule {
  const NoSuggestedPrice();

  @override
  int? suggestedFor(int weeks) => null;
}

/// «Rinnova»: el total de la reserva con las mismas semanas; con otras, el de
/// las tarifas de [estimate] si el total era el de esas tarifas, o ninguno
/// (renewalPriceFor). Sin total (RenewalPlan.serviceTotalCents null),
/// ninguno: lo escribe Evelyn.
final class RenewalPriceRule extends BookingPriceRule {
  const RenewalPriceRule({
    required this.totalCents,
    required this.weeks,
    this.estimate,
  });

  final int? totalCents;
  final int weeks;
  final RequestEstimate? estimate;

  @override
  int? suggestedFor(int weeks) {
    final total = totalCents;
    if (total == null) return null;
    return renewalPriceFor(
      originalTotal: total,
      originalWeeks: this.weeks,
      weeks: weeks,
      estimate: estimate,
    );
  }
}

/// Lo que trae la hoja al abrirse. Tiene datos de la clienta: toString no
/// los muestra.
final class BookingSeed {
  const BookingSeed({
    required this.kind,
    required this.party,
    this.request,
    this.clientId,
    this.clientStatus,
    this.newClient,
    this.household,
    this.locale = ClientLocale.it,
    required this.maxWeeks,
    required this.dates,
    required this.today,
    this.start,
    this.startEdited = false,
    required this.cookMinutes,
    this.cookFollowsHousehold = false,
    required this.priceRule,
    this.portions,
    this.initialFailure,
    this.renewedFrom,
    this.renewedRequestId,
    this.lastDiffers = false,
    this.otherRequestPhone,
    this.openQuote,
  });

  /// Desde un pedido: lo mismo que armaba la hoja del PR 5.
  /// [openQuote]: el presupuesto abierto del pedido, que la base retira al
  /// confirmar (SPEC 5.8): la hoja lo avisa.
  factory BookingSeed.fromRequest(
    ChefRequest request, {
    required CalendarDate today,
    OpenQuoteToWithdraw? openQuote,
  }) {
    final weeks = initialBookingWeeks(request);
    return BookingSeed(
      kind: BookingSourceKind.request,
      party: BookingParty.fromRequest(request),
      request: request,
      locale: request.locale,
      maxWeeks: maxWeeksFor(request.type),
      dates: weeklyDates(initialBookingDate(request, today: today), weeks),
      today: today,
      cookMinutes: suggestedCookMinutes(request.estimate?.cookMinutes),
      priceRule: EstimatePriceRule(request.estimate),
      portions: request.estimate?.portions,
      openQuote: request.canConfirmBooking ? openQuote : null,
      // Ya no es un pedido nuevo (ni tiene el presupuesto mandado): ni se
      // pregunta al servidor.
      initialFailure: request.canConfirmBooking
          ? null
          : BookingFailure(
              BookingFailureKind.requestNotNew,
              requestStatus: request.status == RequestStatus.newRequest
                  ? 'new'
                  : request.status.name,
            ),
    );
  }

  /// El presupuesto de un pedido: lo mismo que desde un pedido (las semanas,
  /// la fecha preferida, los minutos, las porciones y el precio de la
  /// estimación), salvo que empieza mañana como muy pronto
  /// ([initialQuoteDate]): la clienta lo acepta antes de la primera llegada.
  /// Un pedido que no lo admite ya no se pregunta al servidor: uno de cambios
  /// (requestNotQuotable) o uno que ya no está nuevo.
  factory BookingSeed.forQuote(
    ChefRequest request, {
    required CalendarDate today,
  }) {
    final weeks = initialBookingWeeks(request);
    return BookingSeed(
      kind: BookingSourceKind.quote,
      party: BookingParty.fromRequest(request),
      request: request,
      locale: request.locale,
      maxWeeks: maxWeeksFor(request.type),
      dates: weeklyDates(initialQuoteDate(request, today: today), weeks),
      today: today,
      cookMinutes: suggestedCookMinutes(request.estimate?.cookMinutes),
      priceRule: EstimatePriceRule(request.estimate),
      portions: request.estimate?.portions,
      initialFailure: request.type == RequestType.change
          ? const BookingFailure(BookingFailureKind.requestNotQuotable)
          : request.status != RequestStatus.newRequest
          ? BookingFailure(
              BookingFailureKind.requestNotNew,
              requestStatus: request.status.name,
            )
          : null,
    );
  }

  /// A mano: 4 semanas desde mañana, el hogar y su estimación (los minutos
  /// siguen al hogar) y el precio vacío.
  factory BookingSeed.manual({
    required BookingParty party,
    String? clientId,
    ClientStatus? clientStatus,
    NewClientData? newClient,
    required BookingHousehold household,
    required ClientLocale locale,
    required CalendarDate today,
  }) {
    final estimate = manualBookingEstimate(household);
    return BookingSeed(
      kind: BookingSourceKind.manual,
      party: party,
      clientId: clientId,
      clientStatus: clientStatus,
      newClient: newClient,
      household: household,
      locale: locale,
      maxWeeks: maxBookingWeeks,
      dates: weeklyDates(today.addDays(1), defaultManualBookingWeeks),
      today: today,
      cookMinutes: estimate.cookMinutes,
      cookFollowsHousehold: true,
      priceRule: const NoSuggestedPrice(),
      portions: estimate.portions,
    );
  }

  /// «Rinnova»: lo que copia [plan] (las semanas desde la última viva + 7,
  /// la hora ya elegida, los minutos que no siguen al hogar y el precio de la
  /// reserva), para la misma ficha; el destinatario es la ficha.
  factory BookingSeed.renewal(
    RenewalPlan plan, {
    required CalendarDate today,
  }) => BookingSeed(
    kind: BookingSourceKind.renewal,
    party: BookingParty.fromSessionClient(plan.last.client),
    clientId: plan.clientId,
    clientStatus: plan.last.client.status,
    household: plan.household,
    locale: plan.locale,
    maxWeeks: maxBookingWeeks,
    dates: plan.dates,
    today: today,
    start: plan.start,
    startEdited: true,
    cookMinutes: plan.cookMinutes,
    priceRule: RenewalPriceRule(
      totalCents: plan.serviceTotalCents,
      weeks: plan.weeks,
      estimate: plan.estimate,
    ),
    portions: plan.portions,
    renewedFrom: plan.last.date,
    renewedRequestId: plan.last.requestId,
    lastDiffers: plan.lastDiffers,
    otherRequestPhone: plan.otherRequestPhone,
  );

  final BookingSourceKind kind;
  final BookingParty party;

  /// El destino del POST: el pedido, la ficha o la ficha nueva (uno solo).
  final ChefRequest? request;
  final String? clientId;
  final NewClientData? newClient;

  /// El estado de la ficha existente (un prospecto pasa a trial al
  /// confirmar); null en una ficha nueva o desde un pedido.
  final ClientStatus? clientStatus;

  /// El hogar y el idioma de una reserva a mano; desde un pedido, el idioma
  /// del pedido y ningún hogar (vale el del pedido).
  final BookingHousehold? household;
  final ClientLocale locale;

  final int maxWeeks;
  final List<CalendarDate> dates;

  /// Hoy en Roma, al abrir la hoja.
  final CalendarDate today;

  /// La llegada; null: la sugiere el primer dryRun. Con [startEdited], ya
  /// elegida (el primer dryRun la lleva).
  final ClockTime? start;
  final bool startEdited;

  final int cookMinutes;

  /// Los minutos siguen al hogar mientras Evelyn no los toque (a mano).
  final bool cookFollowsHousehold;
  final BookingPriceRule priceRule;
  final int? portions;

  /// Una falla que la hoja ya conoce al abrirse (un pedido que ya no está
  /// nuevo): no se pregunta al servidor.
  final BookingFailure? initialFailure;

  /// «Rinnova»: el día de la última sesión viva de la reserva que se renueva
  /// y su pedido (al confirmar, renewedBookingsProvider lo marca).
  final CalendarDate? renewedFrom;
  final String? renewedRequestId;

  /// «Rinnova»: el día y la hora de la última semana no son los de la mayoría
  /// (ver RenewalPlan.lastDiffers).
  final bool lastDiffers;

  /// «Rinnova»: el teléfono del pedido renovado, si no es el de la ficha.
  final String? otherRequestPhone;

  /// Desde un pedido con un presupuesto abierto: el que la base retira al
  /// confirmar sin presupuesto (el borrador o el mandado).
  final OpenQuoteToWithdraw? openQuote;

  /// El borrador o el mandado de [openQuote].
  QuoteToWithdraw? get quoteToWithdraw => openQuote?.kind;

  @override
  String toString() => 'BookingSeed(${kind.name}, weeks: ${dates.length})';
}

/// Lo que trae la hoja de [BookingSource]; null si no está (el pedido, la
/// ficha o la sesión no existen, el borrador de la ficha nueva ya no sirve o
/// la reserva de la sesión no se puede renovar).
final bookingSeedProvider = FutureProvider.autoDispose
    .family<BookingSeed?, BookingSource>((ref, source) async {
      final today = romeToday(ref.read(clockProvider)());
      switch (source) {
        case RequestBookingSource(:final requestId):
          final request = await ref.watch(
            chefRequestProvider(requestId).future,
          );
          if (request == null) return null;
          return BookingSeed.fromRequest(
            request,
            today: today,
            openQuote: await _openQuoteOf(ref, request),
          );
        case QuoteBookingSource(:final requestId):
          final request = await ref.watch(
            chefRequestProvider(requestId).future,
          );
          return request == null
              ? null
              : BookingSeed.forQuote(request, today: today);
        case ClientBookingSource(:final clientId, :final fromForm):
          final clients = await ref.watch(clientDirectoryProvider.future);
          final client = clients.where((c) => c.id == clientId).firstOrNull;
          if (client == null) return null;
          // El borrador sigue vivo con el elegir debajo; si se recargó la
          // página, arranca vacío y vale lo de la ficha. Nada de esto la toca:
          // va al pedido.
          final draft = fromForm ? ref.read(newClientFormProvider) : null;
          return _clientSeed(client, draft: draft, today: today);
        case NewClientBookingSource():
          final draft = ref.watch(newClientFormProvider);
          return _newClientSeed(draft, today: today);
        case RenewalBookingSource(:final sessionId):
          // Todas las semanas de su reserva, también las canceladas.
          final detail = await ref.watch(
            sessionDetailProvider(sessionId).future,
          );
          if (detail == null) return null;
          final plan = renewalPlan(detail.booking);
          return plan == null
              ? null
              : BookingSeed.renewal(plan, today: today);
      }
    });

/// El presupuesto abierto del pedido que la reserva retiraría (SPEC 5.8): un
/// borrador o uno mandado, con sus semanas y si la semana 1 tiene un menú
/// guardado. Si no se puede leer (o no hay uno leído para un pedido con el
/// presupuesto mandado: un dato viejo), lo que dice el pedido: uno con el
/// presupuesto mandado (`quoted`) tiene uno abierto; uno nuevo, no se sabe
/// (la base igual lo retira).
Future<OpenQuoteToWithdraw?> _openQuoteOf(Ref ref, ChefRequest request) async {
  if (!request.canConfirmBooking) return null;
  final OpenQuoteToWithdraw? fallback = request.status == RequestStatus.quoted
      ? (kind: QuoteToWithdraw.sent, weeks: 0, hasMenu: false)
      : null;
  final RequestQuote? quote;
  try {
    quote = await ref.watch(requestQuoteProvider(request.id).future);
  } on Object {
    return fallback;
  }
  if (quote == null) return fallback;
  if (!quote.isOpen) return null;
  // El menú de la semana 1 vive en su sesión retenida: al confirmar se va
  // con ella. Si no se puede leer, la hoja no lo dice.
  var hasMenu = false;
  if (quote.firstWeek case final first?) {
    try {
      final summary = await ref.watch(
        weekMenuSummaryProvider(first.sessionId).future,
      );
      hasMenu = summary.saved;
    } on Object {
      hasMenu = false;
    }
  }
  return (
    kind: quote.wasSent ? QuoteToWithdraw.sent : QuoteToWithdraw.draft,
    weeks: quote.currentTerms.weeks.length,
    hasMenu: hasMenu,
  );
}

BookingSeed _clientSeed(
  ChefClient client, {
  NewClientForm? draft,
  required CalendarDate today,
}) {
  final latest = client.latestWeekly;
  var household = householdFor(
    latestWeekly: latest,
    fichaAdults: client.adults,
    fichaKids: client.kids,
  );
  var locale = latest?.type == RequestType.week
      ? latest!.locale
      : ClientLocale.it;
  if (draft != null && draft.householdTouched) {
    household = BookingHousehold.clamped(
      adults: draft.household.adults,
      kids: draft.household.kids,
      days: household.days,
      meals: household.meals,
    );
  }
  if (draft != null && draft.localeTouched) locale = draft.locale;
  return BookingSeed.manual(
    party: BookingParty.fromClient(client),
    clientId: client.id,
    clientStatus: client.status,
    household: household,
    locale: locale,
    today: today,
  );
}

BookingSeed? _newClientSeed(NewClientForm draft, {required CalendarDate today}) {
  if (!draft.canContinue || draft.phoneInvalid || draft.tooLong.isNotEmpty) {
    return null;
  }
  final data = draft.toNewClientData();
  return BookingSeed.manual(
    party: BookingParty(
      displayName: data.name,
      phoneText: draft.cleanPhone,
      phoneE164: data.phone,
      zone: data.zone,
    ),
    newClient: data,
    household: draft.household,
    locale: draft.locale,
    today: today,
  );
}

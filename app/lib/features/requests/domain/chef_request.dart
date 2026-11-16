// Pedido tal como lo ve la cocinera en la bandeja y la agenda.
// Una fila de `public.requests` con la copia del contacto con que llegó
// (`requests.contact`, pedidos de la web) y la ficha de su cliente
// (`public.clients`) embebida. Los nombres de columna son los de la base
// (M1 + contrato docs/contracts/public-request.md §3).
//
// Contiene datos de salud (restricciones) y de contacto: nunca se loguea ni se
// manda a analytics (SPEC §6). Por eso los modelos no imprimen su contenido en
// toString (ver `@Freezed(toStringOverride: false)` más abajo).
import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:radici/core/phone.dart';
import 'package:radici/core/rome_time.dart';
import 'package:radici/features/quote/domain/quote.dart' show NoAutoPriceReason;

export 'package:radici/features/quote/domain/quote.dart' show NoAutoPriceReason;

part 'chef_request.freezed.dart';
part 'chef_request.g.dart';

/// `request_type`. `change` es solo para clientes con cuenta.
enum RequestType { week, extra, change }

/// `request_status` (SPEC §5.3). En la app la cocinera solo pasa de `new` a
/// `rejected` y deshace ese rechazo (`rejected` → `new`); el resto lo cambian
/// las Edge Functions (la base lo controla en requests_guard_update).
enum RequestStatus {
  @JsonValue('new')
  newRequest,
  quoted,
  accepted,
  declined,
  rejected,
  expired,
  resolved,
}

/// `requests.preferred_slot`, cuando el pedido trae mañana o tarde. La web ya
/// no pregunta la franja y manda `any` (sin preferencia): se lee como null,
/// igual que un pedido sin franja, y no se muestra (los emails tampoco la
/// muestran).
enum PreferredSlot { morning, afternoon }

/// `requests.locale`: idioma del cliente (mensajes de WhatsApp y emails).
enum ClientLocale { it, es, en }

/// `requests.source`.
enum RequestSource { web, app }

/// Valores de `requests.meals`, en este orden.
enum Meal { lunch, dinner }

/// Los 14 alérgenos del Reg. UE 1169/2011, en el orden del enum `allergen`.
enum Allergen {
  gluten,
  crustaceans,
  eggs,
  fish,
  peanuts,
  soy,
  milk,
  nuts,
  celery,
  mustard,
  sesame,
  sulphites,
  lupin,
  molluscs,
}

/// Enum `diet`.
enum Diet { vegetarian, vegan }

/// Qué contestó el cliente a la pregunta de alergias del formulario web
/// (`requests.no_allergies` y `requests.restrictions`).
enum AllergyAnswer {
  /// Confirmó que nadie de quienes van a comer tiene alergias, intolerancias
  /// ni celiaquía.
  none,

  /// Las escribió (o el pedido trae restricciones): se muestran.
  listed,

  /// Sin respuesta: un pedido anterior a la pregunta, uno de la app o uno
  /// cuyo consentimiento de salud se retiró. Hay que preguntarle al cliente.
  unknown,
}

/// Lee una fecha `date` de Postgres ("AAAA-MM-DD").
class CalendarDateConverter implements JsonConverter<CalendarDate, String> {
  const CalendarDateConverter();

  @override
  CalendarDate fromJson(String json) => CalendarDate.parse(json);

  @override
  String toJson(CalendarDate object) => object.toIso();
}

/// Lista de valores de un enum leída de JSON, sin repetir, en el orden del
/// enum y descartando valores desconocidos (un alérgeno nuevo en la base no
/// rompe la bandeja: simplemente no se muestra hasta actualizar la app).
List<T> _knownValues<T extends Enum>(List<T> values, Object? json) {
  if (json is! List) return <T>[];
  final names = json.whereType<String>().toSet();
  return [
    for (final value in values)
      if (names.contains(value.name)) value,
  ];
}

/// Copia de las restricciones al momento del pedido (`requests.restrictions`):
/// `{ "allergens": [...], "diets": [...], "note": "..." }`. Dato de salud.
@Freezed(fromJson: false, toJson: false, toStringOverride: false)
abstract class RequestRestrictions with _$RequestRestrictions {
  const factory RequestRestrictions({
    @Default(<Allergen>[]) List<Allergen> allergens,
    @Default(<Diet>[]) List<Diet> diets,
    @Default('') String note,
  }) = _RequestRestrictions;

  const RequestRestrictions._();

  factory RequestRestrictions.fromJson(Map<String, dynamic> json) {
    final note = json['note'];
    return RequestRestrictions(
      allergens: _knownValues(Allergen.values, json['allergens']),
      diets: _knownValues(Diet.values, json['diets']),
      note: note is String ? note.trim() : '',
    );
  }

  bool get isEmpty => allergens.isEmpty && diets.isEmpty && note.isEmpty;

  @override
  String toString() => 'RequestRestrictions(<oculto>)';
}

/// Estimación guardada al crear el pedido (`requests.estimate`): el resultado
/// de `calcQuote` (quote.ts, en camelCase) con las tarifas de ese momento.
/// Montos en centavos. Cualquier campo que falte queda en null.
///
/// Desde el precio por semana (SPEC §5.1) trae `weeks` y `autoPrice`, y el
/// precio solo si lo hay: el servicio por semana, el de todas las semanas y el
/// ahorro; sin precio, el motivo. Las guardadas antes no tienen `autoPrice`
/// (eran de una semana, con el servicio por hora y el total).
@Freezed(fromJson: false, toJson: false)
abstract class RequestEstimate with _$RequestEstimate {
  const factory RequestEstimate({
    int? weeks,
    int? portions,
    int? recipes,
    int? cookMinutes,

    /// true o false desde el precio por semana; null en las de antes.
    bool? autoPrice,
    NoAutoPriceReason? reason,
    int? weeklyServiceCents,
    int? serviceCents,
    int? savingsCents,

    /// Compra estimada (de una semana desde el precio por semana).
    int? groceriesEstCents,

    /// Servicio y compra: lo que mostraban los pedidos de antes.
    int? totalCents,

    /// Hasta cuántas personas había precio automático con esas tarifas
    /// (`pricing.weeklyRateMaxPeople`), para decir por qué no lo hay.
    int? maxPeople,
  }) = _RequestEstimate;

  const RequestEstimate._();

  factory RequestEstimate.fromJson(Map<String, dynamic> json) {
    int? readFrom(Map<dynamic, dynamic> map, String key) {
      final value = map[key];
      if (value is int) return value;
      // Un número JSON entero puede llegar como double (14100.0).
      if (value is double && value.isFinite && value == value.roundToDouble()) {
        return value.toInt();
      }
      return null;
    }

    int? read(String key) => readFrom(json, key);
    final autoPrice = json['autoPrice'];
    final reason = json['reason'];
    final pricing = json['pricing'];
    return RequestEstimate(
      weeks: read('weeks'),
      portions: read('portions'),
      recipes: read('recipes'),
      cookMinutes: read('cookMinutes'),
      autoPrice: autoPrice is bool ? autoPrice : null,
      reason: NoAutoPriceReason.values.where((r) => r.name == reason).firstOrNull,
      weeklyServiceCents: read('weeklyServiceCents'),
      serviceCents: read('serviceCents'),
      savingsCents: read('savingsCents'),
      groceriesEstCents: read('groceriesEstCents'),
      totalCents: read('totalCents'),
      maxPeople: pricing is Map ? readFrom(pricing, 'weeklyRateMaxPeople') : null,
    );
  }

  /// Guardada antes del precio por semana (sin `autoPrice`): una semana, con
  /// el servicio por hora y el total.
  bool get isLegacy => autoPrice == null;

  /// Hay precio automático: el de las guardadas antes también (siempre lo
  /// tenían).
  bool get hasAutoPrice => autoPrice ?? true;

  bool get isEmpty =>
      autoPrice == null &&
      weeks == null &&
      portions == null &&
      recipes == null &&
      cookMinutes == null &&
      serviceCents == null &&
      groceriesEstCents == null &&
      totalCents == null;
}

/// `client_status` de la ficha (`public.clients.status`).
enum ClientStatus { prospect, trial, active, paused, churned }

/// Datos de contacto de un pedido. En un pedido de la web son los que llegaron
/// con él (`requests.contact`): un envío sin login no cambia la ficha de una
/// persona que ya existe, así que cada pedido muestra los suyos. Lo que falte
/// (y todo en un pedido de la app) sale de la ficha (`public.clients`), igual
/// que [status]. El teléfono se guarda tal como lo escribió el cliente: para
/// WhatsApp y llamadas usar [phoneE164].
@Freezed(toJson: false, toStringOverride: false)
abstract class RequestClient with _$RequestClient {
  const factory RequestClient({
    @JsonKey(name: 'display_name') @Default('') String displayName,
    @JsonKey(name: 'contact_email') String? contactEmail,
    @JsonKey(name: 'contact_phone') String? contactPhone,
    String? zone,

    /// Estado de la ficha; null si no vino o es uno que esta versión no conoce.
    @JsonKey(unknownEnumValue: JsonKey.nullForUndefinedEnumValue)
    ClientStatus? status,
  }) = _RequestClient;

  const RequestClient._();

  factory RequestClient.fromJson(Map<String, dynamic> json) =>
      _$RequestClientFromJson(json);

  /// Teléfono normalizado ("+39…"), o null si falta o no se puede normalizar.
  String? get phoneE164 {
    final phone = contactPhone;
    return phone == null ? null : normalizePhone(phone);
  }

  /// Primer nombre, para saludar ("Giulia Rossi" → "Giulia").
  String get firstName {
    final trimmed = displayName.trim();
    if (trimmed.isEmpty) return '';
    return trimmed.split(RegExp(r'\s+')).first;
  }

  @override
  String toString() => 'RequestClient(<oculto>)';
}

/// Columnas que la app lee de `requests`, con la copia del contacto del pedido
/// y la ficha del cliente embebida
/// (FK `requests (client_id, chef_id) → clients (id, chef_id)`).
const String chefRequestColumns =
    'id, chef_id, client_id, type, status, adults, kids, days, meals, weeks, '
    'restrictions, no_allergies, notes, preferred_date, preferred_slot, locale, '
    'whatsapp_opt_in, estimate, source, seen_at, created_at, contact, '
    'client:clients(display_name, contact_email, contact_phone, zone, status)';

/// Pasa la copia del contacto del pedido (`contact`: name, zone, phone,
/// email) por encima de la ficha embebida (`client`), campo por campo.
Map<String, dynamic> _withRequestContact(Map<String, dynamic> json) {
  final contact = json['contact'];
  if (contact is! Map) return json;
  final client = json['client'];
  final merged = <String, dynamic>{
    if (client is Map) ...client.cast<String, dynamic>(),
  };
  void take(String from, String to) {
    final value = contact[from];
    if (value is String && value.trim().isNotEmpty) merged[to] = value;
  }

  take('name', 'display_name');
  take('zone', 'zone');
  take('phone', 'contact_phone');
  take('email', 'contact_email');
  return {...json, 'client': merged};
}

@Freezed(toJson: false, toStringOverride: false)
abstract class ChefRequest with _$ChefRequest {
  const factory ChefRequest({
    required String id,
    @JsonKey(name: 'chef_id') required String chefId,
    @JsonKey(name: 'client_id') required String clientId,
    required RequestType type,
    required RequestStatus status,
    int? adults,
    int? kids,
    int? days,
    @JsonKey(fromJson: _mealsFromJson) @Default(<Meal>[]) List<Meal> meals,

    /// Semanas de un pedido semanal (`requests.weeks`, 1 a 8): una sesión
    /// por semana, el mismo día. 1 en los demás y en los pedidos anteriores.
    @Default(1) int weeks,
    RequestRestrictions? restrictions,

    /// Respuesta a la pregunta de alergias de la web (`requests.no_allergies`):
    /// true = nadie tiene; false = las escribió; null = sin respuesta. Para
    /// mostrarla, [allergyAnswer].
    @JsonKey(name: 'no_allergies') bool? noAllergies,
    String? notes,
    @JsonKey(name: 'preferred_date')
    @CalendarDateConverter()
    CalendarDate? preferredDate,
    @JsonKey(
      name: 'preferred_slot',
      unknownEnumValue: JsonKey.nullForUndefinedEnumValue,
    )
    PreferredSlot? preferredSlot,
    @JsonKey(unknownEnumValue: ClientLocale.it)
    @Default(ClientLocale.it)
    ClientLocale locale,
    @JsonKey(name: 'whatsapp_opt_in') @Default(false) bool whatsappOptIn,
    RequestEstimate? estimate,
    @JsonKey(unknownEnumValue: RequestSource.app)
    @Default(RequestSource.app)
    RequestSource source,
    @JsonKey(name: 'seen_at') DateTime? seenAt,
    @JsonKey(name: 'created_at') required DateTime createdAt,
    @Default(RequestClient()) RequestClient client,
  }) = _ChefRequest;

  const ChefRequest._();

  /// Una fila de PostgREST seleccionada con [chefRequestColumns]. El contacto
  /// ([client]) es el que llegó con el pedido, si lo trae (ver [RequestClient]).
  factory ChefRequest.fromJson(Map<String, dynamic> json) =>
      _$ChefRequestFromJson(_withRequestContact(json));

  /// Nueva para la bandeja: Evelyn todavía no la abrió.
  bool get isNew => seenAt == null && status != RequestStatus.rejected;

  bool get isRejected => status == RequestStatus.rejected;

  /// Solo un pedido nuevo se puede rechazar desde la app (contrato §3).
  bool get canReject => status == RequestStatus.newRequest;

  /// Un rechazo de la cocinera se puede deshacer (vuelve a `new`).
  bool get canUndoReject => status == RequestStatus.rejected;

  /// La persona es todavía un prospecto: la cocinera la puede marcar como
  /// cliente (ficha en `trial`), así sus datos no se borran a los 90 días
  /// (contrato §9).
  bool get canMarkClient => client.status == ClientStatus.prospect;

  /// Cuenta para la agenda: pedidos en curso (no rechazados, vencidos ni
  /// cerrados).
  bool get isActive => switch (status) {
    RequestStatus.newRequest ||
    RequestStatus.quoted ||
    RequestStatus.accepted => true,
    RequestStatus.declined ||
    RequestStatus.rejected ||
    RequestStatus.expired ||
    RequestStatus.resolved => false,
  };

  bool get hasRestrictions => !(restrictions?.isEmpty ?? true);

  /// Qué mostrar de alergias. Con restricciones, siempre
  /// [AllergyAnswer.listed] (más vale mostrarlas, aunque diga lo contrario);
  /// sin ellas, [AllergyAnswer.none] solo si lo confirmó y si no,
  /// [AllergyAnswer.unknown].
  AllergyAnswer get allergyAnswer {
    if (hasRestrictions) return AllergyAnswer.listed;
    return noAllergies == true ? AllergyAnswer.none : AllergyAnswer.unknown;
  }

  /// Total de personas, o null si el pedido no lo indica (type = change).
  int? get people =>
      adults == null && kids == null ? null : (adults ?? 0) + (kids ?? 0);

  @override
  String toString() => 'ChefRequest($id, ${status.name})';
}

List<Meal> _mealsFromJson(Object? json) => _knownValues(Meal.values, json);

// Pedido tal como lo ve la cocinera en la bandeja y la agenda.
// Una fila de `public.requests` con los datos de contacto de su cliente
// (`public.clients`) embebidos. Los nombres de columna son los de la base
// (M1 + contrato docs/contracts/public-request.md §3).
//
// Contiene datos de salud (restricciones) y de contacto: nunca se loguea ni se
// manda a analytics (SPEC §6). Por eso los modelos no imprimen su contenido en
// toString (ver `@Freezed(toStringOverride: false)` más abajo).
import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:mestolo/core/phone.dart';
import 'package:mestolo/core/rome_time.dart';

part 'chef_request.freezed.dart';
part 'chef_request.g.dart';

/// `request_type`. `change` es solo para clientes con cuenta.
enum RequestType { week, extra, change }

/// `request_status` (SPEC §5.3). En la app la cocinera solo pasa de `new` a
/// `rejected`; el resto lo cambian las Edge Functions.
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

/// `requests.preferred_slot`.
enum PreferredSlot { morning, afternoon, any }

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
@Freezed(fromJson: false, toJson: false)
abstract class RequestEstimate with _$RequestEstimate {
  const factory RequestEstimate({
    int? portions,
    int? recipes,
    int? cookMinutes,
    int? serviceCents,
    int? groceriesEstCents,
    int? totalCents,
  }) = _RequestEstimate;

  const RequestEstimate._();

  factory RequestEstimate.fromJson(Map<String, dynamic> json) {
    int? read(String key) {
      final value = json[key];
      if (value is int) return value;
      // Un número JSON entero puede llegar como double (14100.0).
      if (value is double && value.isFinite && value == value.roundToDouble()) {
        return value.toInt();
      }
      return null;
    }

    return RequestEstimate(
      portions: read('portions'),
      recipes: read('recipes'),
      cookMinutes: read('cookMinutes'),
      serviceCents: read('serviceCents'),
      groceriesEstCents: read('groceriesEstCents'),
      totalCents: read('totalCents'),
    );
  }

  bool get isEmpty =>
      portions == null &&
      recipes == null &&
      cookMinutes == null &&
      serviceCents == null &&
      groceriesEstCents == null &&
      totalCents == null;
}

/// Datos de contacto del cliente (`public.clients`). El teléfono se guarda tal
/// como lo escribió el cliente: para WhatsApp y llamadas usar [phoneE164].
@Freezed(toJson: false, toStringOverride: false)
abstract class RequestClient with _$RequestClient {
  const factory RequestClient({
    @JsonKey(name: 'display_name') @Default('') String displayName,
    @JsonKey(name: 'contact_email') String? contactEmail,
    @JsonKey(name: 'contact_phone') String? contactPhone,
    String? zone,
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

/// Columnas que la app lee de `requests`, con el cliente embebido
/// (FK `requests (client_id, chef_id) → clients (id, chef_id)`).
const String chefRequestColumns =
    'id, chef_id, client_id, type, status, adults, kids, days, meals, '
    'restrictions, notes, preferred_date, preferred_slot, locale, '
    'whatsapp_opt_in, estimate, source, seen_at, created_at, '
    'client:clients(display_name, contact_email, contact_phone, zone)';

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
    RequestRestrictions? restrictions,
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

  /// Una fila de PostgREST seleccionada con [chefRequestColumns].
  factory ChefRequest.fromJson(Map<String, dynamic> json) =>
      _$ChefRequestFromJson(json);

  /// Nueva para la bandeja: Evelyn todavía no la abrió.
  bool get isNew => seenAt == null && status != RequestStatus.rejected;

  bool get isRejected => status == RequestStatus.rejected;

  /// Solo un pedido nuevo se puede rechazar desde la app (contrato §3).
  bool get canReject => status == RequestStatus.newRequest;

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

  /// Total de personas, o null si el pedido no lo indica (type = change).
  int? get people =>
      adults == null && kids == null ? null : (adults ?? 0) + (kids ?? 0);

  @override
  String toString() => 'ChefRequest($id, ${status.name})';
}

List<Meal> _mealsFromJson(Object? json) => _knownValues(Meal.values, json);

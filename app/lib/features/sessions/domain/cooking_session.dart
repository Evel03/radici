// Sesiones de cocina de la cocinera: una fila de `public.sessions` con su
// ficha (`clients`, con las restricciones de `client_restrictions` y su último
// pedido semanal de la web que se reservó, responda o no) y el pedido de su
// reserva (`requests`, con su contacto) embebidos. La app las lee con la
// RLS («la cocinera lee las suyas»); los estados solo cambian vía la Edge
// Function chef (CLAUDE.md), nunca desde la app. Dart puro.
//
// Una reserva es un pedido aceptado más sus sesiones, una por semana (SPEC §4).
//
// Llevan contacto, la dirección y datos de salud (las alergias de la ficha y la
// nota de los pedidos): nunca se loguean y los modelos no los imprimen en
// toString.
import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:radici/core/clock_time.dart';
import 'package:radici/core/phone.dart';
import 'package:radici/core/rome_time.dart';
import 'package:radici/features/availability/domain/availability.dart'
    show parsePgTime;
import 'package:radici/features/requests/domain/chef_request.dart';

part 'cooking_session.freezed.dart';

/// `session_status` (SPEC §5.3), con el nombre de la base.
enum SessionStatus {
  /// Presupuesto enviado: retiene el horario hasta `hold_until`.
  held('held'),
  confirmed('confirmed'),

  /// La compra hecha: sin uso desde el 19/11/2026 (la compra la hace el
  /// cliente). La base todavía lo tiene y la app lo lee, pero no lo ofrece
  /// como paso: una sesión vieja en este estado se ve como confirmada
  /// ([shown]).
  shoppingDone('shopping_done'),
  cooked('cooked'),
  paid('paid'),
  cancelled('cancelled');

  const SessionStatus(this.dbName);

  final String dbName;

  /// El de la base, o null si no es uno conocido.
  static SessionStatus? fromDb(Object? value) =>
      values.where((status) => status.dbName == value).firstOrNull;

  /// Cómo se muestra: [shoppingDone] como [confirmed], porque todavía no se
  /// cocinó y la compra ya no es un paso del servicio. Los demás, como son.
  SessionStatus get shown => this == shoppingDone ? confirmed : this;
}

/// Columnas que la app lee de `sessions`, con la ficha (sus restricciones y
/// su último pedido semanal de la web que se reservó, `answers`) y el pedido
/// de la reserva embebidos. Los nombres de las FK desambiguan:
/// `requests.target_session_id` también apunta a `sessions`, y `sessions` une
/// `clients` con `requests`. De `answers`, el repositorio pide solo el más
/// nuevo de los semanales, de la web y aceptados (sessions_repository.dart).
const String cookingSessionColumns =
    'id, chef_id, client_id, request_id, date, start_time, cook_minutes, '
    'shop_minutes, gap_minutes, portions, status, service_cents, '
    'cancelled_at, cancel_reason, '
    'client:clients!sessions_client_id_chef_id_fkey(display_name, '
    'contact_email, contact_phone, zone, address, adults, kids, kitchen_notes, '
    'status, restrictions:client_restrictions(allergen, diet), '
    'answers:requests!requests_client_id_chef_id_fkey(type, source, status, '
    'created_at, restrictions, no_allergies)), '
    'request:requests!sessions_request_id_chef_id_fkey($chefRequestColumns)';

/// Lo que la clienta contestó a la pregunta de alergias en su último pedido
/// semanal de la web que se reservó (`requests.restrictions` y
/// `requests.no_allergies`) y cuándo lo mandó (`requests.created_at`): lo de
/// su casa. Sirve para una sesión semanal cuyo pedido no responde, como una
/// renovación: una reserva a mano no guarda alergias (SPEC §6). Un pedido
/// extra no cuenta (los que comen pueden ser otros, como los invitados de una
/// cena, SPEC §5.6), ni uno que no se reservó (rechazado, vencido o
/// pendiente: pudo mandarlo otra persona con su email). Dato de salud: no se
/// imprime.
@Freezed(fromJson: false, toJson: false, toStringOverride: false)
abstract class PastAllergyAnswer with _$PastAllergyAnswer {
  const factory PastAllergyAnswer({
    required DateTime requestedAt,
    RequestRestrictions? restrictions,
    bool? noAllergies,
  }) = _PastAllergyAnswer;

  const PastAllergyAnswer._();

  /// Responde sobre alergias: las indica (alérgenos o la nota) o confirma que
  /// nadie tiene. Una dieta sola no responde.
  bool get answersAllergies =>
      noAllergies == true || (restrictions?.answersAllergies ?? false);

  @override
  String toString() => 'PastAllergyAnswer(<oculto>)';
}

/// De los pedidos embebidos en `client.answers`, el último semanal de la web
/// que se reservó (`accepted`), solo si responde sobre alergias
/// ([PastAllergyAnswer.answersAllergies]); null si no hay o si no responde.
/// Si el más nuevo no responde no se busca uno anterior: puede ser uno
/// anterior a la pregunta o uno cuya respuesta se borró (consentimiento de
/// salud retirado, o la copia borrada a pedido de otra persona, contrato
/// public-request §10.2), y entonces un «nadie tiene» viejo no vale. No
/// depende del orden en que llegan, y salta los que están rotos o no son
/// semanales, de la web y aceptados (el repositorio ya pide solo esos).
PastAllergyAnswer? _lastAllergyAnswer(Object? json) {
  if (json is! List) return null;
  PastAllergyAnswer? last;
  for (final row in json.whereType<Map<Object?, Object?>>()) {
    if (row['type'] != RequestType.week.name ||
        row['source'] != RequestSource.web.name ||
        row['status'] != RequestStatus.accepted.name) {
      continue;
    }
    final createdAt = row['created_at'];
    final requestedAt = createdAt is String
        ? DateTime.tryParse(createdAt)
        : null;
    if (requestedAt == null) continue;
    if (last != null && !requestedAt.isAfter(last.requestedAt)) continue;
    final restrictions = row['restrictions'];
    final noAllergies = row['no_allergies'];
    last = PastAllergyAnswer(
      requestedAt: requestedAt,
      restrictions: restrictions is Map
          ? RequestRestrictions.fromJson(restrictions.cast<String, dynamic>())
          : null,
      noAllergies: noAllergies is bool ? noAllergies : null,
    );
  }
  return (last?.answersAllergies ?? false) ? last : null;
}

/// La ficha de la clienta de una sesión (`clients`) y sus restricciones
/// guardadas (`client_restrictions`, con su consentimiento de salud). Datos de
/// contacto, dirección y de salud: no se imprimen.
@Freezed(fromJson: false, toJson: false, toStringOverride: false)
abstract class SessionClient with _$SessionClient {
  const factory SessionClient({
    @Default('') String displayName,
    String? contactEmail,
    String? contactPhone,
    String? zone,
    String? address,
    int? adults,
    int? kids,
    String? kitchenNotes,
    ClientStatus? status,

    /// De `client_restrictions`, en el orden del enum y sin repetir.
    @Default(<Allergen>[]) List<Allergen> allergens,
    @Default(<Diet>[]) List<Diet> diets,

    /// La respuesta de alergias de su último pedido semanal de la web que se
    /// reservó (de `answers`); null si no hay o si ese pedido no responde.
    PastAllergyAnswer? lastAllergyAnswer,
  }) = _SessionClient;

  const SessionClient._();

  /// La ficha embebida con [cookingSessionColumns]. Lanza [FormatException] si
  /// no tiene nombre.
  factory SessionClient.fromJson(Map<String, dynamic> json) {
    final name = json['display_name'];
    if (name is! String) throw const FormatException('Ficha inválida');
    final restrictions = json['restrictions'];
    final rows = restrictions is List
        ? restrictions.whereType<Map<Object?, Object?>>()
        : const <Map<Object?, Object?>>[];
    final allergens = {for (final row in rows) row['allergen']};
    final diets = {for (final row in rows) row['diet']};
    return SessionClient(
      displayName: name,
      contactEmail: _text(json['contact_email']),
      contactPhone: _text(json['contact_phone']),
      zone: _text(json['zone']),
      address: _text(json['address']),
      adults: _intOrNull(json['adults']),
      kids: _intOrNull(json['kids']),
      kitchenNotes: _text(json['kitchen_notes']),
      status: ClientStatus.values
          .where((status) => status.name == json['status'])
          .firstOrNull,
      allergens: [
        for (final allergen in Allergen.values)
          if (allergens.contains(allergen.name)) allergen,
      ],
      diets: [
        for (final diet in Diet.values)
          if (diets.contains(diet.name)) diet,
      ],
      lastAllergyAnswer: _lastAllergyAnswer(json['answers']),
    );
  }

  @override
  String toString() => 'SessionClient(<oculto>)';
}

/// Horas de una sesión, en minutos desde la medianoche de Roma: la llegada a
/// la casa y el fin de la cocina, `cook_minutes` después. `sessions.busy`
/// (SPEC §5.2) suma antes la compra (`shop_minutes`: 0 desde el 19/11/2026;
/// las sesiones de antes guardan 45) y después el margen (`gap_minutes`):
/// ninguno de los dos se muestra.
final class SessionTimes {
  const SessionTimes({required this.arrival, required this.end});

  final int arrival;
  final int end;

  /// "HH:MM" de [minutes] (fuera del día, la hora del reloj: una sesión que
  /// cruza la medianoche no rompe el texto).
  static String hhmm(int minutes) =>
      ClockTime(minutes % ClockTime.minutesPerDay).toHhMm();
}

@Freezed(fromJson: false, toJson: false, toStringOverride: false)
abstract class CookingSession with _$CookingSession {
  const factory CookingSession({
    required String id,
    required String chefId,
    required String clientId,

    /// El pedido de su reserva; null en una sesión sin pedido.
    String? requestId,

    /// Día en Roma.
    required CalendarDate date,

    /// Llegada a la casa (hora de Roma).
    required ClockTime start,
    required int cookMinutes,

    /// Copiados de chef_settings al crearla: no se mueven si cambian después.
    /// La compra (`shop_minutes`) es 0 desde el 19/11/2026 y la app no la
    /// muestra; las sesiones de antes guardan sus 45 min.
    required int shopMinutes,
    required int gapMinutes,
    @Default(0) int portions,
    required SessionStatus status,
    @Default(0) int serviceCents,
    DateTime? cancelledAt,

    /// El código guardado (`chef_cancelled`, `client_cancelled`,
    /// `chef_unavailable`, `hold_expired`, `declined`…).
    String? cancelReason,
    required SessionClient client,

    /// El pedido de la reserva, con su contacto; null sin pedido.
    ChefRequest? request,
  }) = _CookingSession;

  const CookingSession._();

  /// Una fila de PostgREST seleccionada con [cookingSessionColumns]. Lanza
  /// [FormatException] si está rota.
  factory CookingSession.fromJson(Map<String, dynamic> json) {
    final id = json['id'];
    final chefId = json['chef_id'];
    final clientId = json['client_id'];
    final requestId = json['request_id'];
    final date = json['date'];
    final start = json['start_time'];
    final cookMinutes = json['cook_minutes'];
    final shopMinutes = json['shop_minutes'];
    final gapMinutes = json['gap_minutes'];
    final status = SessionStatus.fromDb(json['status']);
    final client = json['client'];
    final request = json['request'];
    final cancelledAt = json['cancelled_at'];
    if (id is! String ||
        chefId is! String ||
        clientId is! String ||
        (requestId != null && requestId is! String) ||
        date is! String ||
        start is! String ||
        cookMinutes is! int ||
        shopMinutes is! int ||
        gapMinutes is! int ||
        status == null ||
        client is! Map ||
        (request != null && request is! Map) ||
        (cancelledAt != null && cancelledAt is! String)) {
      throw const FormatException('Fila de sessions inválida');
    }
    return CookingSession(
      id: id,
      chefId: chefId,
      clientId: clientId,
      requestId: requestId as String?,
      date: CalendarDate.parse(date),
      start: _clockTime(start),
      cookMinutes: cookMinutes,
      shopMinutes: shopMinutes,
      gapMinutes: gapMinutes,
      portions: _intOrNull(json['portions']) ?? 0,
      status: status,
      serviceCents: _intOrNull(json['service_cents']) ?? 0,
      cancelledAt: cancelledAt == null
          ? null
          : DateTime.parse(cancelledAt as String),
      cancelReason: _text(json['cancel_reason']),
      client: SessionClient.fromJson(client.cast<String, dynamic>()),
      request: request == null
          ? null
          : ChefRequest.fromJson((request as Map).cast<String, dynamic>()),
    );
  }

  /// No está cancelada: cuenta para la agenda y para «Semana k de N».
  bool get isLive => status != SessionStatus.cancelled;

  /// Solo una sesión held o confirmed se mueve (chef_move_session).
  bool get canMove =>
      status == SessionStatus.held || status == SessionStatus.confirmed;

  /// Se cancela desde held, confirmed o shopping_done (chef_cancel_sessions;
  /// shopping_done, solo en una sesión de antes del 19/11/2026).
  bool get canCancel =>
      status == SessionStatus.held ||
      status == SessionStatus.confirmed ||
      status == SessionStatus.shoppingDone;

  /// Lunes de su semana (como `sessions.week_start`).
  CalendarDate get weekStart => date.startOfWeek;

  /// Llegada y fin de la cocina, de lo guardado en la sesión (sin la compra
  /// de las sesiones de antes del 19/11/2026).
  SessionTimes get times =>
      SessionTimes(arrival: start.minutes, end: start.minutes + cookMinutes);

  /// El nombre: el del pedido de la reserva (el contacto con que llegó, y lo
  /// que falte de la ficha), como en la bandeja; sin pedido, el de la ficha.
  String get displayName {
    final fromRequest = request?.client.displayName.trim() ?? '';
    return fromRequest.isNotEmpty ? fromRequest : client.displayName;
  }

  /// Primer nombre, para saludar ("Giulia Rossi" → "Giulia").
  String get firstName {
    final name = displayName.trim();
    return name.isEmpty ? '' : name.split(RegExp(r'\s+')).first;
  }

  /// El teléfono como lo escribió la clienta, como el nombre: el del pedido
  /// y, si falta, el de la ficha.
  String? get contactPhone =>
      request?.client.contactPhone ?? client.contactPhone;

  /// Teléfono para WhatsApp y llamadas ("+39…"); null si no hay uno válido.
  String? get phoneE164 {
    final phone = contactPhone;
    return phone == null ? null : normalizePhone(phone);
  }

  /// La zona, como el nombre: la del pedido y, si falta, la de la ficha.
  String? get zone {
    final fromRequest = request?.client.zone?.trim() ?? '';
    return fromRequest.isNotEmpty ? fromRequest : client.zone;
  }

  /// Personas (adultos y niños), como el nombre: las del pedido y, si no las
  /// dice (o no hay pedido), las de la ficha; null si ninguno las dice.
  int? get people {
    final fromRequest = request?.people;
    if (fromRequest != null) return fromRequest;
    final adults = client.adults;
    final kids = client.kids;
    return adults == null && kids == null ? null : (adults ?? 0) + (kids ?? 0);
  }

  /// Idioma de la clienta (los mensajes de WhatsApp): el del pedido.
  ClientLocale get locale => request?.locale ?? ClientLocale.it;

  /// La dirección de la ficha, o null.
  String? get address => client.address;

  /// La respuesta de alergias que la sesión toma de otro pedido de la
  /// clienta: la de su último pedido semanal de la web que se reservó
  /// ([SessionClient.lastAllergyAnswer], null si ese pedido no responde),
  /// solo si la sesión es de la casa (de un pedido semanal, o sin pedido) y su
  /// pedido no responde (no trae alérgenos, nota ni «nadie tiene», como una
  /// renovación, que no guarda alergias). Una sesión extra no la toma: los que
  /// comen pueden ser otros, como los invitados de una cena (SPEC §5.6). null
  /// si no corresponde o no hay.
  PastAllergyAnswer? get earlierAllergyAnswer {
    final own = request;
    if (own != null && (own.type != RequestType.week || own.answersAllergies)) {
      return null;
    }
    return client.lastAllergyAnswer;
  }

  /// Alérgenos a evitar: los del pedido (`requests.restrictions`) o, si no
  /// responde, los del otro pedido ([earlierAllergyAnswer]), y los de la ficha
  /// (`client_restrictions`), en el orden del enum y sin repetir.
  List<Allergen> get allergens {
    final all = {
      ...?request?.restrictions?.allergens,
      ...?earlierAllergyAnswer?.restrictions?.allergens,
      ...client.allergens,
    };
    return [
      for (final allergen in Allergen.values)
        if (all.contains(allergen)) allergen,
    ];
  }

  /// Dietas del pedido, del otro pedido ([earlierAllergyAnswer]) y de la
  /// ficha, en el orden del enum y sin repetir. Se muestran siempre, pero no
  /// responden sobre alergias.
  List<Diet> get diets {
    final all = {
      ...?request?.restrictions?.diets,
      ...?earlierAllergyAnswer?.restrictions?.diets,
      ...client.diets,
    };
    return [
      for (final diet in Diet.values)
        if (all.contains(diet)) diet,
    ];
  }

  /// La nota de alergias del pedido o, si no responde, la del otro pedido
  /// ([earlierAllergyAnswer]) (texto libre: ningún control la cruza con los
  /// platos), o vacía.
  String get allergyNote {
    final own = request?.restrictions?.note.trim() ?? '';
    if (own.isNotEmpty) return own;
    return earlierAllergyAnswer?.restrictions?.note.trim() ?? '';
  }

  /// La celiaquía exige la nota de contaminación cruzada en la sesión (SPEC
  /// §5.6): gluten en la ficha o en un pedido.
  bool get needsCrossContaminationNote => allergens.contains(Allergen.gluten);

  /// Qué mostrar de alergias: indicadas si hay algún alérgeno o la nota; si
  /// no, «nadie tiene» solo si el pedido (o, si no responde, el otro) lo
  /// confirmó; si no, sin datos (hay que preguntar), también con solo una
  /// dieta.
  AllergyAnswer get allergyAnswer {
    if (allergens.isNotEmpty || allergyNote.isNotEmpty) {
      return AllergyAnswer.listed;
    }
    final confirmed =
        request?.noAllergies == true ||
        earlierAllergyAnswer?.noAllergies == true;
    return confirmed ? AllergyAnswer.none : AllergyAnswer.unknown;
  }

  /// Cuándo mandó la clienta el otro pedido de donde sale lo que se muestra
  /// de alergias ([earlierAllergyAnswer]), para decirlo con su fecha. null si
  /// sale del pedido de la reserva o no hay respuesta, y también si su «nadie
  /// tiene» no se muestra porque la ficha tiene alérgenos.
  DateTime? get earlierAnswerAt {
    final earlier = earlierAllergyAnswer;
    if (earlier == null) return null;
    final shown =
        (earlier.restrictions?.answersAllergies ?? false) ||
        allergyAnswer == AllergyAnswer.none;
    return shown ? earlier.requestedAt : null;
  }

  /// Solo el id y el estado: nada de la clienta.
  @override
  String toString() => 'CookingSession($id, ${status.name})';
}

/// Largo máximo de la dirección de una ficha (como `newClient.address` en el
/// contrato chef-api §4).
const int maxClientAddressLength = 200;

/// La dirección como se guarda: en una línea y sin espacios de más; null si
/// queda vacía.
String? normalizeClientAddress(String value) {
  final text = value.trim().replaceAll(RegExp(r'\s+'), ' ');
  return text.isEmpty ? null : text;
}

String? _text(Object? value) {
  if (value is! String) return null;
  final trimmed = value.trim();
  return trimmed.isEmpty ? null : trimmed;
}

int? _intOrNull(Object? value) => value is int ? value : null;

/// `time` de Postgres ("10:00:00") como hora del día.
ClockTime _clockTime(String value) {
  final minutes = parsePgTime(value).inMinutes;
  if (minutes >= ClockTime.minutesPerDay) {
    throw FormatException('Hora inválida', value);
  }
  return ClockTime(minutes);
}

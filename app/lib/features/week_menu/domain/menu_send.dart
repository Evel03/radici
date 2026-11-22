// El envío del menú de una semana a la clienta (SPEC 5.8, «Envío del menú»;
// contrato docs/contracts/chef-api.md §13): lo que la app manda a la función
// chef (la vista previa y el envío), lo que devuelve y lo que lee de
// `menu_sends` (con la RLS de la cocina) para saber qué salió y qué contestó
// la clienta. Dart puro.
//
// El envío vigente de una semana es el último que salió (por `sent_at` y, con
// el mismo, por id), como en la base. El mensaje de la clienta al pedir
// cambios (`changes_text`) se ve solo en la app: nunca va por email ni por
// push (SPEC §6). Nada de esto se loguea: los toString no muestran el
// contacto, los textos del mensaje ni lo que escribió la clienta.
import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:radici/core/phone.dart';
import 'package:radici/features/auth/domain/auth_models.dart' show isValidEmail;
import 'package:radici/features/quotes/domain/preview_quote.dart'
    show PreviewQuote;
import 'package:radici/features/requests/domain/chef_request.dart'
    show ClientLocale;
import 'package:radici/features/requests/domain/contact_links.dart';

part 'menu_send.freezed.dart';

/// Por dónde sale un envío (`menu_sends.sent_via`), en el orden de la base:
/// el email antes que el WhatsApp.
enum MenuSendChannel {
  email,
  whatsapp;

  static MenuSendChannel? fromDb(Object? value) =>
      values.where((channel) => channel.name == value).firstOrNull;
}

/// Los canales de [email] y [whatsapp] en el orden de la base.
List<MenuSendChannel> menuSendChannels({
  required bool email,
  required bool whatsapp,
}) => [
  if (email) MenuSendChannel.email,
  if (whatsapp) MenuSendChannel.whatsapp,
];

/// Columnas que la app lee de `menu_sends`: sin la foto (la lee la página de
/// la clienta), el idioma ni la huella.
const String menuSendColumns =
    'id, session_id, menu_version, sent_at, sent_via, client_confirmed_at, '
    'changes_requested_at, changes_text';

/// Un envío que salió, como lo lee la cocina en `menu_sends`.
@Freezed(fromJson: false, toJson: false, toStringOverride: false)
abstract class MenuSendRecord with _$MenuSendRecord {
  const factory MenuSendRecord({
    required String id,
    required String sessionId,

    /// La versión del menú que salió (`session_menus.version` de la vista
    /// previa).
    required int menuVersion,
    required DateTime sentAt,

    /// Uno o los dos, en el orden de la base.
    required List<MenuSendChannel> via,

    /// La clienta lo confirmó.
    DateTime? confirmedAt,

    /// La clienta pidió cambios, con [changesText] (de 1 a 1000 caracteres,
    /// con saltos de línea). Solo una de las dos respuestas.
    DateTime? changesRequestedAt,
    String? changesText,
  }) = _MenuSendRecord;

  const MenuSendRecord._();

  /// Una fila de `menu_sends` seleccionada con [menuSendColumns]. Lanza
  /// [FormatException] si está rota o no salió (sin `sent_at`).
  factory MenuSendRecord.fromRow(Map<String, dynamic> row) {
    final id = row['id'];
    final sessionId = row['session_id'];
    final version = row['menu_version'];
    final sentAt = _instantOrNull(row['sent_at']);
    final via = _channels(row['sent_via']);
    final confirmed = row['client_confirmed_at'];
    final changes = row['changes_requested_at'];
    final text = row['changes_text'];
    if (id is! String ||
        sessionId is! String ||
        version is! int ||
        version < 1 ||
        sentAt == null ||
        via == null ||
        (confirmed != null && _instantOrNull(confirmed) == null) ||
        (changes != null && _instantOrNull(changes) == null) ||
        (text != null && text is! String) ||
        (changes == null) != (text == null)) {
      throw const FormatException('Fila de menu_sends inválida');
    }
    return MenuSendRecord(
      id: id,
      sessionId: sessionId,
      menuVersion: version,
      sentAt: sentAt,
      via: via,
      confirmedAt: _instantOrNull(confirmed),
      changesRequestedAt: _instantOrNull(changes),
      changesText: text as String?,
    );
  }

  /// [other] salió después (con el mismo `sent_at`, el de id mayor: el orden
  /// de la base).
  bool isOlderThan(MenuSendRecord other) {
    final byTime = sentAt.compareTo(other.sentAt);
    return byTime != 0 ? byTime < 0 : id.compareTo(other.id) < 0;
  }

  /// Solo el id y la versión: nunca el mensaje de la clienta.
  @override
  String toString() => 'MenuSendRecord($id, v$menuVersion)';
}

/// El último envío que salió de cada sesión de [records].
Map<String, MenuSendRecord> latestSendsBySession(
  Iterable<MenuSendRecord> records,
) {
  final latest = <String, MenuSendRecord>{};
  for (final record in records) {
    final current = latest[record.sessionId];
    if (current == null || current.isOlderThan(record)) {
      latest[record.sessionId] = record;
    }
  }
  return latest;
}

/// Qué pasó con el menú de una semana, según su último envío.
enum MenuSendPhase {
  /// Nunca salió.
  notSent,

  /// Salió y la clienta todavía no contestó.
  sent,

  /// La clienta lo confirmó.
  confirmed,

  /// La clienta pidió cambios (con su mensaje).
  changesRequested,
}

/// El estado del envío del menú de una semana: su último envío ([send], null
/// si nunca salió) y la versión del menú guardado ([savedVersion], null si no
/// hay menú o no se sabe).
@Freezed(fromJson: false, toJson: false, toStringOverride: false)
abstract class WeekMenuSendStatus with _$WeekMenuSendStatus {
  const factory WeekMenuSendStatus({MenuSendRecord? send, int? savedVersion}) =
      _WeekMenuSendStatus;

  const WeekMenuSendStatus._();

  MenuSendPhase get phase {
    final send = this.send;
    if (send == null) return MenuSendPhase.notSent;
    if (send.confirmedAt != null) return MenuSendPhase.confirmed;
    if (send.changesRequestedAt != null) return MenuSendPhase.changesRequested;
    return MenuSendPhase.sent;
  }

  /// El menú se guardó después de mandarlo: la clienta tiene el de antes y
  /// hay que mandarlo de nuevo.
  bool get changedSinceSent {
    final send = this.send;
    final saved = savedVersion;
    return send != null && saved != null && saved > send.menuVersion;
  }

  @override
  String toString() => 'WeekMenuSendStatus(${phase.name})';
}

// ---------------------------------------------------------------------
// POST chef/menus/preview
// ---------------------------------------------------------------------

/// La vista previa del menú de [sessionId] con la versión guardada
/// [menuVersion]. [translate]: los nombres de la lista, al idioma de la
/// clienta (false: como los escribió Evelyn; la nota nunca se traduce).
@Freezed(fromJson: false, toJson: false)
abstract class MenuPreviewRequest with _$MenuPreviewRequest {
  const factory MenuPreviewRequest({
    required String sessionId,
    required int menuVersion,
    @Default(true) bool translate,
  }) = _MenuPreviewRequest;

  const MenuPreviewRequest._();

  /// El cuerpo, siempre con las tres claves (una de más es un 400).
  Map<String, Object> toBody() => {
    'sessionId': sessionId,
    'menuVersion': menuVersion,
    'translate': translate,
  };
}

/// Por qué no se puede usar el email o el teléfono del contacto.
enum ContactIssue {
  /// No hay.
  missing,

  /// Hay, pero no sirve (un email sin forma de email, un teléfono que no se
  /// puede normalizar): la función no manda nada por ahí.
  invalid,
}

/// El contacto de la clienta para el envío: el del pedido de la web o, si no
/// lo tiene, el de la ficha. Lo que la app le muestra a Evelyn antes de
/// mandar.
@Freezed(fromJson: false, toJson: false, toStringOverride: false)
abstract class MenuSendContact with _$MenuSendContact {
  const factory MenuSendContact({
    required String name,
    String? email,
    String? phone,
  }) = _MenuSendContact;

  const MenuSendContact._();

  /// El email, si sirve para mandar (la regla de la función, sendableEmail).
  String? get usableEmail {
    final email = this.email;
    return email != null && isValidEmail(email) ? email : null;
  }

  /// El teléfono en E.164 para WhatsApp, si se puede normalizar (la regla de
  /// la función, whatsappPhone).
  String? get phoneE164 {
    final phone = this.phone;
    return phone == null ? null : normalizePhone(phone);
  }

  ContactIssue? get emailIssue => email == null
      ? ContactIssue.missing
      : usableEmail == null
      ? ContactIssue.invalid
      : null;

  ContactIssue? get phoneIssue => phone == null
      ? ContactIssue.missing
      : phoneE164 == null
      ? ContactIssue.invalid
      : null;

  /// Nada del contacto.
  @override
  String toString() => 'MenuSendContact(<oculto>)';
}

/// Respuesta 200 de POST chef/menus/preview: el envío guardado sin salir y el
/// mensaje en el idioma de la clienta, sin el link (en su lugar, el texto de
/// reemplazo que manda la función).
@Freezed(fromJson: false, toJson: false, toStringOverride: false)
abstract class MenuPreview with _$MenuPreview {
  const factory MenuPreview({
    required String sendId,
    required ClientLocale locale,

    /// Los nombres de la lista se tradujeron solos.
    required bool translated,
    required MenuSendContact contact,
    required String subject,
    required String emailText,
    required String whatsappText,
  }) = _MenuPreview;

  const MenuPreview._();

  /// Lee el JSON de la respuesta. Lanza [FormatException] si no tiene la
  /// forma del contrato.
  factory MenuPreview.fromResponse(Object? json) {
    if (json is! Map) throw const FormatException('Respuesta inválida');
    final sendId = json['sendId'];
    final locale = ClientLocale.values
        .where((l) => l.name == json['locale'])
        .firstOrNull;
    final translated = json['translated'];
    final contact = json['contact'];
    final message = json['message'];
    if (sendId is! String ||
        sendId.isEmpty ||
        locale == null ||
        translated is! bool ||
        contact is! Map ||
        message is! Map) {
      throw const FormatException('Respuesta inválida');
    }
    final name = contact['name'];
    final email = _textOrNull(contact['email']);
    final phone = _textOrNull(contact['phone']);
    final subject = message['subject'];
    final emailText = message['emailText'];
    final whatsappText = message['whatsappText'];
    if (name is! String ||
        (contact['email'] != null && contact['email'] is! String) ||
        (contact['phone'] != null && contact['phone'] is! String) ||
        subject is! String ||
        emailText is! String ||
        whatsappText is! String ||
        subject.trim().isEmpty ||
        emailText.trim().isEmpty ||
        whatsappText.trim().isEmpty) {
      throw const FormatException('Respuesta inválida');
    }
    return MenuPreview(
      sendId: sendId,
      locale: locale,
      translated: translated,
      contact: MenuSendContact(name: name, email: email, phone: phone),
      subject: subject,
      emailText: emailText,
      whatsappText: whatsappText,
    );
  }

  /// Solo el id: nunca el contacto ni el mensaje.
  @override
  String toString() => 'MenuPreview($sendId)';
}

/// Columnas de una vista previa que lee la app para mostrar el presupuesto
/// que lleva: su pedido y, de la foto, solo el bloque `quote` (lo que va a ver
/// la clienta, quote_snapshot.ts). La respuesta de la vista previa no lo trae.
const String previewQuoteColumns =
    'request_id, quote_id, quote:snapshot->quote';

/// El presupuesto de una vista previa: su pedido y [quote], lo que va en la
/// foto (null si el envío no lleva presupuesto, o si la foto no cierra: el
/// mensaje lo muestra igual).
typedef PreviewSendQuote = ({String requestId, PreviewQuote? quote});

/// Una fila de `menu_sends` con [previewQuoteColumns]. Lanza
/// [FormatException] si no tiene pedido.
PreviewSendQuote previewSendQuoteFromRow(Map<String, dynamic> row) {
  final requestId = row['request_id'];
  if (requestId is! String || requestId.isEmpty) {
    throw const FormatException('Fila de menu_sends inválida');
  }
  return (
    requestId: requestId,
    quote: row['quote_id'] == null ? null : PreviewQuote.tryParse(row['quote']),
  );
}

// ---------------------------------------------------------------------
// POST chef/menus/send
// ---------------------------------------------------------------------

/// Manda el envío [sendId] de una vista previa por email, por WhatsApp o por
/// los dos (al menos uno).
@Freezed(fromJson: false, toJson: false)
abstract class MenuSendRequest with _$MenuSendRequest {
  const factory MenuSendRequest({
    required String sendId,
    required bool email,
    required bool whatsapp,
  }) = _MenuSendRequest;

  const MenuSendRequest._();

  Map<String, Object> toBody() => {
    'sendId': sendId,
    'email': email,
    'whatsapp': whatsapp,
  };
}

/// Lo que salió: la respuesta 200 de POST chef/menus/send o, si se perdió,
/// lo que dice `menu_sends` (sin el texto del WhatsApp, que solo viaja en la
/// respuesta: el link no se guarda en ningún lado).
@Freezed(fromJson: false, toJson: false, toStringOverride: false)
abstract class MenuSendResult with _$MenuSendResult {
  const factory MenuSendResult({
    required DateTime sentAt,
    required List<MenuSendChannel> via,

    /// Solo si se pidió WhatsApp: el mensaje con el link y el teléfono en
    /// E.164.
    String? whatsappText,
    String? whatsappPhone,
  }) = _MenuSendResult;

  const MenuSendResult._();

  /// Lee el JSON de la respuesta. Lanza [FormatException] si no tiene la
  /// forma del contrato.
  factory MenuSendResult.fromResponse(Object? json) {
    if (json is! Map) throw const FormatException('Respuesta inválida');
    final sentAt = _instantOrNull(json['sentAt']);
    final via = _channels(json['sentVia']);
    final text = json['whatsappText'];
    final phone = json['whatsappPhone'];
    if (sentAt == null ||
        via == null ||
        (text != null && (text is! String || text.trim().isEmpty)) ||
        (phone != null && phone is! String) ||
        (text == null) != (phone == null)) {
      throw const FormatException('Respuesta inválida');
    }
    return MenuSendResult(
      sentAt: sentAt,
      via: via,
      whatsappText: text as String?,
      whatsappPhone: phone as String?,
    );
  }

  /// `wa.me` con el mensaje y el link (el mismo armado que la confirmación de
  /// una reserva), para abrir WhatsApp desde el teléfono de quien manda; null
  /// sin el texto o con un teléfono que no es E.164.
  Uri? get whatsAppLink {
    final text = whatsappText;
    return text == null
        ? null
        : whatsAppUri(phoneE164: whatsappPhone, message: text);
  }

  /// Solo cuándo y por dónde: nunca el mensaje ni el teléfono.
  @override
  String toString() =>
      'MenuSendResult(${[for (final channel in via) channel.name].join(',')})';
}

// ---------------------------------------------------------------------
// Lectura
// ---------------------------------------------------------------------

/// Un timestamptz de la base o de la función (ISO 8601), o null.
DateTime? _instantOrNull(Object? value) =>
    value is String ? DateTime.tryParse(value) : null;

/// Una lista de uno o dos canales distintos, en el orden de la base; null si
/// tiene otra forma.
List<MenuSendChannel>? _channels(Object? value) {
  if (value is! List || value.isEmpty || value.length > 2) return null;
  final channels = [for (final item in value) MenuSendChannel.fromDb(item)];
  if (channels.contains(null) || channels.toSet().length != channels.length) {
    return null;
  }
  return [
    for (final channel in MenuSendChannel.values)
      if (channels.contains(channel)) channel,
  ];
}

/// Un texto sin espacios al borde, o null si no viene o queda vacío.
String? _textOrNull(Object? value) {
  if (value is! String) return null;
  final text = value.trim();
  return text.isEmpty ? null : text;
}

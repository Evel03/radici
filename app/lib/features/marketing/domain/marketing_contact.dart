// Un contacto de la lista de ofertas y novedades (public.marketing_contacts,
// contrato public-request §13): quien marcó la casilla en un pedido. La app lo
// lee para la lista de la cocina y la exportación; nunca lo escribe.
import 'package:radici/core/rome_time.dart';

enum MarketingContactStatus { pending, confirmed }

class MarketingContact {
  const MarketingContact({
    required this.email,
    required this.firstName,
    required this.locale,
    required this.status,
    required this.requestedAt,
    required this.confirmedAt,
  });

  final String email;
  final String? firstName;

  /// it, es o en: el idioma en que escribirle.
  final String locale;
  final MarketingContactStatus status;
  final DateTime requestedAt;

  /// Solo los confirmados.
  final DateTime? confirmedAt;

  /// Columnas que lee la app (la base no deja leer el hash del token ni el
  /// pedido de origen). Las bajas no se piden.
  static const String columns =
      'email, first_name, locale, status, requested_at, confirmed_at';

  factory MarketingContact.fromJson(Map<String, dynamic> json) {
    final status = switch (json['status']) {
      'pending' => MarketingContactStatus.pending,
      'confirmed' => MarketingContactStatus.confirmed,
      _ => throw const FormatException('status'),
    };
    final confirmed = json['confirmed_at'];
    return MarketingContact(
      email: json['email'] as String,
      firstName: json['first_name'] as String?,
      locale: json['locale'] as String,
      status: status,
      requestedAt: DateTime.parse(json['requested_at'] as String),
      confirmedAt: confirmed == null ? null : DateTime.parse(confirmed as String),
    );
  }

  // Sin el email ni el nombre: nunca se loguean datos personales.
  @override
  String toString() => 'MarketingContact(${status.name})';
}

/// El CSV para exportar los confirmados (los pendientes todavía no aceptaron:
/// no se exportan): una fila por contacto con el email, el nombre, el idioma y
/// la fecha de la confirmación (día de Roma, AAAA-MM-DD), con los encabezados
/// [header]. Separado por comas, con comillas donde hace falta (RFC 4180) y
/// saltos de línea CRLF. Un valor que empieza con =, +, - o @ lleva un
/// apóstrofo adelante: así una planilla nunca lo toma como fórmula.
String marketingContactsCsv(
  Iterable<MarketingContact> contacts, {
  required List<String> header,
}) {
  String cell(String value) {
    final safe = RegExp(r'^[=+\-@]').hasMatch(value) ? "'$value" : value;
    return RegExp(r'[",\r\n]').hasMatch(safe)
        ? '"${safe.replaceAll('"', '""')}"'
        : safe;
  }

  final rows = <String>[header.map(cell).join(',')];
  for (final contact in contacts) {
    final confirmedAt = contact.confirmedAt;
    if (contact.status != MarketingContactStatus.confirmed ||
        confirmedAt == null) {
      continue;
    }
    rows.add(
      [
        contact.email,
        contact.firstName ?? '',
        contact.locale,
        romeToday(confirmedAt).toIso(),
      ].map(cell).join(','),
    );
  }
  return '${rows.join('\r\n')}\r\n';
}

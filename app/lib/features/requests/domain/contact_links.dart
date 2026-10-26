// Links para contactar al cliente desde el detalle del pedido: WhatsApp
// (wa.me), llamada (tel:) y email (mailto:). Dart puro; los textos llegan ya
// traducidos al idioma del cliente.
//
// Los parámetros se codifican con Uri.encodeComponent (espacios como %20):
// `Uri(queryParameters:)` los pasaría a "+", que los clientes de correo
// muestran tal cual (ver README de url_launcher).

/// `https://wa.me/<número sin +>?text=<mensaje>`, o null sin teléfono válido.
///
/// [phoneE164] es `+<dígitos>` (ver `normalizePhone`).
Uri? whatsAppUri({required String? phoneE164, required String message}) {
  final digits = _e164Digits(phoneE164);
  if (digits == null) return null;
  return Uri.parse(
    'https://wa.me/$digits?text=${Uri.encodeComponent(message)}',
  );
}

/// `tel:+<dígitos>`, o null sin teléfono válido.
Uri? phoneCallUri(String? phoneE164) {
  final digits = _e164Digits(phoneE164);
  return digits == null ? null : Uri(scheme: 'tel', path: '+$digits');
}

/// `mailto:<email>?subject=…&body=…`, o null sin email.
Uri? emailUri({
  required String? email,
  required String subject,
  String body = '',
}) {
  final address = email?.trim() ?? '';
  if (address.isEmpty || !address.contains('@')) return null;
  final query = [
    'subject=${Uri.encodeComponent(subject)}',
    if (body.isNotEmpty) 'body=${Uri.encodeComponent(body)}',
  ].join('&');
  return Uri(scheme: 'mailto', path: address, query: query);
}

final RegExp _e164 = RegExp(r'^\+([1-9]\d{7,14})$');

String? _e164Digits(String? phoneE164) {
  if (phoneE164 == null) return null;
  return _e164.firstMatch(phoneE164)?.group(1);
}

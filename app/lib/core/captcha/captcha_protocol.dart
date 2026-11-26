// Protocolo con la página /captcha/ de la web (el Turnstile de Auth); el lado
// de la web está en web/src/captcha/protocol.ts y docs/contracts/auth.md §10.
// Lógica pura, sin plataforma: la comparten la versión web (iframe) y la nativa
// (el navegador del sistema, canal «return»: captcha_return.dart).
//
// La página no manda nada sola: espera un pedido con un id al azar y contesta
// con ese id, así un token siempre es la respuesta a un pedido de quien lo
// hizo. Mensajes de la página: ready, interactive, token, error. Del host a la
// página: request (id).
// El token es la credencial de un solo uso de Auth: nunca se loguea.
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart' show immutable;

const String captchaMessageSource = 'radici-captcha';
const int captchaProtocolVersion = 1;

/// Canal JavaScript que la app nativa instala en la página.
const String captchaNativeChannel = 'RadiciCaptcha';

/// Función global con la que la app nativa le hace un pedido a la página.
const String captchaNativeRequestFunction = 'radiciCaptchaRequest';

/// Ruta de la página, en el mismo sitio que la web y la bandeja.
const String captchaPagePath = '/captcha/';

/// Sitio público: la versión nativa abre siempre esta página (la web usa el
/// origen en el que corre). No se puede configurar a propósito: la lista de lo
/// (y la vuelta del canal «return», captcha_return.dart) apunta a este origen.
const String captchaProductionOrigin = 'https://radicicucina.app';

/// Lo que dice la página.
@immutable
sealed class CaptchaReply {
  const CaptchaReply();
}

/// La página cargó y espera un pedido.
final class CaptchaReady extends CaptchaReply {
  const CaptchaReady();
}

/// Cloudflare pide que la persona toque la casilla (o ya no).
final class CaptchaInteractive extends CaptchaReply {
  const CaptchaInteractive({required this.id, required this.visible});
  final String id;
  final bool visible;
}

/// El token del pedido [id].
final class CaptchaToken extends CaptchaReply {
  const CaptchaToken({required this.id, required this.token});
  final String id;
  final String token;

  // Sin el token: nunca se loguea.
  @override
  String toString() => 'CaptchaToken($id)';
}

/// El pedido [id] terminó sin token. [code]: texto corto y seguro (un código
/// de Turnstile, «timeout», «cancelled»…).
final class CaptchaError extends CaptchaReply {
  const CaptchaError({required this.id, required this.code});
  final String id;
  final String code;
}

/// La página no pudo cargar (sin red): lo avisa el propio host, no la
/// página. [code]: el código del error, si hay.
final class CaptchaLoadFailed extends CaptchaReply {
  const CaptchaLoadFailed({this.code});
  final int? code;
}

/// Esquema con el que la página vuelve a la app en el canal «return» (iOS y
/// Android): radicicaptcha://result?id=…&token=… o …&code=… (captcha_return.dart).
const String captchaReturnScheme = 'radicicaptcha';

/// Un código corto y seguro para el diagnóstico: solo letras, dígitos, «_» y
/// «-», hasta 32 caracteres; si no, «unknown» (nunca texto libre).
String safeCaptchaCode(String code) => _codePattern.hasMatch(code) ? code : 'unknown';

/// Lo que trajo la vuelta del canal «return»: el token del pedido [id], el
/// error con su código, o null si la dirección no es la esperada (otro
/// esquema, otro id, un token con otra forma sin código).
CaptchaReply? parseCaptchaReturn(String url, String id) {
  final Uri uri;
  try {
    uri = Uri.parse(url);
  } on FormatException {
    return null;
  }
  if (uri.scheme != captchaReturnScheme || uri.host != 'result') return null;
  final params = uri.queryParameters;
  if (params['id'] != id || !isCaptchaId(id)) return null;
  final token = params['token'];
  if (token != null) {
    return _tokenPattern.hasMatch(token) ? CaptchaToken(id: id, token: token) : CaptchaError(id: id, code: 'token-shape');
  }
  final code = params['code'];
  if (code != null) return CaptchaError(id: id, code: safeCaptchaCode(code));
  return null;
}

final RegExp _idPattern = RegExp(r'^[0-9a-f]{32}$');
final RegExp _tokenPattern = RegExp(r'^[\w.-]{1,2048}$');
final RegExp _codePattern = RegExp(r'^[\w-]{1,32}$');

/// Id de un pedido: 128 bits al azar en hexadecimal minúscula.
bool isCaptchaId(Object? value) => value is String && _idPattern.hasMatch(value);

/// Un id nuevo. [random] es para los tests; por defecto [Random.secure].
String newCaptchaId([Random? random]) {
  final source = random ?? Random.secure();
  return [
    for (var i = 0; i < 16; i++) source.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ].join();
}

/// Lo que dijo la página: [raw] es un string JSON o un mapa (lo que llega por
/// postMessage). Todo lo que no encaja (otra
/// marca, otra versión, un campo con otra forma) da null: se ignora.
CaptchaReply? parseCaptchaReply(Object? raw) {
  Object? value = raw;
  if (raw is String) {
    try {
      value = jsonDecode(raw);
    } on FormatException {
      return null;
    }
  }
  if (value is! Map) return null;
  if (value['source'] != captchaMessageSource || value['v'] != captchaProtocolVersion) return null;
  final id = value['id'];
  switch (value['type']) {
    case 'ready':
      return const CaptchaReady();
    case 'interactive':
      final visible = value['visible'];
      if (!isCaptchaId(id) || visible is! bool) return null;
      return CaptchaInteractive(id: id as String, visible: visible);
    case 'token':
      final token = value['token'];
      if (!isCaptchaId(id)) return null;
      // Un token con otra forma no se usa, pero el pedido termina con el motivo (para el diagnóstico).
      if (token is! String || !_tokenPattern.hasMatch(token)) {
        return CaptchaError(id: id as String, code: 'token-shape');
      }
      return CaptchaToken(id: id as String, token: token);
    case 'error':
      final code = value['code'];
      if (!isCaptchaId(id) || code is! String || !_codePattern.hasMatch(code)) return null;
      return CaptchaError(id: id as String, code: code);
  }
  return null;
}

/// El pedido de un token a la página (string JSON).
String captchaRequestMessage(String id) {
  if (!isCaptchaId(id)) throw ArgumentError.value(id, 'id', 'No es un id de pedido');
  return jsonEncode({
    'source': captchaMessageSource,
    'v': captchaProtocolVersion,
    'type': 'request',
    'id': id,
  });
}

/// Dirección de la página en [origin] (con `?lang=` para que sus textos salgan
/// en el idioma de la app; en iOS y Android, `channel=return` y el id del pedido).
Uri captchaPageUri(String origin, {String? locale, String? returnId}) {
  final base = Uri.parse(origin);
  final query = {
    if (returnId != null && isCaptchaId(returnId)) ...{'channel': 'return', 'id': returnId},
    if (locale != null && const {'it', 'es', 'en'}.contains(locale)) 'lang': locale,
  };
  return Uri(
    scheme: base.scheme,
    host: base.host,
    port: base.hasPort ? base.port : null,
    path: captchaPagePath,
    queryParameters: query.isEmpty ? null : query,
  );
}

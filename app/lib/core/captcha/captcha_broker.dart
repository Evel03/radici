// Un token de captcha por llamada: abre una sesión con la página /captcha/,
// le pide un token con un id nuevo y espera la respuesta con ese id (o un
// error, o el tiempo). Lógica pura, sin plataforma: la sesión (iframe o
// WebView) la pone cada plataforma. Nunca lanza: si no hay token, devuelve null.
import 'dart:async';

import 'package:radici/core/captcha/captcha_protocol.dart';
import 'package:radici/core/captcha/captcha_service.dart';

/// Una apertura de la página /captcha/ para un solo pedido. [replies] ya trae
/// solo lo que pasó la verificación de origen de la plataforma (el origen
/// exacto en la web, la página fijada en la WebView).
abstract interface class CaptchaSession {
  Stream<CaptchaReply> get replies;

  /// Le pide un token a la página (después de su `ready`).
  void request(String id);

  /// Cierra la página (la saca del DOM o de la pantalla). Se llama siempre.
  void dispose();
}

typedef CaptchaSessionFactory = CaptchaSession Function(String? locale);

/// Lo que espera cada fase. Turnstile suele resolver en pocos segundos; si
/// pide que la persona toque la casilla, hay más tiempo.
const Duration captchaTimeout = Duration(seconds: 20);
const Duration captchaInteractiveTimeout = Duration(seconds: 120);

class CaptchaBroker implements CaptchaService {
  CaptchaBroker({
    required this.sessionFactory,
    this.timeout = captchaTimeout,
    this.interactiveTimeout = captchaInteractiveTimeout,
    String Function()? newId,
  }) : _newId = newId ?? newCaptchaId;

  final CaptchaSessionFactory sessionFactory;
  final Duration timeout;
  final Duration interactiveTimeout;
  final String Function() _newId;

  @override
  String? lastFailure;

  /// Un pedido a la vez: cada uno abre su propia página y un token es de uno
  /// solo.
  Future<void> _tail = Future<void>.value();

  @override
  Future<String?> token({String? locale}) {
    final result = _tail.then((_) => _run(locale));
    _tail = result.then((_) {}, onError: (_) {});
    return result;
  }

  Future<String?> _run(String? locale) async {
    final id = _newId();
    final done = Completer<String?>();
    Timer? timer;
    StreamSubscription<CaptchaReply>? subscription;
    CaptchaSession? session;
    // Para el diagnóstico (lastFailure): qué pasó antes de un fallo.
    var ready = false;
    var interactive = false;
    String? blocked;

    void finish(String? token, [String? failure]) {
      if (done.isCompleted) return;
      lastFailure = token != null ? null : _diagnostic(failure ?? 'app-unknown', blocked);
      done.complete(token);
    }

    void arm(Duration after) {
      timer?.cancel();
      timer = Timer(
        after,
        () => finish(null, !ready ? 'app-no-ready' : (interactive ? 'app-timeout-interactive' : 'app-timeout')),
      );
    }

    try {
      session = sessionFactory(locale);
      subscription = session.replies.listen(
        (reply) {
          switch (reply) {
            case CaptchaReady():
              ready = true;
              // Una página que se recarga vuelve a avisar: se le repite el pedido.
              try {
                session?.request(id);
              } on Object {
                finish(null, 'app-request');
              }
            case CaptchaInteractive(id: final replyId, :final visible) when replyId == id:
              if (visible) interactive = true;
              arm(visible ? interactiveTimeout : timeout);
            case CaptchaToken(id: final replyId, :final token) when replyId == id:
              finish(token);
            case CaptchaError(id: final replyId, :final code) when replyId == id:
              finish(null, 'page-$code');
            case CaptchaLoadFailed(:final code):
              finish(null, code == null ? 'app-load' : 'app-load$code');
            case CaptchaBlocked(:final what):
              blocked = what;
            // Un id que no es el de este pedido, o un aviso fuera de turno: se ignora.
            case CaptchaInteractive() || CaptchaToken() || CaptchaError():
              break;
          }
        },
        onError: (Object _) => finish(null, 'app-stream'),
        onDone: () => finish(null, 'app-closed'),
      );
      arm(timeout);
      return await done.future;
    } on Object {
      // La plataforma no puede abrir la página (sin WebView, sin DOM): sin token.
      lastFailure = 'app-unavailable';
      return null;
    } finally {
      timer?.cancel();
      unawaited(subscription?.cancel());
      try {
        session?.dispose();
      } on Object {
        // Ya estaba cerrada.
      }
    }
  }
}

/// El código del diagnóstico: el motivo y, si la WebView frenó una navegación,
/// cuál («…+blocked-https:otro.host»). Solo letras, dígitos y «.:+_-».
String _diagnostic(String failure, String? blocked) {
  final text = blocked == null ? failure : '$failure+blocked-$blocked';
  final safe = text.replaceAll(RegExp(r'[^\w.:+-]'), '');
  return safe.length > 80 ? safe.substring(0, 80) : safe;
}

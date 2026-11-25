// Estado de la WebView del captcha en iOS y Android: qué WebView está abierta
// (la crea CaptchaSession nativa en cada pedido) y si Cloudflare pidió que la
// persona toque la casilla. Lo dibuja CaptchaHost; acá no hay widgets.
import 'package:flutter/foundation.dart' show immutable;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:webview_flutter/webview_flutter.dart';

@immutable
class CaptchaUiState {
  const CaptchaUiState({this.controller, this.interactive = false});

  /// La WebView abierta, o null si no hay un pedido en curso.
  final WebViewController? controller;

  /// La persona tiene que tocar la casilla: la WebView se muestra en grande.
  final bool interactive;
}

class CaptchaUi extends Notifier<CaptchaUiState> {
  @override
  CaptchaUiState build() => const CaptchaUiState();

  void open(WebViewController controller) => state = CaptchaUiState(controller: controller);

  void setInteractive({required bool visible}) {
    if (state.controller == null) return;
    state = CaptchaUiState(controller: state.controller, interactive: visible);
  }

  /// Cierra [controller] solo si sigue siendo la WebView abierta (una sesión
  /// vieja que se cierra tarde no cierra la nueva).
  void close(WebViewController controller) {
    if (identical(state.controller, controller)) state = const CaptchaUiState();
  }
}

final captchaUiProvider = NotifierProvider<CaptchaUi, CaptchaUiState>(CaptchaUi.new);

// Dónde se ve la WebView del captcha en iOS y Android: encima de toda la app
// (se pone en el builder de MaterialApp). Casi siempre mide 1×1 px y no se ve;
// si Cloudflare pide tocar la casilla se agranda al centro con un fondo
// atenuado (el botón «Annulla» es de la propia página, con su idioma). En la
// web el marco lo maneja captcha_platform_web.dart y acá no se dibuja nada.
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:radici/core/captcha/captcha_ui.dart';
import 'package:webview_flutter/webview_flutter.dart';

/// Medidas de la ventana con la casilla: entran el título, el widget de
/// Turnstile (300×65) y «Annulla» de la página.
const double captchaDialogWidth = 340;
const double captchaDialogHeight = 260;

class CaptchaHost extends ConsumerWidget {
  const CaptchaHost({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = kIsWeb ? null : ref.watch(captchaUiProvider.select((s) => s.controller));
    final interactive = ref.watch(captchaUiProvider.select((s) => s.interactive));

    // Siempre un Stack con el hijo en el mismo lugar: la app no se reconstruye
    // cuando aparece o desaparece la WebView.
    return Stack(
      children: [
        Positioned.fill(child: child),
        if (controller != null)
          Positioned.fill(
            // La misma cadena de widgets en los dos modos: la WebView no se vuelve a crear al agrandarse.
            child: IgnorePointer(
              ignoring: !interactive,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () {},
                child: ColoredBox(
                  color: interactive ? Colors.black54 : Colors.transparent,
                  child: Align(
                    alignment: interactive ? Alignment.center : Alignment.bottomLeft,
                    child: SizedBox(
                      key: const ValueKey('captcha-webview-box'),
                      width: interactive ? captchaDialogWidth : 1,
                      height: interactive ? captchaDialogHeight : 1,
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(interactive ? 12 : 0),
                        child: WebViewWidget(controller: controller),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

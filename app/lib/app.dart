// Raíz de la UI: router, tema y localizaciones.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:radici/core/captcha/captcha_host.dart';
import 'package:radici/core/env.dart';
import 'package:radici/core/router.dart';
import 'package:radici/core/theme.dart';
import 'package:radici/features/requests/presentation/new_request_alert_listener.dart';
import 'package:radici/features/settings/application/language_controller.dart';
import 'package:radici/features/web_app/presentation/web_app_notices.dart';
import 'package:radici/l10n/app_localizations.dart';

/// Idiomas soportados. El primero es el de respaldo cuando el idioma del
/// dispositivo no está soportado: italiano (clientes de Bergamo).
/// gen-l10n los ordena alfabéticamente, por eso se fija el orden acá.
const List<Locale> appSupportedLocales = [
  Locale('it'),
  Locale('es'),
  Locale('en'),
];

class RadiciApp extends ConsumerWidget {
  const RadiciApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final showBackendNotice = ref.watch(appEnvProvider).showBackendNotice;

    return MaterialApp.router(
      onGenerateTitle: (context) => AppLocalizations.of(context).appTitle,
      theme: buildLightTheme(),
      darkTheme: buildDarkTheme(),
      // Con sesión, el idioma del perfil; sin sesión (null), el del
      // dispositivo, o italiano si no está soportado.
      locale: ref.watch(appLocaleProvider),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: appSupportedLocales,
      routerConfig: ref.watch(routerProvider),
      builder: (context, child) {
        // El aviso de pedidos nuevos escucha desde acá, encima de todas las
        // rutas (ver NewRequestAlertListener). Arriba, los avisos de la web:
        // versión nueva y Safari fuera de la app instalada (ver WebAppNotices).
        // CaptchaHost, encima de todo: la WebView del captcha de Auth en iOS y
        // Android (en la web no dibuja nada).
        final content = CaptchaHost(
          child: WebAppNotices(
            child: NewRequestAlertListener(
              child: child ?? const SizedBox.shrink(),
            ),
          ),
        );
        if (!showBackendNotice) return content;
        return Column(
          children: [
            // El aviso ocupa el borde inferior y su SafeArea: el contenido
            // de arriba no tiene que reservar ese margen otra vez.
            Expanded(
              child: MediaQuery.removePadding(
                context: context,
                removeBottom: true,
                child: content,
              ),
            ),
            const _BackendNotice(),
          ],
        );
      },
    );
  }
}

/// Franja discreta al pie, solo en dev cuando no hay Supabase configurado.
class _BackendNotice extends StatelessWidget {
  const _BackendNotice();

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Material(
      color: colors.surfaceContainerHighest,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                Icons.cloud_off_outlined,
                size: 16,
                color: colors.onSurfaceVariant,
              ),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  AppLocalizations.of(context).backendNotConfigured,
                  style: Theme.of(context).textTheme.labelSmall
                      ?.copyWith(color: colors.onSurfaceVariant),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

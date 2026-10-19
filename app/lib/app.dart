// Raíz de la UI: router, tema y localizaciones.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mestolo/core/env.dart';
import 'package:mestolo/core/router.dart';
import 'package:mestolo/core/theme.dart';
import 'package:mestolo/l10n/app_localizations.dart';

/// Idiomas soportados. El primero es el de respaldo cuando el idioma del
/// dispositivo no está soportado: italiano (clientes de Bergamo).
/// gen-l10n los ordena alfabéticamente, por eso se fija el orden acá.
const List<Locale> appSupportedLocales = [
  Locale('it'),
  Locale('es'),
  Locale('en'),
];

class MestoloApp extends ConsumerWidget {
  const MestoloApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final showBackendNotice = ref.watch(appEnvProvider).showBackendNotice;

    return MaterialApp.router(
      onGenerateTitle: (context) => AppLocalizations.of(context).appTitle,
      theme: buildLightTheme(),
      darkTheme: buildDarkTheme(),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: appSupportedLocales,
      routerConfig: ref.watch(routerProvider),
      builder: (context, child) {
        final content = child ?? const SizedBox.shrink();
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

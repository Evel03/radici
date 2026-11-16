// Avisos de la app web (/gestione/), arriba de todas las pantallas (también
// del login, adonde llega Evelyn desde el botón del email):
// - «C'è una nuova versione · Aggiorna» (AppUpdateController);
// - en el iPhone o el iPad fuera de la app instalada, la tarjeta que le
//   recuerda abrir Radici desde el ícono (InstallHintController).
// Fuera de la web nunca aparecen (no hay id compilado ni página).
//
// Va en el builder de MaterialApp (app.dart), encima del Navigator: sigue ahí
// aunque cambie la ruta, pero no tiene Overlay, así que los botones llevan
// texto y nada de tooltips. También dispara la lectura de build.json: al
// abrir y al volver a primer plano (AppUpdateController decide si toca).
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:radici/features/web_app/application/app_update_controller.dart';
import 'package:radici/features/web_app/application/install_hint_controller.dart';
import 'package:radici/l10n/app_localizations.dart';

class WebAppNotices extends ConsumerStatefulWidget {
  const WebAppNotices({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<WebAppNotices> createState() => _WebAppNoticesState();
}

class _WebAppNoticesState extends ConsumerState<WebAppNotices> {
  late final AppLifecycleListener _lifecycle;

  /// Los avisos aparecen desde el segundo cuadro. En la web, runApp arma la
  /// app antes del primer layout y en ese momento el foco de la página puede
  /// pedir el primer elemento por orden de lectura, que mide cada botón: el de
  /// un aviso todavía no tendría tamaño («RenderBox was not laid out»).
  bool _firstFrameDone = false;

  @override
  void initState() {
    super.initState();
    // En la web, "resumed" llega cuando la página vuelve a verse o recupera el
    // foco (por ejemplo, al volver a la app desde la pantalla de inicio).
    _lifecycle = AppLifecycleListener(onResume: _checkForUpdate);
    // Al abrir, después del primer cuadro: un provider no cambia mientras se
    // construye la pantalla.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      setState(() => _firstFrameDone = true);
      _checkForUpdate();
    });
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    super.dispose();
  }

  void _checkForUpdate() =>
      unawaited(ref.read(appUpdateControllerProvider.notifier).check());

  @override
  Widget build(BuildContext context) {
    final updateAvailable = ref.watch(appUpdateControllerProvider);
    final showInstallHint = ref.watch(installHintControllerProvider);
    final notices = [
      if (_firstFrameDone && updateAvailable) const _UpdateBanner(),
      if (_firstFrameDone && showInstallHint) const _InstallHintCard(),
    ];

    // La misma estructura con o sin avisos: si cambiara, la app de abajo (el
    // router y sus pantallas) se armaría de nuevo y perdería dónde estaba.
    return Column(
      children: [
        if (notices.isEmpty)
          const SizedBox.shrink()
        else
          // Los avisos ocupan el borde superior y su SafeArea: la pantalla de
          // abajo no reserva ese margen otra vez.
          Material(
            color: Theme.of(context).colorScheme.surface,
            child: SafeArea(
              bottom: false,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: notices,
              ),
            ),
          ),
        Expanded(
          child: MediaQuery.removePadding(
            context: context,
            removeTop: notices.isNotEmpty,
            child: widget.child,
          ),
        ),
      ],
    );
  }
}

/// «C'è una nuova versione · Aggiorna». No se cierra: se va al recargar.
class _UpdateBanner extends ConsumerWidget {
  const _UpdateBanner();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Material(
      key: const ValueKey('update-banner'),
      color: colors.primaryContainer,
      child: Padding(
        padding: const EdgeInsetsDirectional.fromSTEB(16, 4, 8, 4),
        child: Row(
          children: [
            Icon(Icons.new_releases_outlined, color: colors.onPrimaryContainer),
            const SizedBox(width: 12),
            Expanded(
              child: Semantics(
                liveRegion: true,
                child: Text(
                  l10n.updateAvailable,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: colors.onPrimaryContainer,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            FilledButton(
              key: const ValueKey('update-banner-reload'),
              onPressed: ref.read(appUpdateControllerProvider.notifier).reload,
              child: Text(l10n.updateReload),
            ),
          ],
        ),
      ),
    );
  }
}

/// «Para no volver a entrar, abre Radici desde el ícono de tu pantalla de
/// inicio», con «Cerrar» (un botón con texto: nada escondido en gestos).
class _InstallHintCard extends ConsumerWidget {
  const _InstallHintCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      child: Card(
        key: const ValueKey('install-hint'),
        margin: EdgeInsets.zero,
        child: Padding(
          padding: const EdgeInsetsDirectional.fromSTEB(16, 12, 8, 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    Icons.add_to_home_screen,
                    color: theme.colorScheme.primary,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      l10n.installHint,
                      style: theme.textTheme.bodyMedium,
                    ),
                  ),
                ],
              ),
              Align(
                alignment: AlignmentDirectional.centerEnd,
                child: TextButton(
                  key: const ValueKey('install-hint-close'),
                  onPressed: ref
                      .read(installHintControllerProvider.notifier)
                      .dismiss,
                  child: Text(l10n.actionClose),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

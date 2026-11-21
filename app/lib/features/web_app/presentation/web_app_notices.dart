// Avisos de la app web (/gestione/), arriba de todas las pantallas (también
// del login, adonde llega Evelyn desde el botón del email):
// - «C'è una nuova versione · Aggiorna» (AppUpdateController);
// - en el iPhone o el iPad fuera de la app instalada, la tarjeta que le
//   recuerda abrir Radici desde el ícono (InstallHintController).
// Fuera de la web nunca aparecen (no hay id compilado ni página). Con el
// teclado abierto se esconden y vuelven al cerrarlo: le quitan su alto a
// todas las pantallas, y en un iPhone en Safari no quedaba lugar para el campo
// que se escribe y la acción de abajo (como «Conferma» de la hoja de reserva).
// Mientras haya un diálogo abierto, también (ver OpenDialogsObserver): los
// diálogos van en el Navigator, debajo de los avisos, y en un iPhone SE en
// Safari el calendario quedaba aplastado y «OK» del reloj, cortado y sin
// poder tocarse.
//
// Va en el builder de MaterialApp (app.dart), encima del Navigator: sigue ahí
// aunque cambie la ruta, pero no tiene Overlay, así que los botones llevan
// texto y nada de tooltips. También dispara la lectura de build.json: al
// abrir y al volver a primer plano (AppUpdateController decide si toca).
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:radici/core/open_dialogs.dart';
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
    // Flutter web informa el teclado del teléfono como viewInsets. Esconder
    // un aviso no es cerrarlo: vuelve al cerrar el teclado o el diálogo.
    final keyboardOpen = MediaQuery.viewInsetsOf(context).bottom > 0;
    final dialogOpen = ref.watch(openDialogsProvider.select((n) => n > 0));
    final visible = _firstFrameDone && !keyboardOpen && !dialogOpen;
    final notices = [
      if (visible && updateAvailable) const _UpdateBanner(),
      if (visible && showInstallHint) const _InstallHintCard(),
    ];

    // La misma estructura con o sin avisos: la app de abajo (el router y sus
    // pantallas) no cambia de lugar en el árbol cuando aparece o se va uno.
    return Column(
      children: [
        if (notices.isEmpty)
          const SizedBox.shrink()
        else
          // Los avisos ocupan el borde superior y su SafeArea: la pantalla de
          // abajo no reserva ese margen otra vez. (Flutter web 3.47 informa
          // siempre un margen 0, así que hoy no cambia nada; queda correcto si
          // la vista algún día informa la muesca.)
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
          // Un contenedor de semántica propio para la app de abajo: cada ruta
          // pone su barrera en un BlockSemantics, que descarta lo pintado
          // antes dentro del mismo contenedor. Sin esto VoiceOver no vería los
          // avisos (ni podría tocar «Aggiorna» o «Chiudi»).
          child: Semantics(
            container: true,
            child: MediaQuery.removePadding(
              context: context,
              removeTop: notices.isNotEmpty,
              child: widget.child,
            ),
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
        // 8 abajo: «Aggiorna» queda a 8 px de lo de abajo (las acciones de la
        // barra de cada pantalla; con un diálogo abierto, como el calendario
        // de rango con «Salva» arriba, el aviso no está).
        padding: const EdgeInsetsDirectional.fromSTEB(16, 8, 8, 8),
        child: Row(
          children: [
            Icon(Icons.new_releases_outlined, color: colors.onPrimaryContainer),
            const SizedBox(width: 12),
            Expanded(
              // Un nodo propio que VoiceOver anuncia al aparecer.
              child: Semantics(
                container: true,
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
      // 8 abajo: «Chiudi» queda a 8 px de lo de abajo.
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
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
                  // VoiceOver: «Chiudi il promemoria», distinto de otros
                  // «Chiudi» de la pantalla (empieza con el texto visible).
                  child: Text(
                    l10n.actionClose,
                    semanticsLabel: l10n.installHintClose,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

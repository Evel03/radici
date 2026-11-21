// Diálogos abiertos en el navegador raíz: los de showDialog y el calendario y
// el reloj (showDatePicker, showDateRangePicker y showTimePicker), que en esta
// app van todos ahí (con useRootNavigator en true, como viene). Mientras haya
// uno, los avisos de /gestione/ se esconden (ver WebAppNotices): van encima
// del Navigator, así que cada diálogo tenía solo el alto que dejaban, y en un
// iPhone SE en Safari el calendario quedaba aplastado y «OK» del reloj,
// cortado y sin poder tocarse.
//
// Cada diálogo cuenta desde que se abre hasta que termina de cerrarse
// (TransitionRoute.completed: después de la animación de salida, o cuando sale
// de la pila sin animación). Si los avisos volvieran cuando empieza a irse, el
// diálogo se achicaría en plena salida: el reloj en modo escritura, con el
// teclado cerrándose, daba un error de layout.
//
// Los menús y las listas desplegables (también rutas emergentes) no cuentan:
// salen pegados a su botón y no necesitan la pantalla entera; esconder los
// avisos movería la pantalla de abajo con el menú abierto.
import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Cuántos diálogos hay abiertos en el navegador raíz (los cuenta
/// [OpenDialogsObserver]).
final openDialogsProvider = NotifierProvider<OpenDialogs, int>(OpenDialogs.new);

class OpenDialogs extends Notifier<int> {
  @override
  int build() => 0;

  void _opened() => state++;

  void _closed() {
    // La app se cerró (el contenedor ya no está) antes que el diálogo.
    if (ref.mounted) state--;
  }
}

/// Le avisa a [OpenDialogs] cada diálogo que se abre en el navegador que
/// observa y cuando termina de cerrarse.
class OpenDialogsObserver extends NavigatorObserver {
  OpenDialogsObserver(this._dialogs);

  final OpenDialogs _dialogs;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      _track(route);

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    if (newRoute != null) _track(newRoute);
  }

  void _track(Route<dynamic> route) {
    if (route is! RawDialogRoute) return;
    _dialogs._opened();
    unawaited(route.completed.whenComplete(_dialogs._closed));
  }
}

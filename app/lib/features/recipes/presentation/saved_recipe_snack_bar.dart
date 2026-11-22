// El aviso de un plato recién guardado, en la lista de platos o en el menú de
// una semana (si se creó desde «Nuevo plato»). Guardado sin traducir deja algo
// por hacer (escribir el italiano y el inglés, o volver a guardar): dura como
// los avisos de error y, con VoiceOver o TalkBack, no se va solo (se cierra
// con la X).
import 'package:flutter/material.dart';
import 'package:radici/features/availability/presentation/availability_actions.dart';

/// Cuánto dura el aviso de un plato guardado como siempre.
const Duration savedRecipeSnackBarDuration = Duration(seconds: 4);

/// El aviso [message] de un plato guardado; [untranslated]: se guardó sin
/// traducir.
SnackBar savedRecipeSnackBar(
  BuildContext context, {
  required String message,
  required bool untranslated,
}) {
  final persist = untranslated && MediaQuery.accessibleNavigationOf(context);
  return SnackBar(
    content: Text(message),
    duration: untranslated
        ? errorSnackBarDuration
        : savedRecipeSnackBarDuration,
    persist: persist,
    showCloseIcon: persist,
  );
}

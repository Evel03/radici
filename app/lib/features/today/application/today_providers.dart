// Hoy, el inicio de la cocinera: la sesión de hoy (o la próxima), los enlaces
// de sus botones, las reservas que terminan y la tira de 7 días. Todo sale de
// lo que ya lee la agenda (las sesiones, la disponibilidad y la bandeja) y de
// «hoy» en Roma (romeTodayProvider, que cambia a la medianoche sin reabrir la
// app). Nada se loguea: las sesiones llevan la dirección y las alergias.
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:radici/core/clock.dart';
import 'package:radici/features/auth/application/session_controller.dart';
import 'package:radici/features/availability/application/availability_controller.dart';
import 'package:radici/features/requests/application/agenda_controller.dart';
import 'package:radici/features/sessions/application/session_links.dart';
import 'package:radici/features/sessions/application/sessions_controller.dart';
import 'package:radici/features/sessions/domain/cooking_session.dart';
import 'package:radici/features/today/domain/today.dart';

/// Cada cuánto se vuelve a mirar la hora como mucho. Como en romeTodayRecheck:
/// si el teléfono se suspende, un Timer largo llegaría tarde.
const Duration todayNowRecheck = Duration(minutes: 1);

/// «Ahora», al minuto: cambia al empezar cada minuto (si el teléfono estuvo
/// suspendido, como mucho [todayNowRecheck] después de volver). Con él, Hoy
/// pone primera la próxima sesión del día cuando termina una, sin reabrir la
/// app.
final todayNowProvider = NotifierProvider<TodayNow, DateTime>(TodayNow.new);

class TodayNow extends Notifier<DateTime> {
  Timer? _timer;

  @override
  DateTime build() {
    final now = ref.watch(clockProvider);
    ref.onDispose(() => _timer?.cancel());
    final current = _minute(now());
    _schedule(now);
    return current;
  }

  /// Programa la próxima revisión al empezar el minuto siguiente. Nunca antes
  /// de un segundo: si el reloj del sistema retrocede, no se revisa en bucle.
  void _schedule(DateTime Function() now) {
    _timer?.cancel();
    final instant = now();
    var wait =
        todayNowRecheck -
        Duration(
          seconds: instant.second,
          milliseconds: instant.millisecond,
          microseconds: instant.microsecond,
        );
    if (wait < const Duration(seconds: 1)) wait = const Duration(seconds: 1);
    _timer = Timer(wait, () {
      final current = _minute(now());
      if (current != state) state = current;
      _schedule(now);
    });
  }
}

/// [instant] sin segundos, en UTC.
DateTime _minute(DateTime instant) {
  final utc = instant.toUtc();
  return DateTime.utc(utc.year, utc.month, utc.day, utc.hour, utc.minute);
}

/// Qué sesión muestra Hoy (ver todayFocus). Con las sesiones ya leídas, lo
/// que hay (también mientras se vuelven a leer o si la última lectura
/// falló); sin ninguna lectura, cargando o el error.
final todayFocusProvider = Provider<AsyncValue<TodayFocus>>((ref) {
  final sessions = ref.watch(sessionsControllerProvider);
  final today = ref.watch(romeTodayProvider);
  final now = ref.watch(todayNowProvider);
  final list = sessions.value;
  if (list != null) {
    return AsyncData(todayFocus(list, today: today, now: now));
  }
  final error = sessions.error;
  if (error != null) {
    return AsyncError(error, sessions.stackTrace ?? StackTrace.empty);
  }
  return const AsyncLoading();
});

/// Los enlaces de los botones de abajo («Cómo llegar» y WhatsApp) para la
/// sesión principal de Hoy; null si no hay ninguna.
final todayLinksProvider = Provider<SessionLinks?>((ref) {
  final session = ref.watch(todayFocusProvider).value?.main;
  if (session == null) return null;
  return sessionLinksFor(
    session,
    chefName: ref.watch(currentChefProvider)?.displayName ?? '',
    appleMaps: ref.watch(appleMapsProvider),
  );
});

/// Las reservas que terminan (ver endingBookings): la última sesión de cada
/// una, por fecha. Vacío mientras las sesiones cargan.
final todayEndingBookingsProvider = Provider<List<CookingSession>>(
  (ref) => endingBookings(
    ref.watch(sessionsControllerProvider).value ?? const [],
    today: ref.watch(romeTodayProvider),
  ),
);

/// La tira de 7 días: las sesiones vivas de cada día (las de la agenda) y su
/// estado con la disponibilidad de la agenda, sin estado mientras no está.
final todayStripProvider = Provider<List<TodayStripDay>>((ref) {
  final ready = ref.watch(availabilityReadyProvider);
  return todayStrip(
    today: ref.watch(romeTodayProvider),
    sessionsByDate: ref.watch(agendaSessionsByDateProvider),
    availability: ready
        ? ref.watch(availabilityControllerProvider).value
        : null,
  );
});

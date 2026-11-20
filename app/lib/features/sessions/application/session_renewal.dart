// «Rinnova» en la ficha de una sesión (decisión 3): la fila va en la última
// sesión viva de una reserva semanal, y dice si la clienta ya tiene otra
// sesión viva después (una renovación u otra reserva) sin esconder el botón.
// Nada de esto se loguea.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:radici/core/rome_time.dart';
import 'package:radici/features/sessions/application/renewed_bookings.dart';
import 'package:radici/features/sessions/application/sessions_controller.dart';
import 'package:radici/features/sessions/domain/session_booking.dart';

/// La ficha de la sesión [sessionId] ofrece «Rinnova»: con la ficha leída, es
/// la última sesión viva de una reserva semanal (isLastLiveOfWeeklyBooking).
/// No depende de la agenda: con dos reservas en paralelo de la misma ficha,
/// cada una conserva su «Rinnova», y el botón no aparece y desaparece
/// mientras la agenda carga.
final sessionRenewalOfferProvider = Provider.autoDispose.family<bool, String>(
  (ref, sessionId) {
    final detail = ref.watch(sessionDetailProvider(sessionId)).value;
    return detail != null &&
        isLastLiveOfWeeklyBooking(detail.session, detail.booking);
  },
);

/// El día de la próxima sesión viva de la ficha de la sesión [sessionId],
/// para «Ha già un'altra sessione…»: de la agenda, solo si ya se leyó (sin
/// leer, no se sabe; nunca una lista vacía en su lugar); si no hay ahí, la
/// primera fecha de una renovación de su reserva hecha desde este
/// dispositivo (renewedBookingsProvider); si no, null.
final sessionLaterSessionProvider = Provider.autoDispose
    .family<CalendarDate?, String>((ref, sessionId) {
      final detail = ref.watch(sessionDetailProvider(sessionId)).value;
      if (detail == null) return null;
      final agenda = ref.watch(sessionsControllerProvider);
      if (agenda.hasValue) {
        final next = nextLiveSessionOfClient(
          detail.session,
          agenda.requireValue,
        );
        if (next != null) return next.date;
      }
      final requestId = detail.session.requestId;
      return requestId == null
          ? null
          : ref.watch(renewedBookingsProvider)[requestId];
    });

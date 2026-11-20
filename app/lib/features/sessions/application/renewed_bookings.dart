// Reservas renovadas desde este dispositivo: el pedido de cada reserva que se
// renovó con «Rinnova» y la primera fecha guardada de su renovación. Así el
// pendiente de Hoy desaparece y la ficha dice «Ha già un'altra sessione…»
// en el acto, aunque la agenda no se haya podido volver a leer después de
// confirmar (ese refresco no avisa si falla).
//
// Va en sessions/ y no en bookings/: lo leen Hoy y la ficha, y bookings/ ya
// importa sessions/. Solo en memoria, hasta recargar la app: cuando la agenda
// trae las sesiones nuevas, la regla del pendiente ya esconde la reserva. Sin
// datos de la clienta: ids y fechas.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:radici/core/rome_time.dart';

final renewedBookingsProvider =
    NotifierProvider<RenewedBookings, Map<String, CalendarDate>>(
      RenewedBookings.new,
    );

class RenewedBookings extends Notifier<Map<String, CalendarDate>> {
  @override
  Map<String, CalendarDate> build() => const {};

  /// La reserva del pedido [requestId] se renovó y su renovación empieza el
  /// [firstDate]. Lo llama la hoja después de confirmar (también un
  /// reintento que el servidor reconoce).
  void mark(String requestId, CalendarDate firstDate) {
    if (state[requestId] == firstDate) return;
    state = {...state, requestId: firstDate};
  }
}

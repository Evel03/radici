// Deslizar para actualizar en la Agenda y en Hoy: vuelve a leer la bandeja,
// la disponibilidad y las sesiones juntas. Sin Realtime de sesiones, entre dos
// dispositivos alcanza con esto (plan del área de Evelyn).
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:radici/features/availability/application/availability_controller.dart';
import 'package:radici/features/availability/data/availability_repository.dart';
import 'package:radici/features/requests/application/chef_inbox_controller.dart';
import 'package:radici/features/requests/data/chef_requests_repository.dart';
import 'package:radici/features/sessions/application/sessions_controller.dart';
import 'package:radici/features/sessions/data/sessions_repository.dart';

/// Vuelve a leer todo; devuelve false si alguna lectura falló (de esa queda
/// lo que había, para avisar).
final refreshChefDataProvider = Provider<Future<bool> Function()>(
  (ref) => () async {
    final results = await Future.wait([
      _attempt(ref.read(chefInboxProvider.notifier).refresh),
      _attempt(ref.read(availabilityControllerProvider.notifier).refresh),
      _attempt(ref.read(sessionsControllerProvider.notifier).refresh),
    ]);
    return !results.contains(false);
  },
);

Future<bool> _attempt(Future<void> Function() refresh) async {
  try {
    await refresh();
    return true;
  } on RequestsFailure {
    return false;
  } on AvailabilityFailure {
    return false;
  } on SessionFailure {
    return false;
  }
}

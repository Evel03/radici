// Providers del área de la clienta. Se crean recién cuando una pantalla de la
// clienta los usa: en /gestione/ ninguno llega a existir (la prueba de humo de
// test/core/entry_smoke_test.dart lo vigila por el nombre).
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:radici/features/auth/application/session_controller.dart';
import 'package:radici/features/auth/domain/auth_models.dart';

/// Cuenta de la clienta con sesión abierta, o null.
final clientAccountProvider = Provider<ClientAccount?>(
  (ref) => switch (ref.watch(sessionControllerProvider)) {
    ClientSession(:final client) => client,
    _ => null,
  },
  name: 'clientAccount',
);

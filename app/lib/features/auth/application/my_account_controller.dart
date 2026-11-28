// «Mi cuenta» (auth.md §20): la clienta ve y corrige los datos de su cuenta, borra sus respuestas opcionales o borra
// la cuenta entera. Los datos se leen con [accountDetailsProvider]; los cambios pasan por [MyAccountController].
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:radici/core/clock.dart';
import 'package:radici/core/rome_time.dart';
import 'package:radici/features/auth/application/session_controller.dart';
import 'package:radici/features/auth/data/account_repository.dart';
import 'package:radici/features/auth/domain/sign_up_form.dart';

/// Los datos guardados de la cuenta de la sesión (null: todavía no los cargó, por ejemplo una cuenta de antes del
/// alta con datos).
final accountDetailsProvider = FutureProvider.autoDispose<Map<String, Object?>?>(
  (ref) => ref.watch(accountRepositoryProvider).fetchAccountDetails(),
);

/// Hay que (volver a) aceptar la privacy: sin datos guardados, o aceptados con otra versión.
bool needsPrivacy(Map<String, Object?>? details) =>
    details == null || details['privacy_version'] != accountPrivacyVersion;

class MyAccountState {
  const MyAccountState({
    this.busy = false,
    this.problems = const {},
    this.failed = false,
    this.saved = false,
    this.deleted = false,
  });

  final bool busy;

  /// Los campos con un problema (de la app o de la base).
  final Map<SignUpField, Object> problems;

  /// No se pudo guardar o borrar (la red).
  final bool failed;

  /// Se acaba de guardar.
  final bool saved;

  /// La cuenta se borró (enseguida se sale).
  final bool deleted;

  // Sin los datos: solo qué campos tienen un problema.
  @override
  String toString() =>
      'MyAccountState(busy: $busy, problems: ${problems.keys.map((k) => k.name).toList()}, failed: $failed, '
      'saved: $saved, deleted: $deleted)';
}

/// Se descarta al salir de la pantalla.
final myAccountControllerProvider = NotifierProvider.autoDispose<MyAccountController, MyAccountState>(
  MyAccountController.new,
);

class MyAccountController extends Notifier<MyAccountState> {
  @override
  MyAccountState build() => const MyAccountState();

  /// Guarda los datos ([form]: los de la pantalla; [current]: los guardados). [privacyAccepted] cuenta solo si hay
  /// que aceptar la privacy ([needsPrivacy]).
  Future<void> save(SignUpForm form, {required Map<String, Object?>? current, bool privacyAccepted = false}) async {
    if (state.busy || state.deleted) return;
    final today = romeToday(ref.read(clockProvider)());
    final problems = detailsProblems(form, DateTime(today.year, today.month, today.day));
    if (needsPrivacy(current) && !privacyAccepted) problems[SignUpField.privacy] = true;
    if (problems.isNotEmpty) {
      state = MyAccountState(problems: problems);
      return;
    }
    state = const MyAccountState(busy: true);
    try {
      await ref.read(accountRepositoryProvider).saveAccountDetails(accountDetailsPayload(form));
    } on AccountDetailsRejected catch (rejected) {
      if (!ref.mounted) return;
      state = MyAccountState(
        problems: {for (final field in rejected.fields) field: true},
        failed: rejected.fields.isEmpty,
      );
      return;
    } on Object {
      if (!ref.mounted) return;
      state = const MyAccountState(failed: true);
      return;
    }
    if (!ref.mounted) return;
    ref.invalidate(accountDetailsProvider);
    state = const MyAccountState(saved: true);
  }

  /// Borra la cuenta y sale (el router la lleva al inicio).
  Future<void> deleteAccount() async {
    if (state.busy || state.deleted) return;
    state = const MyAccountState(busy: true);
    try {
      await ref.read(accountRepositoryProvider).deleteMyAccount();
    } on Object {
      if (!ref.mounted) return;
      state = const MyAccountState(failed: true);
      return;
    }
    if (!ref.mounted) return;
    state = const MyAccountState(deleted: true);
    // La cuenta ya no existe: se cierra la sesión de este dispositivo (si el aviso al servidor falla, la sesión local
    // igual se borra: AuthRepository.signOut).
    await ref.read(sessionControllerProvider.notifier).signOut();
  }
}

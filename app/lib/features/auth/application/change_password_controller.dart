// «Cambia password» del área de la clienta: la actual y la nueva, escrita dos
// veces (un error de tipeo no deja una contraseña que nadie conoce). Auth pide la
// actual (security_update_password_require_current_password, PR14), manda el
// aviso de contraseña cambiada y cierra las otras sesiones de la cuenta; esta
// sigue abierta.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:radici/features/auth/data/auth_repository.dart';
import 'package:radici/features/auth/domain/auth_models.dart';
import 'package:radici/features/auth/domain/password_rules.dart';

part 'change_password_controller.freezed.dart';

@freezed
abstract class ChangePasswordState with _$ChangePasswordState {
  const factory ChangePasswordState({
    /// Hay un pedido al servidor en curso.
    @Default(false) bool busy,

    /// Error a mostrar, o null: [AuthFailureKind.passwordRequired] y
    /// [AuthFailureKind.wrongCurrentPassword] van con la actual,
    /// [AuthFailureKind.weakPassword] y [AuthFailureKind.samePassword] con la
    /// nueva y los demás debajo del botón.
    AuthFailureKind? error,

    /// Lo que le falta a la contraseña nueva (la regla de Auth), o null.
    PasswordProblem? problem,

    /// La repetición no es igual a la contraseña nueva.
    @Default(false) bool mismatch,

    /// La contraseña quedó cambiada.
    @Default(false) bool done,
  }) = _ChangePasswordState;
}

/// Se descarta al salir de la pantalla.
final changePasswordControllerProvider =
    NotifierProvider.autoDispose<ChangePasswordController, ChangePasswordState>(
      ChangePasswordController.new,
    );

class ChangePasswordController extends Notifier<ChangePasswordState> {
  @override
  ChangePasswordState build() => const ChangePasswordState();

  Future<void> submit({
    required String currentPassword,
    required String newPassword,
    required String repeatPassword,
  }) async {
    if (state.busy || state.done) return;
    if (currentPassword.isEmpty) {
      state = const ChangePasswordState(error: AuthFailureKind.passwordRequired);
      return;
    }
    final problem = passwordProblem(newPassword);
    if (problem != null) {
      state = ChangePasswordState(problem: problem);
      return;
    }
    if (repeatPassword != newPassword) {
      state = const ChangePasswordState(mismatch: true);
      return;
    }
    if (newPassword == currentPassword) {
      state = const ChangePasswordState(error: AuthFailureKind.samePassword);
      return;
    }
    state = const ChangePasswordState(busy: true);
    try {
      await ref
          .read(authRepositoryProvider)
          .changePassword(
            currentPassword: currentPassword,
            newPassword: newPassword,
          );
      if (!ref.mounted) return;
      state = const ChangePasswordState(done: true);
    } on AuthFailure catch (failure) {
      if (!ref.mounted) return;
      state = ChangePasswordState(error: failure.kind);
    }
  }
}

// El error de Auth que llegó solo (un link de acceso vencido o ya usado) para
// que el login lo muestre. Vive desde el arranque: el error del link de la URL
// de arranque llega antes de que se abra el login. Se borra al pedir un código
// nuevo y cuando se abre una sesión.
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:radici/features/auth/data/auth_repository.dart';
import 'package:radici/features/auth/domain/auth_models.dart';

final authLinkErrorProvider =
    NotifierProvider<AuthLinkErrorController, AuthFailureKind?>(
      AuthLinkErrorController.new,
    );

class AuthLinkErrorController extends Notifier<AuthFailureKind?> {
  @override
  AuthFailureKind? build() {
    final auth = ref.watch(authRepositoryProvider);
    final failures = auth.failures().listen(
      (failure) => state = failure.kind,
      onError: (Object _) {},
    );
    final users = auth.userChanges().listen((user) {
      if (user != null) state = null;
    }, onError: (Object _) {});
    ref.onDispose(() {
      unawaited(failures.cancel());
      unawaited(users.cancel());
    });
    return null;
  }

  void clear() => state = null;
}

// «Cambia password» del área de la clienta (/area/password): la actual y la
// nueva. Solo muestra el estado de ChangePasswordController y le pasa lo que
// escribe la clienta: no llama a Supabase.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:radici/core/routes.dart';
import 'package:radici/features/auth/application/change_password_controller.dart';
import 'package:radici/features/auth/domain/auth_models.dart';
import 'package:radici/features/auth/presentation/auth_texts.dart';
import 'package:radici/features/auth/presentation/busy_button.dart';
import 'package:radici/l10n/app_localizations.dart';

class ChangePasswordScreen extends ConsumerStatefulWidget {
  const ChangePasswordScreen({super.key});

  @override
  ConsumerState<ChangePasswordScreen> createState() =>
      _ChangePasswordScreenState();
}

class _ChangePasswordScreenState extends ConsumerState<ChangePasswordScreen> {
  final TextEditingController _current = TextEditingController();
  final TextEditingController _next = TextEditingController();
  bool _obscure = true;

  @override
  void dispose() {
    _current.dispose();
    _next.dispose();
    super.dispose();
  }

  void _submit() => ref
      .read(changePasswordControllerProvider.notifier)
      .submit(currentPassword: _current.text, newPassword: _next.text);

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final state = ref.watch(changePasswordControllerProvider);
    ref.listen(changePasswordControllerProvider.select((s) => s.done), (
      _,
      done,
    ) {
      if (!done) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          key: const ValueKey('change-password-done'),
          content: Text(l10n.changePasswordDone),
        ),
      );
      context.canPop() ? context.pop() : context.go(AppRoutes.area);
    });

    final error = state.error;
    final currentError = switch (error) {
      AuthFailureKind.passwordRequired ||
      AuthFailureKind.wrongCurrentPassword => authErrorText(l10n, error!),
      _ => null,
    };
    final problem = state.problem;
    final newError = problem != null
        ? passwordProblemText(l10n, problem)
        : switch (error) {
            AuthFailureKind.weakPassword ||
            AuthFailureKind.samePassword => authErrorText(l10n, error!),
            _ => null,
          };
    final otherError = error != null && currentError == null && newError == null
        ? authErrorText(l10n, error)
        : null;
    final toggle = IconButton(
      key: const ValueKey('change-password-toggle'),
      tooltip: _obscure ? l10n.loginPasswordShow : l10n.loginPasswordHide,
      icon: Icon(
        _obscure ? Icons.visibility_outlined : Icons.visibility_off_outlined,
      ),
      onPressed: () => setState(() => _obscure = !_obscure),
    );

    return Scaffold(
      appBar: AppBar(title: Text(l10n.changePasswordTitle)),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 480),
              child: AutofillGroup(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    TextField(
                      key: const ValueKey('change-password-current'),
                      controller: _current,
                      enabled: !state.busy,
                      obscureText: _obscure,
                      autofillHints: const [AutofillHints.password],
                      autocorrect: false,
                      enableSuggestions: false,
                      textInputAction: TextInputAction.next,
                      onSubmitted: (_) => FocusScope.of(context).nextFocus(),
                      decoration: InputDecoration(
                        labelText: l10n.changePasswordCurrent,
                        prefixIcon: const Icon(Icons.lock_outline),
                        errorText: currentError,
                        errorMaxLines: 4,
                      ),
                    ),
                    const SizedBox(height: 16),
                    TextField(
                      key: const ValueKey('change-password-new'),
                      controller: _next,
                      enabled: !state.busy,
                      obscureText: _obscure,
                      autofillHints: const [AutofillHints.newPassword],
                      autocorrect: false,
                      enableSuggestions: false,
                      textInputAction: TextInputAction.done,
                      onSubmitted: (_) => _submit(),
                      decoration: InputDecoration(
                        labelText: l10n.changePasswordNew,
                        prefixIcon: const Icon(Icons.lock_reset),
                        suffixIcon: toggle,
                        helperText: l10n.passwordHint,
                        helperMaxLines: 2,
                        errorText: newError,
                        errorMaxLines: 4,
                      ),
                    ),
                    const SizedBox(height: 16),
                    BusyButton(
                      key: const ValueKey('change-password-save'),
                      busy: state.busy,
                      onPressed: _submit,
                      label: l10n.changePasswordSave,
                    ),
                    if (otherError != null) ...[
                      const SizedBox(height: 12),
                      Semantics(
                        liveRegion: true,
                        child: Text(
                          otherError,
                          key: const ValueKey('change-password-error'),
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: theme.colorScheme.error,
                          ),
                        ),
                      ),
                    ],
                    const SizedBox(height: 24),
                    Text(
                      l10n.changePasswordForgot,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

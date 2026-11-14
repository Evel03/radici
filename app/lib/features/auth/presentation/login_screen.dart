// Login con código por email (dos pasos). Solo muestra el estado de
// LoginController y le pasa lo que escribe el usuario: no llama a Supabase.
// Arriba, el logotipo: en la web (/gestione/) es la primera pantalla.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:radici/core/platform.dart';
import 'package:radici/core/radici_logo.dart';
import 'package:radici/features/auth/application/login_controller.dart';
import 'package:radici/features/auth/domain/auth_models.dart';
import 'package:radici/l10n/app_localizations.dart';

class LoginScreen extends ConsumerWidget {
  const LoginScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final step = ref.watch(loginControllerProvider.select((s) => s.step));
    // En la web el login es la primera pantalla: volver llevaría a `/`, que
    // redirige otra vez acá.
    final isWeb = ref.watch(isWebProvider);

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.loginTitle),
        automaticallyImplyLeading: !isWeb,
      ),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 480),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const _BrandHeader(),
                  const SizedBox(height: 32),
                  AutofillGroup(
                    child: switch (step) {
                      LoginStep.email => const _EmailStep(),
                      LoginStep.code => const _CodeStep(),
                    },
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Logotipo de la marca (nombre y rótulo).
class _BrandHeader extends StatelessWidget {
  const _BrandHeader();

  @override
  Widget build(BuildContext context) {
    return const Center(key: ValueKey('login-brand'), child: RadiciLogo());
  }
}

String authErrorText(AppLocalizations l10n, AuthFailureKind kind) =>
    switch (kind) {
      AuthFailureKind.invalidEmail => l10n.authErrorInvalidEmail,
      AuthFailureKind.invalidCode => l10n.authErrorInvalidCode,
      AuthFailureKind.rateLimited => l10n.authErrorRateLimited,
      AuthFailureKind.network => l10n.authErrorNetwork,
      AuthFailureKind.notAllowed => l10n.authErrorNotAllowed,
      AuthFailureKind.noBackend => l10n.authErrorNoBackend,
      AuthFailureKind.unknown => l10n.authErrorUnknown,
    };

class _EmailStep extends ConsumerStatefulWidget {
  const _EmailStep();

  @override
  ConsumerState<_EmailStep> createState() => _EmailStepState();
}

class _EmailStepState extends ConsumerState<_EmailStep> {
  late final TextEditingController _email = TextEditingController(
    text: ref.read(loginControllerProvider).email,
  );

  @override
  void dispose() {
    _email.dispose();
    super.dispose();
  }

  void _submit() => ref
      .read(loginControllerProvider.notifier)
      .submitEmail(
        _email.text,
        locale: Localizations.localeOf(context).languageCode,
      );

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final state = ref.watch(loginControllerProvider);
    final error = state.error;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(l10n.loginBody, style: theme.textTheme.bodyLarge),
        const SizedBox(height: 24),
        TextField(
          key: const ValueKey('login-email'),
          controller: _email,
          enabled: !state.busy,
          keyboardType: TextInputType.emailAddress,
          autofillHints: const [AutofillHints.email],
          autocorrect: false,
          enableSuggestions: false,
          textInputAction: TextInputAction.send,
          onSubmitted: (_) => _submit(),
          decoration: InputDecoration(
            labelText: l10n.loginEmailLabel,
            hintText: l10n.loginEmailHint,
            prefixIcon: const Icon(Icons.mail_outline),
            errorText: error == null ? null : authErrorText(l10n, error),
            errorMaxLines: 3,
          ),
        ),
        const SizedBox(height: 16),
        _BusyButton(
          key: const ValueKey('login-send-code'),
          busy: state.busy,
          onPressed: _submit,
          label: l10n.loginSendCode,
        ),
      ],
    );
  }
}

class _CodeStep extends ConsumerStatefulWidget {
  const _CodeStep();

  @override
  ConsumerState<_CodeStep> createState() => _CodeStepState();
}

class _CodeStepState extends ConsumerState<_CodeStep> {
  final TextEditingController _code = TextEditingController();

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  void _submit() =>
      ref.read(loginControllerProvider.notifier).submitCode(_code.text);

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final state = ref.watch(loginControllerProvider);
    final notifier = ref.read(loginControllerProvider.notifier);
    final error = state.error;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          l10n.loginCodeSentTo(state.email),
          key: const ValueKey('login-code-sent-to'),
          style: theme.textTheme.bodyLarge,
        ),
        const SizedBox(height: 24),
        TextField(
          key: const ValueKey('login-code'),
          controller: _code,
          enabled: !state.busy,
          autofocus: true,
          keyboardType: TextInputType.number,
          autofillHints: const [AutofillHints.oneTimeCode],
          inputFormatters: [
            FilteringTextInputFormatter.digitsOnly,
            LengthLimitingTextInputFormatter(otpMaxLength),
          ],
          textInputAction: TextInputAction.done,
          onSubmitted: (_) => _submit(),
          style: theme.textTheme.headlineSmall?.copyWith(letterSpacing: 4),
          decoration: InputDecoration(
            labelText: l10n.loginCodeLabel,
            hintText: l10n.loginCodeHint,
            // El espaciado entre cifras es para el código, no para la ayuda.
            hintStyle: theme.textTheme.bodyLarge?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
            prefixIcon: const Icon(Icons.password),
            helperText: l10n.loginSpamHint,
            helperMaxLines: 2,
            errorText: error == null ? null : authErrorText(l10n, error),
            errorMaxLines: 3,
          ),
        ),
        const SizedBox(height: 16),
        _BusyButton(
          key: const ValueKey('login-verify'),
          busy: state.busy,
          onPressed: _submit,
          label: l10n.loginVerify,
        ),
        if (state.codeResent) ...[
          const SizedBox(height: 12),
          Text(
            l10n.loginCodeResent,
            key: const ValueKey('login-code-resent'),
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.primary,
            ),
          ),
        ],
        const SizedBox(height: 8),
        Wrap(
          alignment: WrapAlignment.center,
          spacing: 8,
          children: [
            TextButton(
              key: const ValueKey('login-resend'),
              onPressed: state.busy ? null : notifier.resendCode,
              child: Text(l10n.loginResendCode),
            ),
            TextButton(
              key: const ValueKey('login-change-email'),
              onPressed: state.busy ? null : notifier.changeEmail,
              child: Text(l10n.loginChangeEmail),
            ),
          ],
        ),
      ],
    );
  }
}

/// Botón principal que muestra una rueda mientras espera al servidor.
class _BusyButton extends StatelessWidget {
  const _BusyButton({
    super.key,
    required this.busy,
    required this.onPressed,
    required this.label,
  });

  final bool busy;
  final VoidCallback onPressed;
  final String label;

  @override
  Widget build(BuildContext context) {
    return FilledButton(
      onPressed: busy ? null : onPressed,
      child: busy
          ? SizedBox.square(
              dimension: 20,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                semanticsLabel: label,
              ),
            )
          : Text(label),
    );
  }
}

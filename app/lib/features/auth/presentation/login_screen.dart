// El login de cada entrada (app_entry.dart):
// - /gestione/ (la cocina): solo el código por email, en dos pasos.
// - /app/ (las clientas): email y contraseña, «Crea account» y «Password
//   dimenticata?» (PasswordAccessView).
// - La app nativa (las dos cuentas): el acceso con contraseña y, debajo, el
//   «Accesso cucina» con el código, para Evelyn y sus colaboradores.
// Solo muestra el estado de los controllers y les pasa lo que escribe el
// usuario: no llama a Supabase. Arriba, el logotipo: en la web es la primera
// pantalla.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:radici/core/app_entry.dart';
import 'package:radici/core/platform.dart';
import 'package:radici/core/radici_logo.dart';
import 'package:radici/features/auth/application/auth_link_error.dart';
import 'package:radici/features/auth/application/login_controller.dart';
import 'package:radici/features/auth/domain/auth_models.dart';
import 'package:radici/features/auth/presentation/auth_texts.dart';
import 'package:radici/features/auth/presentation/busy_button.dart';
import 'package:radici/features/auth/presentation/password_access_view.dart';
import 'package:radici/l10n/app_localizations.dart';

/// Cómo se entra: con el código del email (la cocina) o con la contraseña
/// (las clientas).
enum LoginMethod { code, password }

/// El método con que abre el login en [entry]: el código en /gestione/, la
/// contraseña en /app/ y en la app nativa.
LoginMethod initialLoginMethod(AppEntry entry) => switch (entry) {
  AppEntry.kitchen => LoginMethod.code,
  AppEntry.client || AppEntry.auto => LoginMethod.password,
};

class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key, this.initialEmail});

  /// Email ya escrito, de `/accedi?email=` (el «Vai al login» de /accesso/).
  /// Se usa solo si es un email válido.
  final String? initialEmail;

  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen> {
  late LoginMethod _method = initialLoginMethod(ref.read(appEntryProvider));

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final step = ref.watch(loginControllerProvider.select((s) => s.step));
    // En la web el login es la primera pantalla: volver llevaría a `/`, que
    // redirige otra vez acá.
    final isWeb = ref.watch(isWebProvider);
    // Solo la app nativa sirve a las dos cuentas: ahí se pasa de un método
    // al otro. En la web cada entrada tiene el suyo.
    final canSwitch = ref.watch(appEntryProvider) == AppEntry.auto;

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
                  _LinkError(method: _method),
                  AutofillGroup(
                    child: switch (_method) {
                      LoginMethod.password => PasswordAccessView(
                        initialEmail: widget.initialEmail,
                      ),
                      LoginMethod.code => switch (step) {
                        LoginStep.email => _EmailStep(
                          initialEmail: widget.initialEmail,
                        ),
                        LoginStep.code => const _CodeStep(),
                      },
                    },
                  ),
                  if (canSwitch) ...[
                    const SizedBox(height: 24),
                    TextButton(
                      key: const ValueKey('login-switch-method'),
                      onPressed: () => setState(
                        () => _method = _method == LoginMethod.password
                            ? LoginMethod.code
                            : LoginMethod.password,
                      ),
                      child: Text(
                        _method == LoginMethod.password
                            ? l10n.loginKitchenCode
                            : l10n.loginUsePassword,
                        textAlign: TextAlign.center,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// El link de acceso que llegó con un error (vencido, ya usado): se dice acá
/// y se pide un código nuevo (o, con la contraseña, que se vuelva a entrar).
class _LinkError extends ConsumerWidget {
  const _LinkError({required this.method});

  final LoginMethod method;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (ref.watch(authLinkErrorProvider) == null) {
      return const SizedBox.shrink();
    }
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 24),
      child: Semantics(
        liveRegion: true,
        child: Text(
          method == LoginMethod.code
              ? AppLocalizations.of(context).authErrorLink
              : AppLocalizations.of(context).authErrorLinkSignIn,
          key: const ValueKey('login-link-error'),
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.error,
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

class _EmailStep extends ConsumerStatefulWidget {
  const _EmailStep({this.initialEmail});

  final String? initialEmail;

  @override
  ConsumerState<_EmailStep> createState() => _EmailStepState();
}

class _EmailStepState extends ConsumerState<_EmailStep> {
  late final TextEditingController _email = TextEditingController(
    text: _initialText(),
  );

  /// El email del paso anterior (al volver con «Cambia email») o, si no hay,
  /// el que llegó en la ruta, si es válido.
  String _initialText() {
    final previous = ref.read(loginControllerProvider).email;
    if (previous.isNotEmpty) return previous;
    final fromRoute = widget.initialEmail?.trim().toLowerCase() ?? '';
    return isValidEmail(fromRoute) ? fromRoute : '';
  }

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
            errorText: error == null ? null : authErrorText(l10n, error, detail: state.errorDetail),
            errorMaxLines: 6,
          ),
        ),
        const SizedBox(height: 16),
        BusyButton(
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
            errorText: error == null ? null : authErrorText(l10n, error, detail: state.errorDetail),
            errorMaxLines: 6,
          ),
        ),
        const SizedBox(height: 16),
        BusyButton(
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

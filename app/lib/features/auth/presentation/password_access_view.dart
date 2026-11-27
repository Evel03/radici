// Acceso de las clientas con contraseña (/app/ y la app nativa): entrar,
// «Crea account» y «Password dimenticata?», con la confirmación de lo que se
// mandó. Solo muestra el estado de PasswordAccessController y le pasa lo que
// escribe la persona: no llama a Supabase.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:radici/core/link_launcher.dart';
import 'package:radici/core/routes.dart';
import 'package:radici/core/web_links.dart';
import 'package:radici/features/auth/application/password_access_controller.dart';
import 'package:radici/features/auth/domain/auth_models.dart';
import 'package:radici/features/auth/presentation/auth_texts.dart';
import 'package:radici/features/auth/presentation/busy_button.dart';
import 'package:radici/l10n/app_localizations.dart';

class PasswordAccessView extends ConsumerStatefulWidget {
  const PasswordAccessView({super.key, this.initialEmail});

  /// Email ya escrito (`/accedi?email=`, el «Vai al login» de /accesso/).
  final String? initialEmail;

  @override
  ConsumerState<PasswordAccessView> createState() => _PasswordAccessViewState();
}

class _PasswordAccessViewState extends ConsumerState<PasswordAccessView> {
  late final TextEditingController _email = TextEditingController(
    text: _validOrEmpty(widget.initialEmail),
  );
  final TextEditingController _password = TextEditingController();
  bool _obscure = true;

  static String _validOrEmpty(String? email) {
    final value = email?.trim().toLowerCase() ?? '';
    return isValidEmail(value) ? value : '';
  }

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  PasswordAccessController get _controller =>
      ref.read(passwordAccessControllerProvider.notifier);

  String get _locale => Localizations.localeOf(context).languageCode;

  void _show(AccessView view) {
    _password.clear();
    _controller.show(view, email: _email.text);
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(passwordAccessControllerProvider);
    // Al volver de la confirmación (o al cambiar de formulario) el email
    // queda escrito.
    ref.listen(passwordAccessControllerProvider.select((s) => s.email), (
      _,
      email,
    ) {
      if (email.isNotEmpty && _email.text.trim().toLowerCase() != email) {
        _email.text = email;
      }
    });

    if (state.notice != null) return _Sent(state: state, locale: _locale);
    return switch (state.view) {
      AccessView.signIn => _signIn(context, state),
      AccessView.forgot => _forgot(context, state),
    };
  }

  Widget _emailField(
    AppLocalizations l10n,
    PasswordAccessState state, {
    required TextInputAction action,
    required VoidCallback onSubmitted,
    String? errorText,
  }) => TextField(
    key: const ValueKey('access-email'),
    controller: _email,
    enabled: !state.busy,
    keyboardType: TextInputType.emailAddress,
    autofillHints: const [AutofillHints.email, AutofillHints.username],
    autocorrect: false,
    enableSuggestions: false,
    textInputAction: action,
    onSubmitted: (_) => onSubmitted(),
    decoration: InputDecoration(
      labelText: l10n.loginEmailLabel,
      hintText: l10n.loginEmailHint,
      prefixIcon: const Icon(Icons.mail_outline),
      errorText: errorText,
      errorMaxLines: 6,
    ),
  );

  String? _errorText(AppLocalizations l10n, PasswordAccessState state) {
    final error = state.error;
    return error == null
        ? null
        : authErrorText(l10n, error, detail: state.errorDetail);
  }

  Widget _signIn(BuildContext context, PasswordAccessState state) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    void submit() => _controller.signIn(_email.text, _password.text, locale: _locale);
    final error = state.error;
    final emailError = error == AuthFailureKind.invalidEmail;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(l10n.loginPasswordBody, style: theme.textTheme.bodyLarge),
        const SizedBox(height: 24),
        _emailField(
          l10n,
          state,
          action: TextInputAction.next,
          onSubmitted: () => FocusScope.of(context).nextFocus(),
          errorText: emailError ? _errorText(l10n, state) : null,
        ),
        const SizedBox(height: 16),
        TextField(
          key: const ValueKey('access-password'),
          controller: _password,
          enabled: !state.busy,
          obscureText: _obscure,
          autofillHints: const [AutofillHints.password],
          autocorrect: false,
          enableSuggestions: false,
          textInputAction: TextInputAction.done,
          onSubmitted: (_) => submit(),
          decoration: InputDecoration(
            labelText: l10n.loginPasswordLabel,
            prefixIcon: const Icon(Icons.lock_outline),
            suffixIcon: IconButton(
              key: const ValueKey('access-password-toggle'),
              tooltip: _obscure ? l10n.loginPasswordShow : l10n.loginPasswordHide,
              icon: Icon(_obscure ? Icons.visibility_outlined : Icons.visibility_off_outlined),
              onPressed: () => setState(() => _obscure = !_obscure),
            ),
            errorText: emailError ? null : _errorText(l10n, state),
            errorMaxLines: 6,
          ),
        ),
        const SizedBox(height: 16),
        BusyButton(
          key: const ValueKey('access-sign-in'),
          busy: state.busy,
          onPressed: submit,
          label: l10n.loginSignIn,
        ),
        Align(
          alignment: AlignmentDirectional.centerEnd,
          child: TextButton(
            key: const ValueKey('access-forgot'),
            onPressed: state.busy ? null : () => _show(AccessView.forgot),
            child: Text(l10n.loginForgotPassword),
          ),
        ),
        const SizedBox(height: 16),
        const Divider(),
        const SizedBox(height: 16),
        Text(
          l10n.loginNoAccount,
          textAlign: TextAlign.center,
          style: theme.textTheme.bodyMedium,
        ),
        const SizedBox(height: 8),
        OutlinedButton(
          key: const ValueKey('access-go-sign-up'),
          // «Crear cuenta»: los datos, la contraseña y el código, en su pantalla (auth.md §19).
          onPressed: state.busy ? null : () => context.push(AppRoutes.signUp),
          child: Text(l10n.loginCreateAccount),
        ),
        const SizedBox(height: 8),
        _PrivacyNote(locale: _locale),
      ],
    );
  }

  Widget _forgot(BuildContext context, PasswordAccessState state) {
    final l10n = AppLocalizations.of(context);
    void submit() => _controller.requestReset(_email.text, locale: _locale);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Title(l10n.loginForgotPassword),
        const SizedBox(height: 8),
        Text(l10n.forgotBody, style: Theme.of(context).textTheme.bodyLarge),
        const SizedBox(height: 24),
        _emailField(
          l10n,
          state,
          action: TextInputAction.send,
          onSubmitted: submit,
          errorText: _errorText(l10n, state),
        ),
        const SizedBox(height: 16),
        BusyButton(
          key: const ValueKey('access-send-reset'),
          busy: state.busy,
          onPressed: submit,
          label: l10n.forgotSubmit,
        ),
        const SizedBox(height: 8),
        TextButton(
          key: const ValueKey('access-back'),
          onPressed: state.busy ? null : () => _show(AccessView.signIn),
          child: Text(l10n.accessBackToSignIn),
        ),
      ],
    );
  }
}

class _Title extends StatelessWidget {
  const _Title(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Semantics(
    header: true,
    child: Text(text, style: Theme.of(context).textTheme.titleLarge),
  );
}

/// Lo que se mandó (el alta o la recuperación), con el mismo texto exista o
/// no la cuenta, «Reinvia l'email» y la vuelta al acceso.
class _Sent extends ConsumerWidget {
  const _Sent({required this.state, required this.locale});

  final PasswordAccessState state;
  final String locale;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final controller = ref.read(passwordAccessControllerProvider.notifier);
    final error = state.error;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Title(l10n.loginForgotPassword),
        const SizedBox(height: 16),
        Semantics(
          liveRegion: true,
          child: Text(
            l10n.resetSent(state.email),
            key: const ValueKey('access-sent'),
            style: theme.textTheme.bodyLarge,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          l10n.accessSpamHint,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        if (state.resent) ...[
          const SizedBox(height: 12),
          Text(
            l10n.accessResent,
            key: const ValueKey('access-resent'),
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.primary,
            ),
          ),
        ],
        if (error != null) ...[
          const SizedBox(height: 12),
          Semantics(
            liveRegion: true,
            child: Text(
              authErrorText(l10n, error, detail: state.errorDetail),
              key: const ValueKey('access-error'),
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.error,
              ),
            ),
          ),
        ],
        const SizedBox(height: 24),
        FilledButton(
          key: const ValueKey('access-back'),
          onPressed: state.busy
              ? null
              : () => controller.show(AccessView.signIn),
          child: Text(l10n.accessBackToSignIn),
        ),
        const SizedBox(height: 8),
        TextButton(
          key: const ValueKey('access-resend'),
          onPressed: state.busy ? null : () => controller.resend(locale: locale),
          child: Text(l10n.accessResend),
        ),
      ],
    );
  }
}

/// El link a la informativa, debajo de los botones del alta: se ve antes de
/// mandar el email.
class _PrivacyNote extends ConsumerWidget {
  const _PrivacyNote({required this.locale});

  final String locale;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return Column(
      children: [
        Text(
          l10n.loginPrivacyNote,
          textAlign: TextAlign.center,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        TextButton(
          key: const ValueKey('access-privacy'),
          // Directo desde el toque: en la web, el navegador bloquea la
          // pestaña nueva si antes se espera otra cosa.
          onPressed: () => ref
              .read(linkLauncherProvider)
              .launch(privacyPolicyUri(locale)),
          child: Text(l10n.loginPrivacyLink),
        ),
      ],
    );
  }
}

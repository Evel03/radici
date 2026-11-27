// «Crear cuenta» (/crea-account, auth.md §19): los datos, el email y la contraseña (dos veces) en una sola pantalla, y
// después el código de 10 cifras que llega por email, sin salir de la app. Solo muestra el estado de SignUpController
// y le pasa lo que escribe la clienta: no llama a Supabase. Los campos de los datos son los de «Mi cuenta»
// (account_details_fields.dart).
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:radici/core/link_launcher.dart';
import 'package:radici/core/routes.dart';
import 'package:radici/core/web_links.dart';
import 'package:radici/features/auth/application/sign_up_controller.dart';
import 'package:radici/features/auth/domain/password_rules.dart';
import 'package:radici/features/auth/domain/sign_up_form.dart';
import 'package:radici/features/auth/presentation/account_details_fields.dart';
import 'package:radici/features/auth/presentation/auth_texts.dart';
import 'package:radici/features/auth/presentation/busy_button.dart';
import 'package:radici/l10n/app_localizations.dart';

class SignUpScreen extends ConsumerStatefulWidget {
  const SignUpScreen({super.key});

  @override
  ConsumerState<SignUpScreen> createState() => _SignUpScreenState();
}

class _SignUpScreenState extends ConsumerState<SignUpScreen> {
  late final SignUpController _controller;
  final _draft = AccountDetailsDraft();
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _repeat = TextEditingController();
  final _code = TextEditingController();
  bool _obscure = true;
  bool _privacy = false;

  @override
  void initState() {
    super.initState();
    _controller = ref.read(signUpControllerProvider.notifier);
  }

  @override
  void dispose() {
    _draft.dispose();
    for (final controller in [_email, _password, _repeat, _code]) {
      controller.dispose();
    }
    // Al salir de la pantalla se olvida todo (la contraseña incluida), salvo que esté terminando de guardar.
    Future.microtask(_controller.resetUnlessFinishing);
    super.dispose();
  }

  String get _locale => Localizations.localeOf(context).languageCode;

  SignUpForm get _form => _draft.toForm(
    email: _email.text,
    password: _password.text,
    repeat: _repeat.text,
    privacyAccepted: _privacy,
  );

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final state = ref.watch(signUpControllerProvider);
    ref.listen(signUpControllerProvider.select((s) => s.step), (_, step) {
      if (step != SignUpStep.done) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(key: const ValueKey('signup-done'), content: Text(l10n.signUpDone)),
      );
      _controller.reset();
      context.go(AppRoutes.area);
    });

    final body = switch (state.step) {
      SignUpStep.form => _formStep(context, state),
      SignUpStep.code => _codeStep(context, state),
      SignUpStep.finishing || SignUpStep.done => _finishingStep(context, state),
    };
    return Scaffold(
      appBar: AppBar(title: Text(l10n.signUpTitle)),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 520), child: body),
          ),
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // 1. El formulario
  // ---------------------------------------------------------------------------

  Widget _formStep(BuildContext context, SignUpState state) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final problems = state.problems;
    final password = problems[SignUpField.password];
    final enabled = !state.busy;
    void submit() {
      FocusScope.of(context).unfocus();
      _controller.submit(_form, locale: _locale);
    }

    return AutofillGroup(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(l10n.signUpIntro, style: theme.textTheme.bodyLarge),
          AccountPersonalFields(draft: _draft, problems: problems, enabled: enabled),
          AccountSection(l10n.signUpSectionAccount),
          AccountTextField(
            fieldKey: 'signup-email',
            controller: _email,
            label: l10n.loginEmailLabel,
            enabled: enabled,
            error: problems.containsKey(SignUpField.email) ? l10n.authErrorInvalidEmail : null,
            keyboard: TextInputType.emailAddress,
            autofill: const [AutofillHints.email],
          ),
          AccountTextField(
            fieldKey: 'signup-password',
            controller: _password,
            label: l10n.loginPasswordLabel,
            enabled: enabled,
            error: password is PasswordProblem ? passwordProblemText(l10n, password) : null,
            helper: l10n.passwordHint,
            obscure: _obscure,
            autofill: const [AutofillHints.newPassword],
            suffix: IconButton(
              key: const ValueKey('signup-password-toggle'),
              tooltip: _obscure ? l10n.loginPasswordShow : l10n.loginPasswordHide,
              icon: Icon(_obscure ? Icons.visibility_outlined : Icons.visibility_off_outlined),
              onPressed: () => setState(() => _obscure = !_obscure),
            ),
          ),
          AccountTextField(
            fieldKey: 'signup-repeat',
            controller: _repeat,
            label: l10n.signUpRepeat,
            enabled: enabled,
            error: problems.containsKey(SignUpField.repeat) ? l10n.passwordMismatch : null,
            obscure: _obscure,
            autofill: const [AutofillHints.newPassword],
          ),
          AccountExtraFields(draft: _draft, problems: problems, enabled: enabled),
          const SizedBox(height: 16),
          CheckboxListTile(
            key: const ValueKey('signup-privacy'),
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
            value: _privacy,
            onChanged: state.busy ? null : (value) => setState(() => _privacy = value ?? false),
            title: Text(l10n.signUpPrivacy),
            subtitle: problems.containsKey(SignUpField.privacy)
                ? Text(l10n.signUpErrorPrivacy, style: TextStyle(color: theme.colorScheme.error))
                : null,
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              key: const ValueKey('signup-privacy-link'),
              onPressed: () => ref.read(linkLauncherProvider).openPage(privacyPolicyUri(_locale)),
              child: Text(l10n.signUpPrivacyLink),
            ),
          ),
          const SizedBox(height: 16),
          BusyButton(key: const ValueKey('signup-submit'), busy: state.busy, onPressed: submit, label: l10n.signUpSubmit),
          AccountErrorLine(
            problems.isNotEmpty
                ? l10n.signUpErrorFix
                : (state.error != null ? authErrorText(l10n, state.error!, detail: state.errorDetail) : null),
          ),
          const SizedBox(height: 8),
          TextButton(
            key: const ValueKey('signup-have-account'),
            onPressed: state.busy ? null : () => context.canPop() ? context.pop() : context.go(AppRoutes.login),
            child: Text(l10n.signUpHaveAccount),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // 2. El código del email
  // ---------------------------------------------------------------------------

  Widget _codeStep(BuildContext context, SignUpState state) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    void confirm() => _controller.verify(_code.text);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Semantics(header: true, child: Text(l10n.signUpCodeTitle, style: theme.textTheme.headlineSmall)),
        const SizedBox(height: 12),
        Text(l10n.signUpCodeBody(state.email), style: theme.textTheme.bodyLarge),
        const SizedBox(height: 8),
        Text(l10n.signUpCodeExisting, style: theme.textTheme.bodyMedium),
        const SizedBox(height: 20),
        TextField(
          key: const ValueKey('signup-code'),
          controller: _code,
          enabled: !state.busy,
          keyboardType: TextInputType.number,
          autofillHints: const [AutofillHints.oneTimeCode],
          inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(10)],
          textInputAction: TextInputAction.done,
          onSubmitted: (_) => confirm(),
          decoration: InputDecoration(labelText: l10n.loginCodeLabel, hintText: l10n.loginCodeHint),
        ),
        const SizedBox(height: 16),
        BusyButton(key: const ValueKey('signup-code-confirm'), busy: state.busy, onPressed: confirm, label: l10n.signUpCodeConfirm),
        AccountErrorLine(state.error != null ? authErrorText(l10n, state.error!, detail: state.errorDetail) : null),
        if (state.resent) ...[
          const SizedBox(height: 8),
          Text(l10n.loginCodeResent, key: const ValueKey('signup-code-resent')),
        ],
        const SizedBox(height: 8),
        Text(l10n.loginSpamHint, style: theme.textTheme.bodySmall),
        const SizedBox(height: 8),
        TextButton(
          key: const ValueKey('signup-code-resend'),
          onPressed: state.busy ? null : _controller.resend,
          child: Text(l10n.loginResendCode),
        ),
        TextButton(
          key: const ValueKey('signup-edit'),
          onPressed: state.busy ? null : _controller.editForm,
          child: Text(l10n.signUpEditData),
        ),
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // 3. Guardando la contraseña y los datos
  // ---------------------------------------------------------------------------

  Widget _finishingStep(BuildContext context, SignUpState state) {
    final l10n = AppLocalizations.of(context);
    final error = state.error;
    return Column(
      key: const ValueKey('signup-finishing'),
      children: [
        const SizedBox(height: 32),
        if (state.busy || error == null) const CircularProgressIndicator(),
        const SizedBox(height: 16),
        Text(l10n.signUpFinishing, textAlign: TextAlign.center),
        if (!state.busy && error != null) ...[
          AccountErrorLine(authErrorText(l10n, error)),
          const SizedBox(height: 12),
          FilledButton(key: const ValueKey('signup-retry'), onPressed: _controller.retryFinish, child: Text(l10n.actionRetry)),
        ],
      ],
    );
  }
}

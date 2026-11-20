// Traducción automática de un plato en la Edge Function `chef` (contrato
// docs/contracts/chef-api.md §12): POST chef/translate con el nombre y la
// descripción en español devuelve el italiano y el inglés, enteros o nada.
//
// Como las reservas: el SDK manda la sesión de quien entró (Evelyn o un
// colaborador suyo) en `Authorization: Bearer <token>` y la clave publicable
// en `apikey`; la región va en la URL (`?forceFunctionRegion=eu-central-1`,
// Frankfurt), nunca en la cabecera `x-region`, que el preflight de CORS no
// permite (contrato §2).
//
// A Anthropic solo va el nombre y la descripción del plato (SPEC §6). Nada se
// loguea: ni el texto del plato ni el detalle de un error, que se traduce a
// [TranslationFailure] (solo el tipo).
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:radici/core/supabase_client.dart';
import 'package:radici/features/recipes/domain/recipe.dart';
import 'package:radici/features/recipes/domain/recipe_translation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

abstract interface class TranslationRepository {
  /// Traduce [spanish] al italiano y al inglés. La descripción vuelve si y
  /// solo si se mandó. Lanza [TranslationFailure].
  Future<RecipeTranslation> translate(SpanishText spanish);
}

final translationRepositoryProvider = Provider<TranslationRepository>((ref) {
  final client = ref.watch(supabaseClientProvider);
  return client == null
      ? const _NoBackendTranslationRepository()
      : SupabaseTranslationRepository(client);
});

enum TranslationFailureKind {
  /// 503 (el traductor o la base no respondieron), otro 5xx, la función sin
  /// desplegar o una respuesta con otra forma. Se puede reintentar.
  unavailable,

  /// Sin conexión: el pedido no salió. Se puede reintentar.
  offline,

  /// No respondió en [SupabaseTranslationRepository.timeout]. Se puede
  /// reintentar.
  timeout,

  /// 422: Claude no lo tradujo (se negó, la salida no valió o se cortó).
  /// Reintentar lo mismo no sirve: se escribe a mano.
  untranslatable,

  /// 501: la traducción está apagada (sin `ANTHROPIC_API_KEY`). Se escribe a
  /// mano.
  notConfigured,

  /// 429: la cocina pasó su límite de traducciones. La app nunca reintenta
  /// sola (el intento rechazado también cuenta).
  rateLimited,

  /// 401: sin sesión válida (vencida o cerrada).
  unauthorized,

  /// 403: el usuario no es la cocinera ni un colaborador suyo.
  forbidden,

  /// 400 y los otros 4xx: un cuerpo que la app no debería mandar.
  invalid;

  /// Probar de nuevo puede andar: la falla es de la red o del momento.
  bool get canRetry =>
      this == unavailable || this == offline || this == timeout;
}

class TranslationFailure implements Exception {
  const TranslationFailure(this.kind);

  final TranslationFailureKind kind;

  /// Solo el tipo: nunca el texto del plato.
  @override
  String toString() => 'TranslationFailure(${kind.name})';
}

class SupabaseTranslationRepository implements TranslationRepository {
  SupabaseTranslationRepository(
    this._client, {
    this.timeout = translateTimeout,
  });

  final SupabaseClient _client;

  /// Cuánto se espera la respuesta antes de darla por perdida.
  final Duration timeout;

  /// La función y su ruta (functions.invoke arma
  /// `<url>/functions/v1/chef/translate`).
  static const String translateFunction = 'chef/translate';

  /// Frankfurt, como public-request (contrato public-request §2).
  static const String functionRegion = 'eu-central-1';

  /// La función corta a los 40 s (contrato §12); el resto es el margen para
  /// la sesión, el arranque de la función y la red.
  static const Duration translateTimeout = Duration(seconds: 60);

  @override
  Future<RecipeTranslation> translate(SpanishText spanish) async {
    final FunctionResponse response;
    try {
      response = await _client.functions
          .invoke(
            translateFunction,
            body: {'name': spanish.name, 'description': spanish.description},
            // Solo el parámetro: `region:` también mandaría x-region.
            queryParameters: const {'forceFunctionRegion': functionRegion},
          )
          .timeout(timeout);
    } on TimeoutException {
      throw const TranslationFailure(TranslationFailureKind.timeout);
    } on FunctionsFetchException {
      // El pedido no salió: sin red.
      throw const TranslationFailure(TranslationFailureKind.offline);
    } on FunctionsHttpException catch (error) {
      throw translationFailureFromResponse(error.status, error.details);
    } on Object {
      // El relay de la plataforma o el token que no se pudo renovar.
      throw const TranslationFailure(TranslationFailureKind.unavailable);
    }
    try {
      return translationFromResponse(
        response.data,
        withDescription: spanish.description != null,
      );
    } on FormatException {
      throw const TranslationFailure(TranslationFailureKind.unavailable);
    }
  }
}

/// Traduce una respuesta de error de la función (contrato §3 y §12) a
/// [TranslationFailure]. Del cuerpo solo se mira el código.
TranslationFailure translationFailureFromResponse(int status, Object? body) {
  final error = body is Map ? body['error'] : null;
  final kind = switch (status) {
    401 => TranslationFailureKind.unauthorized,
    403 => TranslationFailureKind.forbidden,
    // Sin el código de la función, el 429 es de la plataforma: se puede
    // reintentar.
    429 when error == 'rateLimited' => TranslationFailureKind.rateLimited,
    422 when error == 'untranslatable' => TranslationFailureKind.untranslatable,
    501 when error == 'notConfigured' => TranslationFailureKind.notConfigured,
    // La función sin desplegar (404 de la plataforma) o desplegada antes de
    // /translate (notFound): se puede reintentar más tarde.
    404 || 429 => TranslationFailureKind.unavailable,
    >= 400 && < 500 => TranslationFailureKind.invalid,
    _ => TranslationFailureKind.unavailable,
  };
  return TranslationFailure(kind);
}

/// La respuesta 200: `it` y `en`, cada uno con `name` y `description` (null si
/// y solo si no se mandó, [withDescription]). Todo o nada: con otra forma, un
/// texto vacío o pasado de largo, [FormatException]. Los textos quedan como
/// los guarda la base ([normalizeRecipeText]).
RecipeTranslation translationFromResponse(
  Object? data, {
  required bool withDescription,
}) {
  TranslatedText language(Object? value) {
    if (value is! Map) throw const FormatException('Idioma inválido');
    final name = value['name'];
    final description = value['description'];
    if (name is! String) throw const FormatException('Nombre inválido');
    final cleanName = normalizeRecipeText(name);
    if (cleanName.isEmpty || textLength(cleanName) > maxRecipeNameLength) {
      throw const FormatException('Nombre inválido');
    }
    if (!withDescription) {
      if (description != null) {
        throw const FormatException('Descripción que no se pidió');
      }
      return (name: cleanName, description: null);
    }
    if (description is! String) {
      throw const FormatException('Descripción inválida');
    }
    final cleanDescription = normalizeRecipeText(description);
    if (cleanDescription.isEmpty ||
        textLength(cleanDescription) > maxRecipeDescriptionLength) {
      throw const FormatException('Descripción inválida');
    }
    return (name: cleanName, description: cleanDescription);
  }

  if (data is! Map) throw const FormatException('Respuesta inválida');
  return (it: language(data['it']), en: language(data['en']));
}

class _NoBackendTranslationRepository implements TranslationRepository {
  const _NoBackendTranslationRepository();

  @override
  Future<RecipeTranslation> translate(SpanishText spanish) => Future.error(
    const TranslationFailure(TranslationFailureKind.unavailable),
  );
}

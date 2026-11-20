// Traducción automática de los platos (pedido de Evelyn del 20/11/2026; SPEC
// §4, «Traducción de los platos»; contrato chef-api.md §12). Evelyn escribe
// el nombre y la descripción en español y POST chef/translate devuelve el
// italiano y el inglés. Acá, en Dart puro, la regla de qué se traduce al
// guardar y qué queda si se guarda sin traducir.
//
// La regla, por cada campo de destino (nombre y descripción, en italiano y en
// inglés), con su fuente (el nombre o la descripción en español):
// - se traduce si está vacío, o si sigue automático (`autoTranslated`: lo
//   llenó el traductor y nadie lo tocó) y su español cambió desde la última
//   traducción;
// - lo escrito a mano nunca se pisa;
// - si se borró la descripción en español, las descripciones automáticas se
//   vacían (las escritas a mano quedan);
// - sin el nombre en español no se traduce nada (el traductor lo exige): un
//   plato viejo sin español se guarda como está.
import 'package:radici/features/recipes/domain/recipe.dart';
import 'package:radici/features/recipes/domain/recipe_draft.dart';

/// El español del que salen las traducciones, como lo guarda la base: sin
/// espacios de más (`name` vacío = sin nombre) y la descripción vacía en
/// null. Es el cuerpo de POST chef/translate.
typedef SpanishText = ({String name, String? description});

/// Un idioma de la respuesta del traductor. `description` es null si y solo
/// si no se mandó.
typedef TranslatedText = ({String name, String? description});

/// Lo que devuelve el traductor: los dos idiomas enteros, nunca uno solo.
typedef RecipeTranslation = ({TranslatedText it, TranslatedText en});

/// El texto de [field] en [translation].
String? translatedTextOf(
  RecipeTranslation translation,
  TranslatedField field,
) => switch (field) {
  TranslatedField.nameIt => translation.it.name,
  TranslatedField.descriptionIt => translation.it.description,
  TranslatedField.nameEn => translation.en.name,
  TranslatedField.descriptionEn => translation.en.description,
};

/// El español de [draft] ([SpanishText]).
SpanishText spanishTextOf(RecipeDraft draft) {
  final description = normalizeRecipeText(draft.descriptionEs);
  return (
    name: normalizeRecipeText(draft.nameEs),
    description: description.isEmpty ? null : description,
  );
}

/// Qué pasa con los campos de destino de [draft] al guardar.
final class RecipeTranslationPlan {
  const RecipeTranslationPlan._({
    required this.draft,
    required this.translate,
    required this.clear,
    required this.source,
  });

  /// El formulario del que sale el plan.
  final RecipeDraft draft;

  /// Los campos que hay que traducir: vacíos, o automáticos con su español
  /// cambiado.
  final Set<TranslatedField> translate;

  /// Las descripciones automáticas que se vacían porque se borró la
  /// española. No hace falta el traductor.
  final Set<TranslatedField> clear;

  /// Lo que se manda al traductor: el español de [draft].
  final SpanishText source;

  /// Hay que llamar al traductor antes de guardar.
  bool get needsTranslation => translate.isNotEmpty;

  /// [draft] con la traducción en los campos de [translate] (que quedan
  /// automáticos) y las descripciones de [clear] vacías. Lo demás, como
  /// estaba. Un campo que la respuesta no trae (no debería pasar: la
  /// descripción viene si y solo si se mandó) queda como sin traducir.
  RecipeDraft translated(RecipeTranslation translation) {
    var result = draft;
    final auto = {...draft.autoTranslated};
    for (final field in translate) {
      final text = translatedTextOf(translation, field);
      if (text == null || normalizeRecipeText(text).isEmpty) {
        result = _withoutTranslation(result, auto, field);
      } else {
        result = result.withText(field, text);
        auto.add(field);
      }
    }
    for (final field in clear) {
      result = _withoutTranslation(result, auto, field);
    }
    return result.copyWith(autoTranslated: auto);
  }

  /// [draft] para guardar sin traducir: lo automático que habría que
  /// traducir de nuevo (y las descripciones de [clear]) queda vacío, para no
  /// guardar una traducción vieja como si fuera la del español nuevo; lo
  /// vacío queda vacío, y lo escrito a mano, como estaba. Lo vacío se
  /// traduce la próxima vez que se guarde.
  RecipeDraft get skipped {
    var result = draft;
    final auto = {...draft.autoTranslated};
    for (final field in {...translate, ...clear}) {
      result = _withoutTranslation(result, auto, field);
    }
    return result.copyWith(autoTranslated: auto);
  }

  /// Se puede guardar sin traducir: el nombre en italiano (obligatorio en la
  /// base) no queda vacío.
  bool get canSkip => normalizeRecipeText(skipped.nameIt).isNotEmpty;

  /// Guardar sin traducir deja vacía la descripción en italiano, y sin ella
  /// el plato no sale en la web.
  bool get skipEmptiesItalianDescription =>
      translate.contains(TranslatedField.descriptionIt);
}

/// Si [field] es automático, lo vacía y le saca la marca (de [auto]); si no,
/// lo deja como está.
RecipeDraft _withoutTranslation(
  RecipeDraft draft,
  Set<TranslatedField> auto,
  TranslatedField field,
) {
  if (!auto.remove(field)) return draft;
  return draft.withText(field, '');
}

/// El plan de [draft]. [translatedFrom] es el español del que salen sus
/// campos automáticos: el guardado al abrir el editor, o el de la última
/// traducción.
RecipeTranslationPlan planRecipeTranslation(
  RecipeDraft draft, {
  required SpanishText translatedFrom,
}) {
  final source = spanishTextOf(draft);
  final translate = <TranslatedField>{};
  final clear = <TranslatedField>{};
  for (final field in TranslatedField.values) {
    final from = field.isName ? source.name : source.description ?? '';
    final before = field.isName
        ? translatedFrom.name
        : translatedFrom.description ?? '';
    final auto = draft.autoTranslated.contains(field);
    if (from.isEmpty) {
      // Sin su español: una descripción automática se vacía (un nombre no:
      // sin el nombre en español no se traduce nada).
      if (auto && !field.isName) clear.add(field);
      continue;
    }
    if (source.name.isEmpty) continue;
    final empty = normalizeRecipeText(draft.textOf(field)).isEmpty;
    if (empty || (auto && from != before)) translate.add(field);
  }
  return RecipeTranslationPlan._(
    draft: draft,
    translate: translate,
    clear: clear,
    source: source,
  );
}

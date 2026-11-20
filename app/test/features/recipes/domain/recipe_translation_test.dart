// La regla de qué se traduce al guardar un plato (SPEC §4, «Traducción de
// los platos»), en Dart puro: se traduce lo que está vacío o sigue
// automático cuando cambió el español; lo escrito a mano nunca se pisa; si se
// borra la descripción en español, las descripciones automáticas se vacían.
// Y qué queda si se guarda sin traducir.
import 'package:flutter_test/flutter_test.dart';
import 'package:radici/features/recipes/domain/recipe.dart';
import 'package:radici/features/recipes/domain/recipe_draft.dart';
import 'package:radici/features/recipes/domain/recipe_translation.dart';

import '../../../support/recipe_fixtures.dart';

const String _newId = '0e5b3c1a-2f4d-4a6b-8c9d-0123456789ab';

const SpanishText _nothing = (name: '', description: null);

/// Lo que devolvería el traductor para [spanish] (como TRANSLATE_TRANSPORT=fake).
RecipeTranslation _fake(SpanishText spanish) => (
  it: (name: '[it] ${spanish.name}', description: spanish.description == null ? null : '[it] ${spanish.description}'),
  en: (name: '[en] ${spanish.name}', description: spanish.description == null ? null : '[en] ${spanish.description}'),
);

/// El plan de [draft] como lo arma el editor al abrir [saved] (el español
/// guardado es el de las traducciones automáticas).
RecipeTranslationPlan _planFor(RecipeDraft draft, {Recipe? saved}) => planRecipeTranslation(
  draft,
  translatedFrom: saved == null ? _nothing : spanishTextOf(recipeDraftFrom(saved)),
);

void main() {
  const allFields = {
    TranslatedField.nameIt,
    TranslatedField.descriptionIt,
    TranslatedField.nameEn,
    TranslatedField.descriptionEn,
  };

  test('el español como lo guarda la base: sin espacios de más y la descripción vacía en null', () {
    final draft = emptyRecipeDraft(_newId).copyWith(nameEs: '  Milanesa   a la\tnapolitana ', descriptionEs: '   ');
    expect(spanishTextOf(draft), (name: 'Milanesa a la napolitana', description: null));
  });

  group('un plato nuevo', () {
    test('con el nombre y la descripción en español: se traducen los cuatro', () {
      final draft = emptyRecipeDraft(_newId).copyWith(
        nameEs: 'Milanesa a la napolitana',
        descriptionEs: 'Con salsa de tomate, jamón y mozzarella.',
      );
      final plan = _planFor(draft);
      expect(plan.translate, allFields);
      expect(plan.clear, isEmpty);
      expect(plan.needsTranslation, isTrue);
      expect(plan.source, (name: 'Milanesa a la napolitana', description: 'Con salsa de tomate, jamón y mozzarella.'));

      final translated = plan.translated(_fake(plan.source));
      expect(translated.nameIt, '[it] Milanesa a la napolitana');
      expect(translated.descriptionIt, '[it] Con salsa de tomate, jamón y mozzarella.');
      expect(translated.nameEn, '[en] Milanesa a la napolitana');
      expect(translated.descriptionEn, '[en] Con salsa de tomate, jamón y mozzarella.');
      expect(translated.autoTranslated, allFields);
      expect(translated.nameEs, draft.nameEs, reason: 'el español no se toca');
    });

    test('solo con el nombre: se traducen los nombres, sin descripción', () {
      final plan = _planFor(emptyRecipeDraft(_newId).copyWith(nameEs: 'Locro'));
      expect(plan.translate, {TranslatedField.nameIt, TranslatedField.nameEn});
      expect(plan.source, (name: 'Locro', description: null));
    });

    test('sin español no hay nada que traducir', () {
      final plan = _planFor(emptyRecipeDraft(_newId).copyWith(nameIt: 'Polpette al sugo'));
      expect(plan.needsTranslation, isFalse);
      expect(plan.clear, isEmpty);
    });

    test('lo que ya escribió a mano en italiano o en inglés no se traduce', () {
      final draft = emptyRecipeDraft(_newId).copyWith(
        nameEs: 'Milanesa a la napolitana',
        nameIt: 'Cotoletta alla napoletana',
        descriptionEs: 'Con salsa de tomate.',
        descriptionEn: 'With tomato sauce.',
      );
      final plan = _planFor(draft);
      expect(plan.translate, {TranslatedField.descriptionIt, TranslatedField.nameEn});

      final translated = plan.translated(_fake(plan.source));
      expect(translated.nameIt, 'Cotoletta alla napoletana');
      expect(translated.descriptionEn, 'With tomato sauce.');
      expect(translated.autoTranslated, {TranslatedField.descriptionIt, TranslatedField.nameEn});
    });
  });

  // Decisión del 20/11/2026: un plato guardado sin nombre en español abre con
  // su italiano en el español y el italiano vacío (recipeDraftFrom); si no se
  // traduce, el italiano vuelve al texto de antes (italianMovedToSpanish).
  group('un plato viejo (sin nombre en español)', () {
    final old = pastel();
    RecipeTranslationPlan planOf(RecipeDraft draft) => planRecipeTranslation(
      draft,
      translatedFrom: spanishTextOf(recipeDraftFrom(old)),
      untranslatedFallback: italianMovedToSpanish(old),
    );

    test('se traduce todo lo que quedó vacío, del texto que estaba en italiano', () {
      final plan = planOf(recipeDraftFrom(old));
      expect(plan.translate, allFields);
      expect(plan.request, (name: 'Pastel de papa', description: pastelDescription));
      expect(plan.fillsOnlyEmpty, isTrue);
      final translated = plan.translated(_fake(plan.source));
      expect(translated.nameIt, '[it] Pastel de papa');
      expect(translated.descriptionIt, '[it] $pastelDescription');
      expect(translated.autoTranslated, allFields);
    });

    test('guardar sin traducir vuelve al italiano de antes: se puede sin escribirlo', () {
      final plan = planOf(recipeDraftFrom(old));
      final skipped = plan.skipped;
      expect([skipped.nameIt, skipped.descriptionIt], ['Pastel de papa', pastelDescription]);
      expect([skipped.nameEs, skipped.descriptionEs], ['Pastel de papa', pastelDescription]);
      expect([skipped.nameEn, skipped.descriptionEn], ['', '']);
      expect(skipped.autoTranslated, isEmpty, reason: 'nada lo tradujo');
      expect(plan.canSkip, isTrue);
      expect(plan.skipKeepsItalian, isTrue);
      expect(plan.skipEmptiesItalianDescription, isFalse, reason: 'la descripción italiana vuelve');
    });

    test('lo escrito a mano en italiano queda, y entonces no vuelve nada', () {
      final written = recipeDraftFrom(old).copyWith(nameIt: 'Pasticcio di patate', descriptionIt: 'Carne e purè.');
      final plan = planOf(written);
      expect(plan.translate, {TranslatedField.nameEn, TranslatedField.descriptionEn});
      expect([plan.skipped.nameIt, plan.skipped.descriptionIt], ['Pasticcio di patate', 'Carne e purè.']);
      expect(plan.skipKeepsItalian, isFalse);
    });

    test('una respuesta sin la descripción que se pidió deja la de antes, no vacía', () {
      final plan = planOf(recipeDraftFrom(old));
      final translated = plan.translated((
        it: (name: 'Pasticcio di patate', description: null),
        en: (name: 'Potato pie', description: null),
      ));
      expect(translated.descriptionIt, pastelDescription);
      expect(translated.descriptionEn, isEmpty);
      expect(translated.autoTranslated, {TranslatedField.nameIt, TranslatedField.nameEn});
    });

    test('sin italiano de antes (un plato que no es viejo), guardar sin traducir no inventa nada', () {
      final plan = _planFor(emptyRecipeDraft(_newId).copyWith(nameEs: 'Locro'));
      expect(plan.untranslatedFallback, isEmpty);
      expect(plan.skipKeepsItalian, isFalse);
      expect(plan.skipped.nameIt, isEmpty);
    });
  });

  group('un plato guardado escrito a mano (sin marcas)', () {
    test('un campo vacío se traduce aunque el español no haya cambiado', () {
      // La lasaña no tiene descripción en inglés y sí en español.
      final plan = _planFor(recipeDraftFrom(lasagne()), saved: lasagne());
      expect(plan.translate, {TranslatedField.descriptionEn});
      expect(plan.source, (name: 'Lasaña a la boloñesa', description: lasagneDescriptionEs));
    });

    test('si cambia el español, lo escrito a mano no se vuelve a traducir', () {
      final draft = recipeDraftFrom(lasagne()).copyWith(
        nameEs: 'Lasaña boloñesa',
        descriptionEs: 'Ragú y bechamel.',
        descriptionEn: 'Ragù and béchamel.',
      );
      expect(_planFor(draft, saved: lasagne()).needsTranslation, isFalse);
    });

    test('si se borra la descripción en español, las escritas a mano quedan', () {
      final draft = recipeDraftFrom(lasagne()).copyWith(descriptionEs: '  ');
      final plan = _planFor(draft, saved: lasagne());
      expect(plan.clear, isEmpty);
      expect(plan.needsTranslation, isFalse);
      expect(plan.skipped.descriptionIt, lasagneDescriptionIt);
    });
  });

  group('un plato con campos automáticos (milanesa: el nombre italiano, a mano)', () {
    final saved = milanesa();
    RecipeDraft draft() => recipeDraftFrom(saved);

    test('si el español no cambió, no se traduce nada', () {
      final plan = _planFor(draft(), saved: saved);
      expect(plan.needsTranslation, isFalse);
      expect(plan.clear, isEmpty);
    });

    test('los espacios de más no cuentan como cambio', () {
      final plan = _planFor(draft().copyWith(nameEs: '  Milanesa  a la napolitana '), saved: saved);
      expect(plan.needsTranslation, isFalse);
    });

    test('cambió el nombre en español: se traduce el nombre automático, no el escrito a mano', () {
      final plan = _planFor(draft().copyWith(nameEs: 'Milanesa napolitana'), saved: saved);
      expect(plan.translate, {TranslatedField.nameEn});
      // Sin descripción que traducir, a Anthropic no va la descripción.
      expect(plan.request, (name: 'Milanesa napolitana', description: null));

      final translated = plan.translated(_fake(plan.source));
      expect(translated.nameEn, '[en] Milanesa napolitana');
      expect(translated.nameIt, 'Cotoletta alla napoletana');
      expect(translated.descriptionIt, saved.descriptionIt, reason: 'la descripción no cambió: no se toca');
      expect(translated.autoTranslated, saved.autoTranslated);
    });

    test('cambió la descripción en español: se traducen las dos descripciones automáticas', () {
      final plan = _planFor(draft().copyWith(descriptionEs: 'Con tomate y queso.'), saved: saved);
      expect(plan.translate, {TranslatedField.descriptionIt, TranslatedField.descriptionEn});
      expect(plan.source, (name: 'Milanesa a la napolitana', description: 'Con tomate y queso.'));
      expect(plan.request, plan.source);
      final translated = plan.translated(_fake(plan.source));
      expect(translated.descriptionIt, '[it] Con tomate y queso.');
      expect(translated.nameEn, saved.nameEn);
    });

    test('cambiaron los dos: los tres automáticos', () {
      final plan = _planFor(draft().copyWith(nameEs: 'Napolitana', descriptionEs: 'Con tomate.'), saved: saved);
      expect(plan.translate, {TranslatedField.descriptionIt, TranslatedField.nameEn, TranslatedField.descriptionEn});
    });

    test('un campo corregido a mano (sin la marca) no se traduce aunque cambie el español', () {
      final corrected = draft().copyWith(
        descriptionIt: 'Pomodoro, prosciutto e mozzarella.',
        autoTranslated: {TranslatedField.nameEn, TranslatedField.descriptionEn},
        descriptionEs: 'Con tomate y queso.',
      );
      expect(_planFor(corrected, saved: saved).translate, {TranslatedField.descriptionEn});
    });

    test('un campo vaciado se traduce aunque el español no haya cambiado', () {
      final emptied = draft().copyWith(nameIt: ' ', autoTranslated: saved.autoTranslated);
      expect(_planFor(emptied, saved: saved).translate, {TranslatedField.nameIt});
    });

    test('se borró la descripción en español: las automáticas se vacían sin traducir, las escritas a mano quedan', () {
      final handWrittenEnglish = draft().copyWith(
        descriptionEs: '',
        descriptionEn: 'Tomato, ham and mozzarella.',
        autoTranslated: {TranslatedField.descriptionIt, TranslatedField.nameEn},
      );
      final plan = _planFor(handWrittenEnglish, saved: saved);
      expect(plan.needsTranslation, isFalse);
      expect(plan.clear, {TranslatedField.descriptionIt});

      for (final result in [plan.skipped, plan.translated(_fake(plan.source))]) {
        expect(result.descriptionIt, isEmpty);
        expect(result.descriptionEn, 'Tomato, ham and mozzarella.');
        expect(result.autoTranslated, {TranslatedField.nameEn});
      }
    });

    test('después de traducir, el plan con el español nuevo ya no tiene nada', () {
      final changed = draft().copyWith(descriptionEs: 'Con tomate y queso.');
      final plan = _planFor(changed, saved: saved);
      final translated = plan.translated(_fake(plan.source));
      expect(planRecipeTranslation(translated, translatedFrom: plan.source).needsTranslation, isFalse);
    });
  });

  group('guardar sin traducir', () {
    test('los automáticos viejos se vacían, los vacíos quedan vacíos y lo escrito a mano queda', () {
      final changed = recipeDraftFrom(milanesa()).copyWith(nameEs: 'Napolitana', descriptionEs: 'Con tomate.');
      final plan = _planFor(changed, saved: milanesa());
      final skipped = plan.skipped;
      expect(skipped.nameIt, 'Cotoletta alla napoletana');
      expect([skipped.descriptionIt, skipped.nameEn, skipped.descriptionEn], ['', '', '']);
      expect(skipped.autoTranslated, isEmpty);
      expect([skipped.nameEs, skipped.descriptionEs], ['Napolitana', 'Con tomate.'], reason: 'el español queda');
      expect(plan.canSkip, isTrue);
      expect(plan.skipEmptiesItalianDescription, isTrue);
    });

    test('un plato nuevo sin el nombre en italiano no se puede guardar sin traducir', () {
      final plan = _planFor(emptyRecipeDraft(_newId).copyWith(nameEs: 'Locro'));
      expect(plan.canSkip, isFalse);
      expect(plan.skipEmptiesItalianDescription, isFalse);

      final withItalian = emptyRecipeDraft(_newId).copyWith(nameEs: 'Locro', nameIt: 'Locro');
      final skipPlan = _planFor(withItalian);
      expect(skipPlan.canSkip, isTrue);
      expect(skipPlan.skipped.nameEn, isEmpty);
    });

    test('un nombre en italiano automático y viejo tampoco: hay que escribirlo', () {
      final auto = milanesa().copyWith(autoTranslated: {...milanesa().autoTranslated, TranslatedField.nameIt});
      final plan = _planFor(recipeDraftFrom(auto).copyWith(nameEs: 'Napolitana'), saved: auto);
      expect(plan.translate, {TranslatedField.nameIt, TranslatedField.nameEn});
      expect(plan.canSkip, isFalse);
    });

    test('si todo lo que hay que traducir está vacío, guardar sin traducir no vacía nada automático', () {
      expect(_planFor(recipeDraftFrom(lasagne()), saved: lasagne()).fillsOnlyEmpty, isTrue);
      expect(_planFor(emptyRecipeDraft(_newId).copyWith(nameEs: 'Locro')).fillsOnlyEmpty, isTrue);
      final stale = recipeDraftFrom(milanesa()).copyWith(nameEs: 'Napolitana');
      expect(_planFor(stale, saved: milanesa()).fillsOnlyEmpty, isFalse);
      expect(_planFor(recipeDraftFrom(milanesa()), saved: milanesa()).fillsOnlyEmpty, isTrue, reason: 'nada que traducir');
    });

    test('avisa que el plato sale de la web solo si había descripción en italiano y queda vacía', () {
      // Nuevo, con la descripción en español: la italiana ya estaba vacía.
      final fresh = _planFor(
        emptyRecipeDraft(_newId).copyWith(nameEs: 'Locro', nameIt: 'Locro', descriptionEs: 'Con zapallo.'),
      );
      expect(fresh.translate, contains(TranslatedField.descriptionIt));
      expect(fresh.skipEmptiesItalianDescription, isFalse);
      // La italiana automática y vieja: se vacía.
      final stale = _planFor(recipeDraftFrom(milanesa()).copyWith(descriptionEs: 'Con tomate.'), saved: milanesa());
      expect(stale.skipEmptiesItalianDescription, isTrue);
      // Escrita a mano: queda.
      final handWritten = _planFor(
        recipeDraftFrom(milanesa()).copyWith(
          descriptionEs: 'Con tomate.',
          descriptionIt: 'Pomodoro e mozzarella.',
          autoTranslated: {TranslatedField.nameEn, TranslatedField.descriptionEn},
        ),
        saved: milanesa(),
      );
      expect(handWritten.skipEmptiesItalianDescription, isFalse);
      // Se borró la española (clear) y hay que traducir el nombre: también.
      final cleared = _planFor(
        recipeDraftFrom(milanesa()).copyWith(descriptionEs: '', nameEs: 'Napolitana'),
        saved: milanesa(),
      );
      expect(cleared.clear, contains(TranslatedField.descriptionIt));
      expect(cleared.skipEmptiesItalianDescription, isTrue);
    });

    test('sin nada que traducir, guardar sin traducir no cambia el formulario', () {
      final plan = _planFor(recipeDraftFrom(milanesa()), saved: milanesa());
      expect(plan.skipped, recipeDraftFrom(milanesa()));
      expect(plan.canSkip, isTrue);
    });
  });

  test('una respuesta sin la descripción que se pidió no deja la vieja como si fuera nueva', () {
    final changed = recipeDraftFrom(milanesa()).copyWith(descriptionEs: 'Con tomate.');
    final plan = _planFor(changed, saved: milanesa());
    final translated = plan.translated((
      it: (name: 'Cotoletta', description: null),
      en: (name: 'Milanese', description: null),
    ));
    expect([translated.descriptionIt, translated.descriptionEn], ['', '']);
    expect(translated.autoTranslated, {TranslatedField.nameEn});
  });
}

// El menú que eligió el cliente en la web, en Dart puro: la fila de recipes
// con los nombres, el nombre en el idioma de la app con el italiano de
// respaldo y los platos en el orden elegido, con los borrados en su lugar.
import 'package:flutter_test/flutter_test.dart';
import 'package:radici/features/requests/domain/chosen_menu.dart';

import '../../../support/recipe_fixtures.dart';

void main() {
  const lasagne = MenuDish(
    id: lasagneId,
    nameIt: 'Lasagne alla bolognese',
    nameEs: 'Lasaña a la boloñesa',
    nameEn: 'Lasagne Bolognese',
  );
  const minestrone = MenuDish(
    id: minestroneId,
    nameIt: 'Minestrone di verdure',
    nameEs: 'Minestrone de verduras',
  );

  group('MenuDish.fromJson', () {
    test(
      'lee los tres nombres; una traducción vacía o ausente queda en null',
      () {
        expect(
          MenuDish.fromJson(const {
            'id': lasagneId,
            'name_it': 'Lasagne alla bolognese',
            'name_es': 'Lasaña a la boloñesa',
            'name_en': 'Lasagne Bolognese',
          }),
          lasagne,
        );
        expect(
          MenuDish.fromJson(const {
            'id': minestroneId,
            'name_it': 'Minestrone di verdure',
            'name_es': 'Minestrone de verduras',
            'name_en': '',
          }),
          minestrone,
        );
        expect(
          MenuDish.fromJson(const {'id': risottoId, 'name_it': 'Risotto'})
              .nameEs,
          isNull,
        );
      },
    );

    test('la foto del plato: photo_id o null (sin foto)', () {
      const photoId = 'f0000000-0000-4000-8000-000000000001';
      expect(
        MenuDish.fromJson(const {
          'id': risottoId,
          'name_it': 'Risotto',
          'photo_id': photoId,
        }).photoId,
        photoId,
      );
      expect(
        MenuDish.fromJson(const {
          'id': risottoId,
          'name_it': 'Risotto',
          'photo_id': null,
        }).photoId,
        isNull,
      );
    });

    for (final (label, row) in [
      ('sin id', const {'id': '', 'name_it': 'Risotto'}),
      ('sin nombre en italiano', const {'id': risottoId, 'name_it': null}),
      (
        'una traducción que no es texto',
        const {'id': risottoId, 'name_it': 'Risotto', 'name_es': 3},
      ),
      (
        'una foto que no es un uuid',
        const {'id': risottoId, 'name_it': 'Risotto', 'photo_id': '../x'},
      ),
    ]) {
      test('fila rota ($label): FormatException', () {
        expect(() => MenuDish.fromJson(row), throwsFormatException);
      });
    }
  });

  test(
    'el nombre en el idioma de la app, con el italiano si falta la traducción',
    () {
      expect(lasagne.name('it'), 'Lasagne alla bolognese');
      expect(lasagne.name('es'), 'Lasaña a la boloñesa');
      expect(lasagne.name('en'), 'Lasagne Bolognese');
      expect(minestrone.name('en'), 'Minestrone di verdure');
      expect(minestrone.name('fr'), 'Minestrone di verdure');
    },
  );

  test(
    'chosenDishes: en el orden elegido, y el que ya no existe en su lugar',
    () {
      expect(
        chosenDishes(
          const [minestroneId, risottoId, lasagneId],
          const [lasagne, minestrone],
        ),
        const [
          (id: minestroneId, dish: minestrone),
          (id: risottoId, dish: null),
          (id: lasagneId, dish: lasagne),
        ],
      );
      expect(chosenDishes(const [], const [lasagne]), isEmpty);
    },
  );

  test(
    'menuDishColumns: solo los nombres y la foto (nunca ingredientes ni notas)',
    () {
      expect(menuDishColumns, 'id, name_it, name_es, name_en, photo_id');
    },
  );
}

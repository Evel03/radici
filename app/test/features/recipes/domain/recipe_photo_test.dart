// La foto de un plato antes de subirla: derecha según el EXIF, de 1200 y 360
// px de lado mayor, sin metadatos (ni EXIF ni GPS) y siempre debajo de 2 MiB.
// Las fotos de prueba se arman acá con el paquete image.
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:radici/features/recipes/domain/recipe_photo.dart';

/// Rojo arriba a la izquierda, verde arriba a la derecha y azul abajo.
img.Image _quadrants(int width, int height, {int channels = 3}) {
  final image = img.Image(width: width, height: height, numChannels: channels);
  for (final p in image) {
    final top = p.y < height / 2;
    final left = p.x < width / 2;
    p
      ..r = top && left ? 255 : 0
      ..g = top && !left ? 255 : 0
      ..b = top ? 0 : 255;
    if (channels == 4) p.a = 255;
  }
  return image;
}

/// Un JPEG como los del teléfono: orientación 6 (hay que girarlo 90° a la
/// derecha para verlo bien), marca, modelo y la posición GPS.
Uint8List _phoneJpeg(int width, int height) {
  final image = _quadrants(width, height);
  image.exif.imageIfd
    ..orientation = 6
    ..make = 'Apple'
    ..model = 'iPhone 15';
  image.exif.gpsIfd
    ..gpsLatitudeRef = 'N'
    ..gpsLatitude = 45.6983
    ..gpsLongitudeRef = 'E'
    ..gpsLongitude = 9.6773;
  return img.encodeJpg(image, quality: 92);
}

/// Los marcadores de los segmentos de un JPEG, hasta el comienzo de los datos
/// (SOS).
List<int> _segmentMarkers(Uint8List jpeg) {
  expect(jpeg.sublist(0, 2), [0xff, 0xd8], reason: 'empieza con SOI');
  final markers = <int>[];
  var offset = 2;
  while (offset + 4 <= jpeg.length) {
    expect(jpeg[offset], 0xff, reason: 'un marcador en $offset');
    final marker = jpeg[offset + 1];
    markers.add(marker);
    if (marker == 0xda) break;
    final length = (jpeg[offset + 2] << 8) | jpeg[offset + 3];
    offset += 2 + length;
  }
  return markers;
}

bool _containsAscii(Uint8List bytes, String text) {
  final pattern = text.codeUnits;
  outer:
  for (var i = 0; i + pattern.length <= bytes.length; i++) {
    for (var j = 0; j < pattern.length; j++) {
      if (bytes[i + j] != pattern[j]) continue outer;
    }
    return true;
  }
  return false;
}

/// Sin APP1 a APP15 (EXIF, XMP, perfil de color, IPTC…) ni comentarios: solo
/// el encabezado JFIF, las tablas y la imagen.
void _expectNoMetadata(Uint8List jpeg) {
  final markers = _segmentMarkers(jpeg);
  for (final marker in markers) {
    expect(
      [0xe0, 0xdb, 0xc0, 0xc4, 0xdd, 0xda],
      contains(marker),
      reason: 'segmento 0x${marker.toRadixString(16)} de más',
    );
  }
  expect(_containsAscii(jpeg, 'Exif'), isFalse);
  expect(_containsAscii(jpeg, 'Apple'), isFalse);
  final decoded = img.decodeJpg(jpeg)!;
  expect(decoded.exif.isEmpty, isTrue);
  expect(decoded.iccProfile, isNull);
}

int _longSide(img.Image image) => max(image.width, image.height);

void main() {
  group('processRecipePhoto', () {
    test('una foto del teléfono con EXIF y GPS: sale derecha, de 1200 y 360 px y sin metadatos', () {
      final input = _phoneJpeg(1600, 1000);
      // La foto de prueba tiene de verdad lo que hay que sacar.
      final original = img.decodeJpg(input)!;
      expect(original.exif.gpsIfd.gpsLatitude, closeTo(45.6983, 0.001));
      expect(_containsAscii(input, 'Apple'), isTrue);
      // El decodificador aplica la orientación 6 (y la saca del EXIF): los
      // píxeles guardados son apaisados.
      expect([original.width, original.height], [1000, 1600]);

      final photo = processRecipePhoto(input);

      for (final jpeg in [photo.full, photo.thumb]) {
        _expectNoMetadata(jpeg);
        expect(jpeg.lengthInBytes, lessThanOrEqualTo(recipePhotoMaxBytes));
      }
      final full = img.decodeJpg(photo.full)!;
      final thumb = img.decodeJpg(photo.thumb)!;
      // Girada: era apaisada (1600×1000) y se ve vertical.
      expect([full.width, full.height], [750, 1200]);
      expect([thumb.width, thumb.height], [225, 360]);

      // Girada a la derecha: el rojo (arriba a la izquierda) queda arriba a la
      // derecha, el verde abajo a la derecha y el azul a la izquierda.
      for (final image in [full, thumb]) {
        final w = image.width;
        final h = image.height;
        final topRight = image.getPixel(w * 3 ~/ 4, h ~/ 4);
        final bottomRight = image.getPixel(w * 3 ~/ 4, h * 3 ~/ 4);
        final left = image.getPixel(w ~/ 4, h ~/ 2);
        expect([topRight.r, topRight.g, topRight.b].map((c) => c > 200), [
          true,
          false,
          false,
        ]);
        expect(
          [bottomRight.r, bottomRight.g, bottomRight.b].map((c) => c > 200),
          [false, true, false],
        );
        expect([left.r, left.g, left.b].map((c) => c > 200), [
          false,
          false,
          true,
        ]);
      }
    });

    test('una foto grande que el selector no achicó: la decodifica achicada y sale igual de 1200', () {
      final photo = processRecipePhoto(_phoneJpeg(2600, 1700));
      final full = img.decodeJpg(photo.full)!;
      final thumb = img.decodeJpg(photo.thumb)!;
      expect(_longSide(full), recipePhotoMaxSide);
      expect(full.height, recipePhotoMaxSide, reason: 'derecha: vertical');
      expect(full.width, closeTo(1700 * 1200 / 2600, 1));
      expect(_longSide(thumb), recipePhotoThumbMaxSide);
      _expectNoMetadata(photo.full);
      _expectNoMetadata(photo.thumb);
    });

    test('una foto chica no se agranda', () {
      final photo = processRecipePhoto(img.encodePng(_quadrants(300, 200)));
      final full = img.decodeJpg(photo.full)!;
      final thumb = img.decodeJpg(photo.thumb)!;
      expect([full.width, full.height], [300, 200]);
      expect([thumb.width, thumb.height], [300, 200]);
    });

    test('PNG con transparencia: el fondo queda blanco, en JPEG', () {
      final image = img.Image(width: 400, height: 400, numChannels: 4);
      for (final p in image) {
        final inside = p.x >= 100 && p.x < 300 && p.y >= 100 && p.y < 300;
        p
          ..r = 200
          ..g = 0
          ..b = 0
          ..a = inside ? 255 : 0;
      }
      final photo = processRecipePhoto(img.encodePng(image));
      expect(photo.full.sublist(0, 3), [0xff, 0xd8, 0xff]);
      final full = img.decodeJpg(photo.full)!;
      final corner = full.getPixel(10, 10);
      expect([corner.r, corner.g, corner.b], everyElement(greaterThan(245)));
      final center = full.getPixel(200, 200);
      expect(center.r, greaterThan(150));
      expect(center.g, lessThan(60));
      _expectNoMetadata(photo.full);
    });

    test('GIF y WebP también (la primera imagen), en JPEG', () {
      final source = _quadrants(500, 250);
      for (final bytes in [img.encodeGif(source), img.encodeWebP(source)]) {
        final photo = processRecipePhoto(bytes);
        final full = img.decodeJpg(photo.full)!;
        expect([full.width, full.height], [500, 250]);
        final thumb = img.decodeJpg(photo.thumb)!;
        expect([thumb.width, thumb.height], [360, 180]);
      }
    });

    test(
      'ruido puro de 1200×1200 (lo peor para JPEG): igual entra en 2 MiB',
      () {
        final random = Random(7);
        final noise = img.Image(width: 1200, height: 1200);
        for (final p in noise) {
          p
            ..r = random.nextInt(256)
            ..g = random.nextInt(256)
            ..b = random.nextInt(256);
        }
        final photo = processRecipePhoto(img.encodePng(noise));
        expect(
          photo.full.lengthInBytes,
          lessThanOrEqualTo(recipePhotoMaxBytes),
        );
        expect(
          photo.thumb.lengthInBytes,
          lessThanOrEqualTo(recipePhotoMaxBytes),
        );
        expect(_longSide(img.decodeJpg(photo.full)!), recipePhotoMaxSide);
      },
    );

    test('lo que no es una foto que la app abra (HEIC sin convertir, un archivo roto) → RecipePhotoFormatException', () {
      final heic = Uint8List.fromList([
        0,
        0,
        0,
        24,
        ...'ftypheic'.codeUnits,
        0,
        0,
        0,
        0,
      ]);
      final truncated = _phoneJpeg(200, 100).sublist(0, 300);
      for (final bytes in [
        Uint8List(0),
        Uint8List.fromList([1, 2, 3]),
        heic,
        truncated,
      ]) {
        expect(
          () => processRecipePhoto(bytes),
          throwsA(isA<RecipePhotoFormatException>()),
          reason: '${bytes.length} bytes',
        );
      }
    });
  });

  test(
    'recipePhotoPath: carpeta de la cocina y del plato, uuids en minúsculas',
    () {
      expect(
        recipePhotoPath(
          chefId: 'C0000000-0000-4000-8000-00000000000A',
          recipeId: 'a0000000-0000-4000-8000-000000000001',
          photoId: 'F0000000-0000-4000-8000-00000000000B',
        ),
        'c0000000-0000-4000-8000-00000000000a/a0000000-0000-4000-8000-000000000001/'
        'f0000000-0000-4000-8000-00000000000b.jpg',
      );
      expect(
        recipePhotoPath(chefId: 'c', recipeId: 'r', photoId: 'p', thumb: true),
        'c/r/p-thumb.jpg',
      );
    },
  );

  test('NewRecipePhoto y RecipePhotoChange: iguales por la elección, sin comparar bytes', () {
    final bytes = ProcessedRecipePhoto(full: Uint8List(3), thumb: Uint8List(1));
    final other = ProcessedRecipePhoto(full: Uint8List(9), thumb: Uint8List(9));
    expect(
      NewRecipePhoto(photoId: 'p1', photo: bytes),
      NewRecipePhoto(photoId: 'p1', photo: other),
    );
    expect(
      NewRecipePhoto(photoId: 'p1', photo: bytes),
      isNot(NewRecipePhoto(photoId: 'p2', photo: bytes)),
    );
    expect(
      ReplaceRecipePhoto(NewRecipePhoto(photoId: 'p1', photo: bytes)),
      ReplaceRecipePhoto(NewRecipePhoto(photoId: 'p1', photo: other)),
    );
    expect(const RemoveRecipePhoto(), const RemoveRecipePhoto());
    expect(
      const RemoveRecipePhoto(),
      isNot(ReplaceRecipePhoto(NewRecipePhoto(photoId: 'p1', photo: bytes))),
    );
    // toString sin los bytes (nunca se loguea el contenido).
    expect(bytes.toString(), 'ProcessedRecipePhoto(3 B, 1 B)');
  });
}

// La foto de un plato antes de subirla: derecha según el EXIF, de 1200 px de
// lado mayor y la miniatura de 320 de lado menor, sin metadatos (ni EXIF, GPS,
// XMP, IPTC, comentarios ni nada después del final) salvo el perfil de color,
// y siempre debajo de 2 MiB. Las fotos de prueba se arman acá con el paquete
// image y, los segmentos raros, a mano.
import 'dart:convert';
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

/// Un perfil ICC de prueba de [length] bytes: el largo en el encabezado,
/// «acsp» en los bytes 36 a 39 y el resto, un patrón reconocible.
Uint8List _iccProfile(int length) {
  final profile = Uint8List(length);
  for (var i = 0; i < length; i++) {
    profile[i] = (i * 7) & 0xff;
  }
  profile.setAll(0, [
    length >> 24,
    (length >> 16) & 0xff,
    (length >> 8) & 0xff,
    length & 0xff,
  ]);
  profile.setAll(36, 'acsp'.codeUnits);
  profile.setAll(48, 'Display P3'.codeUnits);
  return profile;
}

/// Un segmento JPEG: marcador y largo (que incluye los dos bytes del largo).
List<int> _segment(int marker, List<int> data) => [
  0xff,
  marker,
  (data.length + 2) >> 8,
  (data.length + 2) & 0xff,
  ...data,
];

List<int> _iccSegment(List<int> chunk, int sequence, int count) =>
    _segment(0xe2, [...'ICC_PROFILE'.codeUnits, 0, sequence, count, ...chunk]);

/// [jpeg] con [segments] metidos después del APP0 y [trailer] después del
/// final (EOI).
Uint8List _withSegments(
  Uint8List jpeg,
  List<List<int>> segments, {
  List<int> trailer = const [],
}) {
  expect(jpeg.sublist(2, 4), [
    0xff,
    0xe0,
  ], reason: 'el paquete escribe APP0 primero');
  final app0End = 4 + ((jpeg[4] << 8) | jpeg[5]);
  return Uint8List.fromList([
    ...jpeg.sublist(0, app0End),
    for (final segment in segments) ...segment,
    ...jpeg.sublist(app0End),
    ...trailer,
  ]);
}

/// Los segmentos de un JPEG (marcador y datos), hasta el comienzo de los datos
/// de la imagen (SOS).
List<(int, Uint8List)> _segments(Uint8List jpeg) {
  expect(jpeg.sublist(0, 2), [0xff, 0xd8], reason: 'empieza con SOI');
  final segments = <(int, Uint8List)>[];
  var offset = 2;
  while (offset + 4 <= jpeg.length) {
    expect(jpeg[offset], 0xff, reason: 'un marcador en $offset');
    final marker = jpeg[offset + 1];
    final length = (jpeg[offset + 2] << 8) | jpeg[offset + 3];
    segments.add((
      marker,
      Uint8List.sublistView(jpeg, offset + 4, offset + 2 + length),
    ));
    if (marker == 0xda) break;
    offset += 2 + length;
  }
  return segments;
}

/// El perfil de color de los segmentos APP2 de [jpeg], unidos en orden (null si
/// no tiene).
Uint8List? _iccOf(Uint8List jpeg) {
  final chunks = [
    for (final (marker, data) in _segments(jpeg))
      if (marker == 0xe2) data,
  ];
  if (chunks.isEmpty) return null;
  for (final (index, chunk) in chunks.indexed) {
    expect(latin1.decode(chunk.sublist(0, 11)), 'ICC_PROFILE');
    expect(chunk.sublist(11, 14), [
      0,
      index + 1,
      chunks.length,
    ], reason: 'firma, número y total');
  }
  return Uint8List.fromList([for (final chunk in chunks) ...chunk.sublist(14)]);
}

bool _containsAscii(Uint8List bytes, String text) =>
    latin1.decode(bytes).contains(text);

/// Solo los segmentos permitidos: el encabezado JFIF (APP0), el perfil de color
/// (APP2), las tablas, el encabezado de la imagen y los datos; nada después del
/// final.
void _expectOnlyAllowedSegments(Uint8List jpeg) {
  final markers = [for (final (marker, _) in _segments(jpeg)) marker];
  for (final marker in markers) {
    expect(
      [0xe0, 0xe2, 0xdb, 0xc0, 0xc4, 0xdd, 0xda],
      contains(marker),
      reason: 'segmento 0x${marker.toRadixString(16)} de más',
    );
  }
  expect(markers.first, 0xe0);
  expect(latin1.decode(_segments(jpeg).first.$2.sublist(0, 5)), 'JFIF\u0000');
  expect(jpeg.sublist(jpeg.length - 2), [
    0xff,
    0xd9,
  ], reason: 'termina en EOI, sin nada después');
  final decoded = img.decodeJpg(jpeg)!;
  expect(decoded.exif.isEmpty, isTrue);
}

int _longSide(img.Image image) => max(image.width, image.height);
int _shortSide(img.Image image) => min(image.width, image.height);

void main() {
  group('processRecipePhoto', () {
    test('una foto del teléfono con EXIF y GPS: sale derecha, de 1200 px y la miniatura de 320 de lado menor', () {
      final input = _phoneJpeg(1600, 1000);
      // La foto de prueba tiene de verdad lo que hay que sacar.
      final original = img.decodeJpg(input)!;
      expect(original.exif.gpsIfd.gpsLatitude, closeTo(45.6983, 0.001));
      // El decodificador aplica la orientación 6 (y la saca del EXIF): los
      // píxeles guardados son apaisados.
      expect([original.width, original.height], [1000, 1600]);

      final photo = processRecipePhoto(input);

      for (final jpeg in [photo.full, photo.thumb]) {
        _expectOnlyAllowedSegments(jpeg);
        expect(_iccOf(jpeg), isNull, reason: 'la original no tenía perfil');
        expect(jpeg.lengthInBytes, lessThanOrEqualTo(recipePhotoMaxBytes));
      }
      final full = img.decodeJpg(photo.full)!;
      final thumb = img.decodeJpg(photo.thumb)!;
      // Girada: era apaisada (1600×1000) y se ve vertical.
      expect([full.width, full.height], [750, 1200]);
      expect([thumb.width, thumb.height], [320, 512]);

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

    // Lo que trae un JPEG de verdad, metido a mano: además del EXIF con el GPS,
    // XMP (APP1), IPTC (APP13), otro APP (APP12), un comentario y datos
    // después del final. Sale solo el perfil de color.
    test('sin EXIF, GPS, XMP, IPTC, comentarios, otros segmentos ni datos después del final; el perfil de color queda igual', () {
      final icc = _iccProfile(560);
      const xmp =
          '<x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:Description exif:GPSLatitude="45,41.9N" '
          'tiff:Make="Apple"/></x:xmpmeta>';
      final input = _withSegments(_phoneJpeg(800, 600), [
        _segment(0xe1, [
          ...'http://ns.adobe.com/xap/1.0/'.codeUnits,
          0,
          ...utf8.encode(xmp),
        ]),
        _segment(0xed, [
          ...'Photoshop 3.0'.codeUnits,
          0,
          ...'8BIM'.codeUnits,
          4,
          4,
          0,
          0,
          ...'Bergamo'.codeUnits,
        ]),
        _segment(0xec, [...'Ducky'.codeUnits, 0, 1, 2, 3]),
        _iccSegment(icc, 1, 1),
        _segment(0xfe, utf8.encode('Scattata in via XX Settembre')),
      ], trailer: utf8.encode('DOPO-EOI 45.6983 9.6773'));
      // La entrada tiene todo eso (y se puede abrir).
      expect(img.decodeJpg(input), isNotNull);
      for (final text in [
        'Exif',
        'xap/1.0',
        'Photoshop',
        '8BIM',
        'Ducky',
        'XX Settembre',
        'DOPO-EOI',
      ]) {
        expect(_containsAscii(input, text), isTrue, reason: text);
      }

      final photo = processRecipePhoto(input);

      for (final jpeg in [photo.full, photo.thumb]) {
        _expectOnlyAllowedSegments(jpeg);
        expect(
          _iccOf(jpeg),
          icc,
          reason: 'el perfil de color, igual byte a byte',
        );
        for (final text in [
          'Exif',
          'xap/1.0',
          'GPSLatitude',
          'Photoshop',
          '8BIM',
          'Ducky',
          'XX Settembre',
          'DOPO-EOI',
          'iPhone',
        ]) {
          expect(_containsAscii(jpeg, text), isFalse, reason: text);
        }
      }
    });

    test(
      'un perfil de color partido en dos segmentos se rearma y sale en dos',
      () {
        final icc = _iccProfile(70000);
        const split = 40000;
        final input = _withSegments(img.encodeJpg(_quadrants(400, 300)), [
          // En cualquier orden: vale el número de cada segmento.
          _iccSegment(icc.sublist(split), 2, 2),
          _iccSegment(icc.sublist(0, split), 1, 2),
        ]);

        final photo = processRecipePhoto(input);

        expect(_iccOf(photo.full), icc);
        expect(
          [for (final (marker, _) in _segments(photo.full)) marker]
              .where((m) => m == 0xe2),
          hasLength(2),
        );
        expect(img.decodeJpg(photo.full), isNotNull);
      },
    );

    test(
      'un perfil roto (sin «acsp», incompleto o con otro largo) no se copia',
      () {
        final good = _iccProfile(300);
        final noSignature = Uint8List.fromList(good)
          ..setAll(36, 'xxxx'.codeUnits);
        final wrongLength = Uint8List.fromList(good)..[3] = 0x10;
        for (final (label, segments) in [
          ('sin acsp', [_iccSegment(noSignature, 1, 1)]),
          (
            'falta el segundo segmento',
            [_iccSegment(good.sublist(0, 100), 1, 2)],
          ),
          ('el largo no coincide', [_iccSegment(wrongLength, 1, 1)]),
        ]) {
          final photo = processRecipePhoto(
            _withSegments(img.encodeJpg(_quadrants(200, 100)), segments),
          );
          expect(_iccOf(photo.full), isNull, reason: label);
          _expectOnlyAllowedSegments(photo.full);
        }
      },
    );

    test(
      'PNG con textos (tEXt) y perfil de color: sale el perfil, los textos no',
      () {
        final icc = _iccProfile(400);
        final image = _quadrants(500, 400)
          ..textData = {
            'Comment': 'Scattata a Bergamo',
            'GPS': '45.6983,9.6773',
            'Software': 'Fotocamera',
          }
          ..iccProfile = img.IccProfile(
            'Display P3',
            img.IccProfileCompression.none,
            icc,
          );
        final input = img.encodePng(image);
        expect(
          _containsAscii(input, 'Scattata a Bergamo'),
          isTrue,
          reason: 'la entrada tiene los textos',
        );

        final photo = processRecipePhoto(input);

        for (final jpeg in [photo.full, photo.thumb]) {
          _expectOnlyAllowedSegments(jpeg);
          expect(_iccOf(jpeg), icc);
          for (final text in ['Bergamo', '45.6983', 'Fotocamera']) {
            expect(_containsAscii(jpeg, text), isFalse, reason: text);
          }
        }
      },
    );

    test('una foto grande que el selector no achicó: la decodifica achicada y sale igual de 1200', () {
      final photo = processRecipePhoto(_phoneJpeg(2600, 1700));
      final full = img.decodeJpg(photo.full)!;
      final thumb = img.decodeJpg(photo.thumb)!;
      expect(_longSide(full), recipePhotoMaxSide);
      expect(full.height, recipePhotoMaxSide, reason: 'derecha: vertical');
      expect(full.width, closeTo(1700 * 1200 / 2600, 1));
      expect(_shortSide(thumb), recipePhotoThumbMinSide);
      expect(thumb.height, closeTo(1200 * 320 / 785, 1));
      _expectOnlyAllowedSegments(photo.full);
      _expectOnlyAllowedSegments(photo.thumb);
    });

    test('la miniatura: el lado menor en 320 (se recorta en un cuadrado), sin agrandar', () {
      for (final (size, thumbSize) in [
        ((1200, 1200), (320, 320)),
        ((1600, 900), (569, 320)),
        ((1200, 300), (1200, 300)), // el lado menor ya tiene menos de 320
        ((300, 200), (300, 200)),
      ]) {
        final photo = processRecipePhoto(
          img.encodePng(_quadrants(size.$1, size.$2)),
        );
        final thumb = img.decodeJpg(photo.thumb)!;
        expect((thumb.width, thumb.height), thumbSize, reason: '$size');
      }
    });

    test('una foto chica no se agranda', () {
      final photo = processRecipePhoto(img.encodePng(_quadrants(300, 200)));
      final full = img.decodeJpg(photo.full)!;
      expect([full.width, full.height], [300, 200]);
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
      _expectOnlyAllowedSegments(photo.full);
    });

    // Un WebP animado trae su color de fondo (ANIM): si llegara a la imagen, el
    // codificador JPEG lo usaría en lugar del blanco. Hoy se decodifica solo
    // el primer cuadro, que no lo trae; _encode lo vacía igual.
    test(
      'WebP animado con fondo negro y transparencia: el fondo queda blanco',
      () {
        img.Image frame() {
          final image = img.Image(width: 200, height: 200, numChannels: 4);
          for (final p in image) {
            final inside = p.x >= 50 && p.x < 150 && p.y >= 50 && p.y < 150;
            p
              ..r = 0
              ..g = 0
              ..b = 200
              ..a = inside ? 255 : 0;
          }
          return image;
        }

        final animation = frame()
          ..addFrame(frame())
          ..backgroundColor = img.ColorRgba8(0, 0, 0, 255);
        final photo = processRecipePhoto(img.encodeWebP(animation));
        final corner = img.decodeJpg(photo.full)!.getPixel(5, 5);
        expect([corner.r, corner.g, corner.b], everyElement(greaterThan(245)));
      },
    );

    test('GIF y WebP también (la primera imagen), en JPEG', () {
      final source = _quadrants(500, 250);
      for (final bytes in [img.encodeGif(source), img.encodeWebP(source)]) {
        final photo = processRecipePhoto(bytes);
        final full = img.decodeJpg(photo.full)!;
        expect([full.width, full.height], [500, 250]);
        final thumb = img.decodeJpg(photo.thumb)!;
        expect(
          [thumb.width, thumb.height],
          [500, 250],
          reason: 'el lado menor ya tiene menos de 320',
        );
        _expectOnlyAllowedSegments(photo.full);
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

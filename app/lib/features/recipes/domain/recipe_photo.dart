// La foto de un plato (pedido de Evelyn del 20/11/2026, migración
// 20261120100000_recipe_photos.sql): una por plato, en el bucket público
// recipe-photos. Dart puro.
//
// La foto que elige la cocinera se prepara en el dispositivo antes de subirla:
// se endereza con la orientación EXIF, se achica a dos tamaños (1200 px de lado
// mayor y la miniatura de 360) y se vuelve a codificar en JPEG sin ningún
// metadato (ni EXIF, ni GPS, ni el perfil de color): el bucket es público y
// una foto del teléfono dice dónde y con qué se sacó. Cada foto lleva un uuid
// nuevo (photoId): un archivo nunca se pisa.
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;

/// Lado mayor de la versión grande, en píxeles.
const int recipePhotoMaxSide = 1200;

/// Lado mayor de la miniatura (la lista, el menù de la web), en píxeles.
const int recipePhotoThumbMaxSide = 360;

/// Tamaño máximo de un archivo en el bucket (file_size_limit).
const int recipePhotoMaxBytes = 2 * 1024 * 1024;

/// Calidades JPEG que se prueban, de mayor a menor, hasta que el archivo entra
/// en [recipePhotoMaxBytes]. A 1200 px la primera alcanza siempre en una foto
/// de verdad (unos 200–400 KB); las otras son por si acaso.
const List<int> _fullQualities = [85, 75, 60, 45, 30];
const List<int> _thumbQualities = [80, 65, 50];

/// Más píxeles que esto no se decodifican (una foto de 48 MP entra de sobra):
/// es para no quedarse sin memoria con un archivo raro.
const int _maxInputPixels = 100 * 1000 * 1000;

/// La foto lista para subir: los dos JPEG, sin metadatos.
final class ProcessedRecipePhoto {
  const ProcessedRecipePhoto({required this.full, required this.thumb});

  /// Lado mayor de [recipePhotoMaxSide] (o menos, si la original era chica).
  final Uint8List full;

  /// Lado mayor de [recipePhotoThumbMaxSide] (o menos).
  final Uint8List thumb;

  @override
  String toString() =>
      'ProcessedRecipePhoto(${full.lengthInBytes} B, ${thumb.lengthInBytes} B)';
}

/// Una foto elegida en el editor que todavía no se subió, con su uuid
/// ([photoId], nuevo en cada elección). Dos son iguales si son la misma
/// elección (el mismo [photoId]): no se comparan los bytes.
final class NewRecipePhoto {
  const NewRecipePhoto({required this.photoId, required this.photo});

  final String photoId;
  final ProcessedRecipePhoto photo;

  @override
  bool operator ==(Object other) =>
      other is NewRecipePhoto && other.photoId == photoId;

  @override
  int get hashCode => photoId.hashCode;

  @override
  String toString() => 'NewRecipePhoto($photoId)';
}

/// Lo que el editor cambia en la foto del plato al guardar.
sealed class RecipePhotoChange {
  const RecipePhotoChange();
}

/// Poner [photo] (en un plato sin foto o en lugar de la que tenía).
final class ReplaceRecipePhoto extends RecipePhotoChange {
  const ReplaceRecipePhoto(this.photo);

  final NewRecipePhoto photo;

  @override
  bool operator ==(Object other) =>
      other is ReplaceRecipePhoto && other.photo == photo;

  @override
  int get hashCode => photo.hashCode;
}

/// Sacar la foto que tiene.
final class RemoveRecipePhoto extends RecipePhotoChange {
  const RemoveRecipePhoto();

  @override
  bool operator ==(Object other) => other is RemoveRecipePhoto;

  @override
  int get hashCode => (RemoveRecipePhoto).hashCode;
}

/// Ruta en el bucket de la foto [photoId] del plato [recipeId] de la cocina
/// [chefId] (la miniatura con [thumb]), en minúsculas como la exigen las
/// políticas de subida y set_recipe_photo.
String recipePhotoPath({
  required String chefId,
  required String recipeId,
  required String photoId,
  bool thumb = false,
}) =>
    '${chefId.toLowerCase()}/${recipeId.toLowerCase()}/'
    '${photoId.toLowerCase()}${thumb ? '-thumb' : ''}.jpg';

/// No se pudo leer la foto (formato que la app no abre, como HEIC en un
/// navegador que no lo convierte, o un archivo roto).
final class RecipePhotoFormatException implements Exception {
  const RecipePhotoFormatException();

  @override
  String toString() => 'RecipePhotoFormatException';
}

/// Prepara [bytes] (JPEG, PNG, WebP o GIF) para subirla: la endereza según su
/// orientación EXIF, la achica a [recipePhotoMaxSide] y a
/// [recipePhotoThumbMaxSide] de lado mayor (nunca agranda), la pone sobre
/// blanco si tiene transparencia y la codifica en JPEG sin metadatos. Lanza
/// [RecipePhotoFormatException] si no la puede leer.
ProcessedRecipePhoto processRecipePhoto(Uint8List bytes) {
  var image = _decode(bytes);
  // Endereza y quita la orientación del EXIF (copyResize también la aplicaría).
  image = img.bakeOrientation(image);
  if (image.hasPalette || image.format != img.Format.uint8) {
    image = image.convert(
      format: img.Format.uint8,
      numChannels: image.hasAlpha ? 4 : 3,
    );
  }
  final full = _fit(image, recipePhotoMaxSide);
  final thumb = _fit(full, recipePhotoThumbMaxSide);
  return ProcessedRecipePhoto(
    full: _encode(full, _fullQualities),
    thumb: _encode(thumb, _thumbQualities),
  );
}

/// La primera imagen de [bytes]. Solo los formatos que pueden llegar del
/// selector (en el iPhone, HEIC llega ya convertido a JPEG): así la web no
/// carga los decodificadores de TIFF, PSD, EXR y demás.
img.Image _decode(Uint8List bytes) {
  try {
    final img.Image? image;
    if (_isJpeg(bytes)) {
      image = _decodeJpeg(bytes);
    } else if (_startsWith(bytes, const [0x89, 0x50, 0x4e, 0x47])) {
      image = img.PngDecoder(maxPixels: _maxInputPixels)
          .decode(bytes, frame: 0);
    } else if (_startsWith(bytes, const [0x47, 0x49, 0x46, 0x38])) {
      image = img.GifDecoder().decode(bytes, frame: 0);
    } else if (_isWebP(bytes)) {
      image = (img.WebPDecoder()..maxPixels = _maxInputPixels).decode(
        bytes,
        frame: 0,
      );
    } else {
      image = null;
    }
    if (image == null || image.width < 1 || image.height < 1) {
      throw const RecipePhotoFormatException();
    }
    return image;
  } on RecipePhotoFormatException {
    rethrow;
  } on Object {
    // ImageException (archivo roto) o falta de memoria.
    throw const RecipePhotoFormatException();
  }
}

/// Un JPEG grande se decodifica ya achicado (1/2, 1/4 u 1/8, lo que deje el
/// lado mayor en [recipePhotoMaxSide] o más): mucho más rápido y con menos
/// memoria, por si el selector no lo achicó (en la web, si el navegador no
/// pudo).
img.Image? _decodeJpeg(Uint8List bytes) {
  final info = img.JpegDecoder(maxPixels: _maxInputPixels).startDecode(bytes);
  if (info == null) return null;
  final longSide = math.max(info.width, info.height);
  var scale = 1;
  for (final candidate in const [8, 4, 2]) {
    if ((longSide / candidate).ceil() >= recipePhotoMaxSide) {
      scale = candidate;
      break;
    }
  }
  return img.JpegDecoder(
    maxPixels: _maxInputPixels,
    scale: scale,
  ).decode(bytes);
}

bool _isJpeg(Uint8List bytes) => _startsWith(bytes, const [0xff, 0xd8, 0xff]);

bool _isWebP(Uint8List bytes) =>
    _startsWith(bytes, const [0x52, 0x49, 0x46, 0x46]) &&
    bytes.length >= 12 &&
    bytes[8] == 0x57 &&
    bytes[9] == 0x45 &&
    bytes[10] == 0x42 &&
    bytes[11] == 0x50;

bool _startsWith(Uint8List bytes, List<int> prefix) {
  if (bytes.length < prefix.length) return false;
  for (var i = 0; i < prefix.length; i++) {
    if (bytes[i] != prefix[i]) return false;
  }
  return true;
}

/// [image] con el lado mayor en [maxSide] como mucho (nunca la agranda).
img.Image _fit(img.Image image, int maxSide) {
  final longSide = math.max(image.width, image.height);
  if (longSide <= maxSide) return image;
  final ratio = maxSide / longSide;
  return img.copyResize(
    image,
    width: math.max(1, (image.width * ratio).round()),
    height: math.max(1, (image.height * ratio).round()),
    interpolation: img.Interpolation.average,
  );
}

/// JPEG de [image] sin metadatos, con la primera calidad de [qualities] que
/// entre en [recipePhotoMaxBytes]. El codificador escribe el EXIF y el perfil
/// de color que tenga la imagen: se vacían antes (la imagen es de acá, se puede
/// cambiar). La transparencia queda sobre blanco.
Uint8List _encode(img.Image image, List<int> qualities) {
  image
    ..exif = img.ExifData()
    ..iccProfile = null
    ..textData = null;
  for (final quality in qualities) {
    final bytes = img.encodeJpg(
      image,
      quality: quality,
      chroma: img.JpegChroma.yuv420,
    );
    if (bytes.lengthInBytes <= recipePhotoMaxBytes) return bytes;
  }
  // Ni con la calidad más baja: no puede pasar con 1200 px de lado mayor.
  throw const RecipePhotoFormatException();
}

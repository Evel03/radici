// La foto de un plato (pedido de Evelyn del 20/11/2026, migración
// 20261120100000_recipe_photos.sql): una por plato, en el bucket público
// recipe-photos. Dart puro.
//
// La foto que elige la cocinera se prepara en el dispositivo antes de subirla:
// se endereza con la orientación EXIF, se achica a dos tamaños (1200 px de lado
// mayor y la miniatura de 320 px de lado menor) y se vuelve a codificar en JPEG
// sin metadatos: ni EXIF, ni GPS, ni XMP, ni IPTC, ni comentarios, ni ningún
// otro segmento. El bucket es público y una foto del teléfono dice dónde y con
// qué se sacó. Solo se conserva el perfil de color (ICC), que no es un dato
// personal: sin él una foto Display P3 del iPhone se ve apagada. Cada foto
// lleva un uuid nuevo (photoId): un archivo nunca se pisa.
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;

/// Lado mayor de la versión grande, en píxeles.
const int recipePhotoMaxSide = 1200;

/// Lado menor de la miniatura, en píxeles: se muestra recortada en un cuadrado
/// (la web a 80 px, la lista de la app a 56), así que lo que cuenta es el lado
/// menor; 320 alcanza para 80 px en una pantalla 3x.
const int recipePhotoThumbMinSide = 320;

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

/// Un perfil de color más grande que esto no se copia (los de un teléfono
/// tienen menos de 4 KB): no tiene que acercar el archivo a los 2 MiB.
const int _maxIccBytes = 256 * 1024;

/// La foto lista para subir: los dos JPEG, sin metadatos (solo el perfil de
/// color, si la original tenía uno).
final class ProcessedRecipePhoto {
  const ProcessedRecipePhoto({required this.full, required this.thumb});

  /// Lado mayor de [recipePhotoMaxSide] (o menos, si la original era chica).
  final Uint8List full;

  /// Lado menor de [recipePhotoThumbMinSide] (o menos, si la grande ya era
  /// más chica).
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
/// orientación EXIF, la achica a [recipePhotoMaxSide] de lado mayor y la
/// miniatura a [recipePhotoThumbMinSide] de lado menor (nunca agranda), la pone
/// sobre blanco si tiene transparencia y la codifica en JPEG sin metadatos, con
/// el perfil de color de la original si tenía uno. Lanza
/// [RecipePhotoFormatException] si no la puede leer.
ProcessedRecipePhoto processRecipePhoto(Uint8List bytes) {
  var image = _decode(bytes);
  final icc = _iccProfileOf(bytes, image);
  // Endereza y quita la orientación del EXIF (copyResize también la aplicaría).
  image = img.bakeOrientation(image);
  if (image.hasPalette || image.format != img.Format.uint8) {
    image = image.convert(
      format: img.Format.uint8,
      numChannels: image.hasAlpha ? 4 : 3,
    );
  }
  final full = _fitLongSide(image, recipePhotoMaxSide);
  final thumb = _fitShortSide(full, recipePhotoThumbMinSide);
  return ProcessedRecipePhoto(
    full: _encode(full, _fullQualities, icc),
    thumb: _encode(thumb, _thumbQualities, icc),
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
img.Image _fitLongSide(img.Image image, int maxSide) =>
    _scaled(image, maxSide / math.max(image.width, image.height));

/// [image] con el lado menor en [minSide] como mucho (nunca la agranda).
img.Image _fitShortSide(img.Image image, int minSide) =>
    _scaled(image, minSide / math.min(image.width, image.height));

img.Image _scaled(img.Image image, double ratio) {
  if (ratio >= 1) return image;
  return img.copyResize(
    image,
    width: math.max(1, (image.width * ratio).round()),
    height: math.max(1, (image.height * ratio).round()),
    interpolation: img.Interpolation.average,
  );
}

/// JPEG de [image] sin metadatos, con la primera calidad de [qualities] que
/// entre en [recipePhotoMaxBytes] (con [icc], el perfil de color, si hay). El
/// codificador escribe el EXIF, el perfil de color y el color de fondo que
/// tenga la imagen: se vacían antes (la imagen es de acá, se puede cambiar). El
/// perfil lo escribe [_withIccProfile]: el codificador del paquete lo escribe
/// sin el número de segmento y sin partirlo si pasa de 64 KB. Sin color de
/// fondo (un WebP animado trae el suyo), la transparencia queda sobre blanco.
Uint8List _encode(img.Image image, List<int> qualities, Uint8List? icc) {
  image
    ..exif = img.ExifData()
    ..iccProfile = null
    ..textData = null
    ..backgroundColor = null;
  for (final quality in qualities) {
    final bytes = _withIccProfile(
      img.encodeJpg(image, quality: quality, chroma: img.JpegChroma.yuv420),
      icc,
    );
    if (bytes.lengthInBytes <= recipePhotoMaxBytes) return bytes;
  }
  // Ni con la calidad más baja: no puede pasar con 1200 px de lado mayor.
  throw const RecipePhotoFormatException();
}

/// «ICC_PROFILE» y un 0: la firma de los segmentos APP2 con el perfil de color.
final List<int> _iccSignature = [...'ICC_PROFILE'.codeUnits, 0];

/// Datos de un segmento APP2 con el perfil: 65535 menos el largo (2), la firma
/// (12) y el número de segmento y el total (2).
const int _iccChunkBytes = 65535 - 2 - 12 - 2;

/// El perfil de color de la original, si tiene uno que parezca un perfil ICC
/// (el largo que dice su encabezado y la firma «acsp»). De un JPEG se lee de
/// sus segmentos APP2 (puede venir partido en varios; el decodificador del
/// paquete se queda con el último y con dos bytes de más); de un PNG o un
/// WebP, el que leyó el decodificador (iCCP, ICCP). Un GIF no tiene.
Uint8List? _iccProfileOf(Uint8List bytes, img.Image decoded) {
  try {
    final profile = _isJpeg(bytes)
        ? _jpegIccProfile(bytes)
        : decoded.iccProfile?.decompressed();
    return profile != null && _looksLikeIcc(profile) ? profile : null;
  } on Object {
    return null;
  }
}

/// El perfil de los segmentos APP2 «ICC_PROFILE» de [jpeg], unidos por su
/// número (1 a N). Si falta alguno o se repite, null.
Uint8List? _jpegIccProfile(Uint8List jpeg) {
  final chunks = <int, Uint8List>{};
  int? total;
  var offset = 2;
  while (offset + 4 <= jpeg.length) {
    if (jpeg[offset] != 0xff) return null;
    final marker = jpeg[offset + 1];
    if (marker == 0xff) {
      offset++; // relleno
      continue;
    }
    if (marker == 0xda || marker == 0xd9) break; // empiezan los datos
    if (marker == 0x01 || (marker >= 0xd0 && marker <= 0xd7)) {
      offset += 2; // sin largo
      continue;
    }
    final length = (jpeg[offset + 2] << 8) | jpeg[offset + 3];
    final end = offset + 2 + length;
    if (length < 2 || end > jpeg.length) return null;
    if (marker == 0xe2 &&
        length >= 2 + 14 &&
        _hasIccSignature(jpeg, offset + 4)) {
      final sequence = jpeg[offset + 4 + 12];
      final count = jpeg[offset + 4 + 13];
      if (total != null && total != count) return null;
      total = count;
      if (sequence < 1 || sequence > count || chunks.containsKey(sequence)) {
        return null;
      }
      chunks[sequence] = Uint8List.sublistView(jpeg, offset + 4 + 14, end);
    }
    offset = end;
  }
  if (total == null || chunks.length != total) return null;
  final profile = BytesBuilder(copy: false);
  for (var sequence = 1; sequence <= total; sequence++) {
    profile.add(chunks[sequence]!);
  }
  return profile.takeBytes();
}

bool _hasIccSignature(Uint8List bytes, int at) {
  if (at + _iccSignature.length > bytes.length) return false;
  for (var i = 0; i < _iccSignature.length; i++) {
    if (bytes[at + i] != _iccSignature[i]) return false;
  }
  return true;
}

/// El encabezado de un perfil ICC: el largo total en los primeros 4 bytes y
/// «acsp» en los bytes 36 a 39.
bool _looksLikeIcc(Uint8List profile) {
  if (profile.length < 132 || profile.length > _maxIccBytes) return false;
  final declared =
      (profile[0] << 24) | (profile[1] << 16) | (profile[2] << 8) | profile[3];
  return declared == profile.length &&
      profile[36] == 0x61 && // a
      profile[37] == 0x63 && // c
      profile[38] == 0x73 && // s
      profile[39] == 0x70; // p
}

/// [jpeg] (como lo escribe el paquete: SOI y APP0 al principio) con [icc] en
/// segmentos APP2 «ICC_PROFILE» numerados, después del APP0.
Uint8List _withIccProfile(Uint8List jpeg, Uint8List? icc) {
  if (icc == null) return jpeg;
  final hasApp0 = jpeg[2] == 0xff && jpeg[3] == 0xe0;
  final app0End = hasApp0 ? 4 + ((jpeg[4] << 8) | jpeg[5]) : 2;
  final count = (icc.length / _iccChunkBytes).ceil();
  final out = BytesBuilder(copy: false)
    ..add(Uint8List.sublistView(jpeg, 0, app0End));
  for (var i = 0; i < count; i++) {
    final chunk = Uint8List.sublistView(
      icc,
      i * _iccChunkBytes,
      math.min(icc.length, (i + 1) * _iccChunkBytes),
    );
    final length = 2 + _iccSignature.length + 2 + chunk.length;
    out
      ..add([0xff, 0xe2, length >> 8, length & 0xff])
      ..add(_iccSignature)
      ..add([i + 1, count])
      ..add(chunk);
  }
  out.add(Uint8List.sublistView(jpeg, app0End));
  return out.takeBytes();
}

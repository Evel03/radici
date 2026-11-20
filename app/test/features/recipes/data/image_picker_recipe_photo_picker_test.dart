// El selector de fotos sobre image_picker (un ImagePicker simulado): pide la
// foto ya achicada a 1200 px y sin pedir permiso a la fototeca, devuelve los
// bytes o null si se canceló, y traduce los errores.
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';
import 'package:mocktail/mocktail.dart';
import 'package:radici/features/recipes/data/recipe_photo_picker.dart';

class _MockImagePicker extends Mock implements ImagePicker {}

void main() {
  late _MockImagePicker imagePicker;
  late ImagePickerRecipePhotoPicker picker;

  setUpAll(() => registerFallbackValue(ImageSource.gallery));

  setUp(() {
    imagePicker = _MockImagePicker();
    picker = ImagePickerRecipePhotoPicker(imagePicker);
  });

  void answer(Future<XFile?> Function() result) => when(
    () => imagePicker.pickImage(
      source: any(named: 'source'),
      maxWidth: any(named: 'maxWidth'),
      maxHeight: any(named: 'maxHeight'),
      requestFullMetadata: any(named: 'requestFullMetadata'),
    ),
  ).thenAnswer((_) => result());

  test('pide la foto achicada a 1200 px, sin permiso de la fototeca, y devuelve sus bytes', () async {
    final bytes = Uint8List.fromList([0xff, 0xd8, 0xff, 1]);
    answer(() async => XFile.fromData(bytes, mimeType: 'image/jpeg'));

    expect(await picker.pick(RecipePhotoSource.camera), bytes);
    expect(await picker.pick(RecipePhotoSource.gallery), bytes);

    for (final source in [ImageSource.camera, ImageSource.gallery]) {
      verify(
        () => imagePicker.pickImage(
          source: source,
          maxWidth: 1200,
          maxHeight: 1200,
          requestFullMetadata: false,
        ),
      ).called(1);
    }
  });

  test('cancelar devuelve null', () async {
    answer(() async => null);
    expect(await picker.pick(RecipePhotoSource.gallery), isNull);
  });

  test('sin permiso → permissionDenied; otro error → unavailable', () async {
    Matcher failure(RecipePhotoPickFailureKind kind) => throwsA(
      isA<RecipePhotoPickFailure>().having((f) => f.kind, 'kind', kind),
    );
    for (final code in ['camera_access_denied', 'photo_access_denied']) {
      answer(() async => throw PlatformException(code: code));
      await expectLater(
        picker.pick(RecipePhotoSource.camera),
        failure(RecipePhotoPickFailureKind.permissionDenied),
        reason: code,
      );
    }
    answer(() async => throw PlatformException(code: 'no_available_camera'));
    await expectLater(
      picker.pick(RecipePhotoSource.camera),
      failure(RecipePhotoPickFailureKind.unavailable),
    );
    answer(() async => throw StateError('ya abierto'));
    await expectLater(
      picker.pick(RecipePhotoSource.gallery),
      failure(RecipePhotoPickFailureKind.unavailable),
    );
  });
}

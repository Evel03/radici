// Identidad de Radici (manual de marca; la misma de la web y de los emails),
// en Dart puro (sin Flutter): la usan el tema (core/theme.dart), el logotipo
// (core/radici_logo.dart) y el generador de íconos (tool/generate_icons.dart).

/// Paleta del manual (ARGB) y los derivados de la web
/// (web/src/styles/base.css), con el contraste verificado (WCAG AA).
const int brandOlive = 0xFF4A5A3C;
const int brandOliveDark = 0xFF3A4730;
const int brandOliveTint = 0xFFE6E4D3;
const int brandCream = 0xFFF5EDE1;
const int brandCreamLight = 0xFFFBF7F1;
const int brandCreamDark = 0xFFEDE2D2;
const int brandTerra = 0xFF8B6B4F;
const int brandTerraInk = 0xFF7A5C43;
const int brandTerraTint = 0xFFEFE0D0;
const int brandTerraDeep = 0xFF5A4330;
const int brandLinen = 0xFFDBC9B4;
const int brandInk = 0xFF2C2B20;
const int brandMuted = 0xFF5B5847;
const int brandError = 0xFF9A3B26;
const int brandErrorTint = 0xFFF6E2DA;
const int brandErrorDeep = 0xFF5C1F10;

/// Familias empaquetadas (pubspec.yaml): Cinzel para el logotipo (sus
/// minúsculas son versalitas) y Cormorant Garamond para los títulos.
const String brandDisplayFont = 'Cinzel';
const String brandSerifFont = 'Cormorant Garamond';

/// La marca de los íconos es la R de Cinzel, como el favicon de la web, sacada
/// de la misma fuente que usa la app (ruta desde app/).
const String brandMarkFontAsset = 'assets/fonts/Cinzel-Medium.ttf';
const int brandMarkCodePoint = 0x52; // R

# Genera las fuentes de la marca que empaqueta la app (assets/fonts/): un peso estático de cada
# variable de Google Fonts (licencia OFL), el mismo que usa la web, con solo las letras latinas y
# las funciones tipográficas que usa la app. Así /gestione/ descarga ~190 KB en lugar de ~1,3 MB.
#
# Uso, desde app/ (necesita Python 3 con fontTools: pip install fonttools):
#   python tool/fonts/make_brand_fonts.py <carpeta>
# donde <carpeta> tiene las variables de github.com/google/fonts:
#   ofl/cinzel/Cinzel[wght].ttf                       → guardada como Cinzel-wght.ttf
#   ofl/cormorantgaramond/CormorantGaramond[wght].ttf → guardada como CormorantGaramond-wght.ttf
# Después: dart run tool/generate_icons.dart (los íconos leen la R de Cinzel-Medium.ttf).
import sys
from pathlib import Path

from fontTools import subset
from fontTools.ttLib import TTFont
from fontTools.varLib.instancer import instantiateVariableFont

# Los mismos rangos que los subconjuntos "latin" y "latin-ext" de la web (@fontsource): italiano,
# español e inglés, y nombres con letras de Europa central (Łukasz, Dvořák) en la bandeja.
LATIN = (
    "U+0000-00FF,U+0131,U+0152-0153,U+02BB-02BC,U+02C6,U+02DA,U+02DC,U+0304,U+0308,U+0329,"
    "U+2000-206F,U+20AC,U+2122,U+2191,U+2193,U+2212,U+2215,U+FEFF,U+FFFD"
)
LATIN_EXT = (
    "U+0100-02BA,U+02BD-02C5,U+02C7-02CC,U+02CE-02D7,U+02DD-02FF,U+1D00-1DBF,U+1E00-1E9F,"
    "U+1EF2-1EFF,U+2020,U+20A0-20AB,U+20AD-20C0,U+2113,U+2C60-2C7F,U+A720-A7FF"
)

# Funciones que se conservan: las básicas y las cifras (lnum: el tema pide números de caja alta,
# porque las de estilo antiguo de Cormorant confunden el 1 con una i). Afuera quedan las
# alternativas (versalitas, adornos, ligaduras discrecionales), que la app no usa.
FEATURES = ["kern", "liga", "clig", "calt", "ccmp", "locl", "mark", "mkmk", "lnum", "pnum", "tnum", "case"]

# Pesos de la web: Cinzel 500 (logotipo y rótulos), Cormorant Garamond 600 (títulos).
JOBS = [
    ("Cinzel-wght.ttf", 500, "Cinzel-Medium.ttf"),
    ("CormorantGaramond-wght.ttf", 600, "CormorantGaramond-SemiBold.ttf"),
]


def main() -> None:
    if len(sys.argv) != 2 or not Path("pubspec.yaml").exists():
        sys.exit("Uso, desde app/: python tool/fonts/make_brand_fonts.py <carpeta con las variables>")
    source_dir, out_dir = Path(sys.argv[1]), Path("assets/fonts")
    for source, weight, target in JOBS:
        font = instantiateVariableFont(TTFont(source_dir / source), {"wght": weight})
        options = subset.Options()
        options.layout_features = FEATURES
        options.name_IDs = ["*"]
        options.name_languages = ["*"]
        options.notdef_outline = True
        options.hinting = False
        options.unicodes = subset.parse_unicodes(f"{LATIN},{LATIN_EXT}")
        subsetter = subset.Subsetter(options=options)
        subsetter.populate(unicodes=options.unicodes)
        subsetter.subset(font)
        font.save(out_dir / target)
        print(f"{out_dir / target}: {(out_dir / target).stat().st_size} bytes")


if __name__ == "__main__":
    main()

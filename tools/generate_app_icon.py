from pathlib import Path

from PIL import Image, ImageDraw


ROOT = Path(__file__).resolve().parents[1]
ICONSET = ROOT / "ios" / "XRelayClient" / "Assets.xcassets" / "AppIcon.appiconset"
MASTER_SIZE = 1024
SCALE = 4


def make_master():
    size = MASTER_SIZE * SCALE
    canvas = Image.new("RGB", (size, size), (0, 0, 0))
    draw = ImageDraw.Draw(canvas)

    # Original geometric X mark, designed for this client (not copied from the APK).
    def scaled(points):
        return [(round(x * SCALE), round(y * SCALE)) for x, y in points]

    draw.polygon(scaled([(230, 205), (345, 205), (794, 819), (679, 819)]), fill=(255, 255, 255))
    draw.polygon(scaled([(679, 205), (794, 205), (345, 819), (230, 819)]), fill=(255, 255, 255))
    return canvas.resize((MASTER_SIZE, MASTER_SIZE), Image.Resampling.LANCZOS)


def main():
    ICONSET.mkdir(parents=True, exist_ok=True)
    master = make_master()
    sizes = {
        "Icon-iPad-20.png": 20,
        "Icon-iPad-20@2x.png": 40,
        "Icon-iPhone-20@2x.png": 40,
        "Icon-iPhone-20@3x.png": 60,
        "Icon-iPad-29.png": 29,
        "Icon-iPad-29@2x.png": 58,
        "Icon-iPhone-29@2x.png": 58,
        "Icon-iPhone-29@3x.png": 87,
        "Icon-iPad-40.png": 40,
        "Icon-iPad-40@2x.png": 80,
        "Icon-iPhone-40@2x.png": 80,
        "Icon-iPhone-40@3x.png": 120,
        "Icon-iPhone-60@2x.png": 120,
        "Icon-iPhone-60@3x.png": 180,
        "Icon-iPad-76.png": 76,
        "Icon-iPad-76@2x.png": 152,
        "Icon-iPad-83.5@2x.png": 167,
        "Icon-1024.png": 1024,
    }
    for filename, size in sizes.items():
        master.resize((size, size), Image.Resampling.LANCZOS).save(ICONSET / filename, format="PNG", optimize=True)


if __name__ == "__main__":
    main()

import copy
import io
import sys
import zipfile
from PIL import Image, ImageOps

source, output, icon_path = sys.argv[1:4]

artwork = Image.open(icon_path).convert("RGBA")

groups = {
    "legacy": [
        "0B", "_i", "B1", "II", "AF", "p9"
    ],
    "background": [
        "kC", "CC", "u6", "V8", "pO", "3E"
    ],
    "foreground": [
        "eu", "0W", "2D", "q9", "M1", "4l"
    ],
    "monochrome": [
        "oR", "RF", "o1", "tg", "YU", "5n"
    ]
}

targets = {
    "res/" + filename + ".webp": role
    for role, filenames in groups.items()
    for filename in filenames
}

# Isolate the portal symbol for adaptive icons.
# The Android launcher supplies the application name separately.
symbol = artwork.crop((85, 50, 427, 340))

pixels = []

for r, g, b, a in symbol.getdata():
    brightness = max(r, g, b)

    alpha = max(
        0,
        min(255, int((brightness - 70) * 255 / 100))
    )

    pixels.append((r, g, b, alpha))

symbol.putdata(pixels)

def make_icon(role, size):
    w, h = size

    if role == "legacy":
        return artwork.resize(
            size, Image.Resampling.LANCZOS
        )

    if role == "background":
        return Image.new(
            "RGBA", size, (12, 15, 37, 255)
        )

    canvas = Image.new(
        "RGBA", size, (0, 0, 0, 0)
    )

    mark = ImageOps.contain(
        symbol,
        (int(w * 0.60), int(h * 0.60)),
        Image.Resampling.LANCZOS
    )

    if role == "monochrome":
        white = Image.new(
            "RGBA", mark.size, (255, 255, 255, 255)
        )
        white.putalpha(mark.getchannel("A"))
        mark = white

    x = (w - mark.width) // 2
    y = (h - mark.height) // 2

    canvas.alpha_composite(mark, (x, y))

    return canvas

modified = {}

with zipfile.ZipFile(source) as src:

    missing = set(targets) - set(src.namelist())

    if missing:
        raise RuntimeError(
            "Missing icon resources: " + str(missing)
        )

    with zipfile.ZipFile(output, "w") as dst:

        for entry in src.infolist():

            data = src.read(entry.filename)

            if entry.filename in targets:

                role = targets[entry.filename]

                original = Image.open(
                    io.BytesIO(data)
                )

                result = make_icon(
                    role, original.size
                )

                buffer = io.BytesIO()

                result.save(
                    buffer,
                    format="WEBP",
                    lossless=True
                )

                data = buffer.getvalue()

                modified[entry.filename] = data

                print(
                    "REPLACED:",
                    entry.filename,
                    role,
                    result.size
                )

            dst.writestr(
                copy.copy(entry), data
            )

    with zipfile.ZipFile(output) as dst:

        assert dst.testzip() is None
        assert len(modified) == 24

        for name in src.namelist():

            actual = dst.read(name)

            if name in modified:

                assert actual == modified[name]

                image = Image.open(
                    io.BytesIO(actual)
                )

                assert image.format == "WEBP"

                image.verify()

            else:

                assert actual == src.read(name)

print("All 24 launcher images replaced.")
print("All other APK contents preserved.")
print("Icon verification: PASS")

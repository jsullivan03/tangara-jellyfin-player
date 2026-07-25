from pathlib import Path
from PIL import Image, ImageDraw, ImageFilter, ImageOps

SOURCE = Path("desktop-sim/test-cover.png")
OUTPUT = Path("desktop-sim/generated")
OUTPUT.mkdir(parents=True, exist_ok=True)

cover = Image.open(SOURCE).convert("RGB")

# Find an approximate dominant album color.
sample = cover.resize((64, 64), Image.Resampling.LANCZOS)
quantized = sample.quantize(colors=8)

color_counts = quantized.getcolors()
dominant_index = max(color_counts, key=lambda item: item[0])[1]

palette = quantized.getpalette()
dominant = tuple(
    palette[dominant_index * 3 : dominant_index * 3 + 3]
)

# Decorative background: cropping is okay because it is heavily blurred.
background = ImageOps.fit(
    cover,
    (160, 128),
    method=Image.Resampling.LANCZOS,
    centering=(0.5, 0.5),
)

background = background.filter(ImageFilter.GaussianBlur(radius=11))

tint = Image.new("RGB", background.size, dominant)
background = Image.blend(background, tint, 0.28)

black = Image.new("RGB", background.size, (2, 3, 7))
background = Image.blend(background, black, 0.70)

background.save(OUTPUT / "now-playing-background.png")

# Sharp foreground artwork.
art_size = 66
contained = ImageOps.contain(
    cover,
    (art_size, art_size),
    method=Image.Resampling.LANCZOS,
)

art = Image.new("RGB", (art_size, art_size), (0, 0, 0))
paste_x = (art_size - contained.width) // 2
paste_y = (art_size - contained.height) // 2
art.paste(contained, (paste_x, paste_y))
art.save(OUTPUT / "now-playing-cover.png")

# Dark translucent edge overlays for the scrolling title.
fade_width = 9
fade_height = 15

left_fade = Image.new("RGBA", (fade_width, fade_height))
right_fade = Image.new("RGBA", (fade_width, fade_height))

for x in range(fade_width):
    ratio = x / max(1, fade_width - 1)

    left_alpha = int(205 * (1.0 - ratio))
    right_alpha = int(205 * ratio)

    for y in range(fade_height):
        left_fade.putpixel((x, y), (2, 3, 7, left_alpha))
        right_fade.putpixel((x, y), (2, 3, 7, right_alpha))

left_fade.save(OUTPUT / "title-fade-left.png")
right_fade.save(OUTPUT / "title-fade-right.png")

print(f"Dominant color: {dominant}")
print("Prepared simulator artwork.")

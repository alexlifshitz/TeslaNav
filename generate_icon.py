#!/usr/bin/env python3
"""Generate TeslaNav app icon - golden map pin with lightning bolt."""

from PIL import Image, ImageDraw, ImageFilter
import math

SIZE = 1024
BG = (10, 10, 14)

img = Image.new("RGB", (SIZE, SIZE), BG)
draw = ImageDraw.Draw(img)

# === Pin parameters ===
pin_cx = SIZE // 2
head_cy = 360        # center of circular head
head_r = 250         # outer radius of head
inner_r = 148        # inner dark circle radius (thick gold ring = 102px)
tip_y = 870          # bottom point

gold = (255, 200, 20)
gold_light = (255, 225, 70)

# === Draw pin as circle + triangle ===
# 1. Gold filled circle (head)
draw.ellipse([pin_cx - head_r, head_cy - head_r, pin_cx + head_r, head_cy + head_r],
             fill=gold)

# 2. Gold triangle (taper to point)
# Triangle top width matches where it meets the circle
# Use tangent geometry to find where triangle edges meet circle
dist = tip_y - head_cy
tangent_half = math.asin(head_r / dist)  # ~28.5 degrees

# Tangent touch points on the circle
left_touch_x = pin_cx - head_r * math.cos(math.pi / 2 - tangent_half)
left_touch_y = head_cy + head_r * math.sin(math.pi / 2 - tangent_half)
right_touch_x = pin_cx + head_r * math.cos(math.pi / 2 - tangent_half)
right_touch_y = left_touch_y  # symmetric

draw.polygon([
    (left_touch_x, left_touch_y),
    (pin_cx, tip_y),
    (right_touch_x, right_touch_y),
], fill=gold)

# 3. Dark inner circle
draw.ellipse([pin_cx - inner_r, head_cy - inner_r, pin_cx + inner_r, head_cy + inner_r],
             fill=BG)

# === Lightning bolt ===
bolt_cx = pin_cx
bolt_cy = head_cy
bolt_h = inner_r * 0.70

bolt_pts = [
    (0.08, -1.0),
    (-0.50, 0.08),
    (-0.05, 0.08),
    (-0.28, 1.0),
    (0.50, -0.12),
    (0.05, -0.12),
]
scaled = [(bolt_cx + x * bolt_h, bolt_cy + y * bolt_h) for x, y in bolt_pts]
draw.polygon(scaled, fill=gold)

# Brighter upper half of bolt
upper = [(0.08, -1.0), (-0.50, 0.08), (-0.05, 0.08), (0.05, -0.12)]
draw.polygon([(bolt_cx + x * bolt_h, bolt_cy + y * bolt_h) for x, y in upper],
             fill=gold_light)

# === Subtle depth effects ===
img_rgba = img.convert("RGBA")

# Specular highlight on gold ring (upper-left)
spec = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
spec_draw = ImageDraw.Draw(spec)
sx = pin_cx - head_r * 0.4
sy = head_cy - head_r * 0.4
spec_draw.ellipse([sx - 50, sy - 40, sx + 50, sy + 40], fill=(255, 255, 255, 50))
spec = spec.filter(ImageFilter.GaussianBlur(radius=20))
img_rgba = Image.alpha_composite(img_rgba, spec)

# Subtle inner ring glow
ring = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
ring_draw = ImageDraw.Draw(ring)
ring_draw.ellipse(
    [pin_cx - inner_r - 1, head_cy - inner_r - 1,
     pin_cx + inner_r + 1, head_cy + inner_r + 1],
    outline=(255, 220, 50, 50), width=2,
)
img_rgba = Image.alpha_composite(img_rgba, ring)

# Save
final = img_rgba.convert("RGB")
out = "/Users/alex/Desktop/TeslaNav/TeslaNav/Assets.xcassets/AppIcon.appiconset/AppIcon.png"
final.save(out, "PNG")
print(f"Saved: {out}")

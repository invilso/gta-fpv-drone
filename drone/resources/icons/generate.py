#!/usr/bin/env python3
# /// script
# requires-python = ">=3.9"
# dependencies = ["pillow"]
# ///
"""Menu icons, macOS Big Sur style: rounded-square gradient tiles with a
white glyph, soft top highlight and bottom shade for depth. Two palettes
are produced from the same glyphs:

  color/  -- per-section colored tiles (the default look)
  mono/   -- frosted translucent tiles, for the all-glass appearance

plus profile icons (whoop / racer / heavy / default quad silhouettes).
Re-run after editing: uv run generate.py
"""
import math
from PIL import Image, ImageDraw, ImageFilter

S = 1024         # supersampled canvas
OUT = 128        # shipped tile size
W = (255, 255, 255, 255)
GLYPH_LINE = 58

# section -> (top gradient color, bottom gradient color), Big Sur-ish hues
TILE_COLORS = {
    "fly":        ((255, 94, 135), (219, 39, 88)),    # pink
    "controller": ((110, 120, 255), (72, 66, 224)),   # indigo
    "camera":     ((120, 130, 145), (70, 78, 92)),    # graphite blue
    "world":      ((88, 200, 108), (34, 150, 70)),    # green
    "audio":      ((255, 158, 80), (235, 98, 40)),    # orange
    "osd":        ((80, 200, 220), (30, 140, 170)),   # teal
    "replay":     ((190, 120, 255), (130, 62, 220)),  # purple
    "advanced":   ((150, 156, 168), (92, 97, 108)),   # gear gray
}
MONO_TILE = ((255, 255, 255, 46), (255, 255, 255, 24))
PROFILE_TILE = ((70, 76, 92, 255), (40, 44, 56, 255))


def squircle_mask(radius_frac=0.30):
    m = Image.new("L", (S, S), 0)
    d = ImageDraw.Draw(m)
    d.rounded_rectangle([0, 0, S - 1, S - 1], radius=int(S * radius_frac), fill=255)
    return m


def gradient_tile(top, bottom):
    tile = Image.new("RGBA", (S, S))
    ta = top[3] if len(top) == 4 else 255
    ba = bottom[3] if len(bottom) == 4 else 255
    for y in range(S):
        t = y / (S - 1)
        r = int(top[0] + (bottom[0] - top[0]) * t)
        g = int(top[1] + (bottom[1] - top[1]) * t)
        b = int(top[2] + (bottom[2] - top[2]) * t)
        a = int(ta + (ba - ta) * t)
        ImageDraw.Draw(tile).line([(0, y), (S, y)], fill=(r, g, b, a))
    # soft top highlight (glass sheen) and bottom shade for depth
    sheen = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    ds = ImageDraw.Draw(sheen)
    ds.ellipse([-S * 0.25, -S * 0.55, S * 1.25, S * 0.42], fill=(255, 255, 255, 34))
    sheen = sheen.filter(ImageFilter.GaussianBlur(S * 0.03))
    tile.alpha_composite(sheen)
    shade = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    ImageDraw.Draw(shade).rectangle([0, S * 0.72, S, S], fill=(0, 0, 0, 26))
    shade = shade.filter(ImageFilter.GaussianBlur(S * 0.05))
    tile.alpha_composite(shade)
    out = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    out.paste(tile, (0, 0), squircle_mask())
    return out


def glyph_canvas():
    img = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    return img, ImageDraw.Draw(img)


def rotated_rect(draw, cx, cy, w, h, angle_deg, fill, rounded=0):
    a = math.radians(angle_deg)
    dx, dy = math.cos(a), math.sin(a)
    px, py = -dy, dx
    pts = []
    for sx, sy in ((-1, -1), (1, -1), (1, 1), (-1, 1)):
        pts.append((cx + sx * w / 2 * dx + sy * h / 2 * px,
                    cy + sx * w / 2 * dy + sy * h / 2 * py))
    draw.polygon(pts, fill=fill)


def quad_glyph(d, cx, cy, scale, line=GLYPH_LINE):
    """Detailed quadcopter: X arms, ducts, prop arcs, camera-front body."""
    arm = 500 * scale
    rotated_rect(d, cx, cy, arm, line * scale * 0.9, 45, W)
    rotated_rect(d, cx, cy, arm, line * scale * 0.9, -45, W)
    r = 132 * scale
    off = 205 * scale
    for ox, oy in ((-1, -1), (1, -1), (-1, 1), (1, 1)):
        mx, my = cx + ox * off, cy + oy * off
        d.ellipse([mx - r, my - r, mx + r, my + r], outline=W, width=int(line * scale))
        # prop hint: short arc inside the duct
        d.arc([mx - r * 0.55, my - r * 0.55, mx + r * 0.55, my + r * 0.55],
              start=ox * 40, end=ox * 40 + 200, fill=W, width=int(line * scale * 0.6))
    body = 118 * scale
    d.rounded_rectangle([cx - body, cy - body, cx + body, cy + body],
                        radius=int(46 * scale), fill=W)
    # camera pupil cut
    d.ellipse([cx - 40 * scale, cy - 40 * scale, cx + 40 * scale, cy + 40 * scale],
              fill=(0, 0, 0, 0))


def glyph_fly():
    img, d = glyph_canvas()
    quad_glyph(d, S / 2, S / 2, 1.0)
    return img


def glyph_controller():
    img, d = glyph_canvas()
    d.rounded_rectangle([120, 300, S - 120, S - 300], radius=190, outline=W, width=GLYPH_LINE)
    # left stick, right buttons diamond, center dots
    d.ellipse([255, S / 2 - 78, 411, S / 2 + 78], outline=W, width=GLYPH_LINE)
    d.ellipse([300, S / 2 - 33, 366, S / 2 + 33], fill=W)
    bx, by, br = S - 330, S / 2, 34
    for ox, oy in ((0, -78), (78, 0), (0, 78), (-78, 0)):
        d.ellipse([bx + ox - br, by + oy - br, bx + ox + br, by + oy + br], fill=W)
    for ox in (-52, 52):
        d.rounded_rectangle([S / 2 + ox - 30, S / 2 - 14, S / 2 + ox + 30, S / 2 + 14],
                            radius=14, fill=W)
    return img


def glyph_camera():
    img, d = glyph_canvas()
    d.rounded_rectangle([110, 280, S - 110, S - 240], radius=120, outline=W, width=GLYPH_LINE)
    d.rounded_rectangle([S / 2 - 170, 190, S / 2 + 170, 300], radius=60, fill=W)
    for r, wl in ((190, GLYPH_LINE), (110, int(GLYPH_LINE * 0.8))):
        d.ellipse([S / 2 - r, S / 2 + 20 - r, S / 2 + r, S / 2 + 20 + r],
                  outline=W, width=wl)
    d.ellipse([S / 2 + 40, S / 2 - 80, S / 2 + 95, S / 2 - 25], fill=W)  # lens glint
    d.ellipse([S - 250, 330, S - 190, 390], fill=W)  # rec dot
    return img


def glyph_world():
    img, d = glyph_canvas()
    m = 150
    d.ellipse([m, m, S - m, S - m], outline=W, width=GLYPH_LINE)
    d.ellipse([S / 2 - 190, m, S / 2 + 190, S - m], outline=W, width=int(GLYPH_LINE * 0.72))
    for frac, half in ((0.5, 1.0), (0.30, 0.86), (0.70, 0.86)):
        y = m + (S - 2 * m) * frac
        halfw = (S / 2 - m) * half
        d.line([S / 2 - halfw, y, S / 2 + halfw, y], fill=W, width=int(GLYPH_LINE * 0.72))
    return img


def glyph_audio():
    img, d = glyph_canvas()
    d.polygon([(180, 400), (350, 400), (520, 240), (520, S - 240),
               (350, S - 400), (180, S - 400)], fill=W)
    d.rounded_rectangle([150, 400, 330, S - 400], radius=40, fill=W)
    for r in (150, 260, 370):
        d.arc([520 - r, S / 2 - r, 520 + r, S / 2 + r], start=-52, end=52,
              fill=W, width=GLYPH_LINE)
    return img


def glyph_osd():
    img, d = glyph_canvas()
    d.rounded_rectangle([100, 210, S - 100, S - 210], radius=110, outline=W, width=GLYPH_LINE)
    # mini artificial horizon: center dot, side bars, pitch ladder
    d.line([250, S / 2, 400, S / 2], fill=W, width=GLYPH_LINE)
    d.line([S - 400, S / 2, S - 250, S / 2], fill=W, width=GLYPH_LINE)
    d.ellipse([S / 2 - 40, S / 2 - 40, S / 2 + 40, S / 2 + 40], fill=W)
    for dy in (-130, 130):
        d.line([S / 2 - 110, S / 2 + dy, S / 2 + 110, S / 2 + dy],
               fill=W, width=int(GLYPH_LINE * 0.6))
    for x in (250, S - 250):
        d.line([x, 330, x, 420], fill=W, width=int(GLYPH_LINE * 0.6))
        d.line([x, S - 420, x, S - 330], fill=W, width=int(GLYPH_LINE * 0.6))
    return img


def glyph_replay():
    img, d = glyph_canvas()
    m = 150
    d.ellipse([m, m, S - m, S - m], outline=W, width=GLYPH_LINE)
    # rounded play triangle
    tri = [(S / 2 - 105, S / 2 - 185), (S / 2 - 105, S / 2 + 185), (S / 2 + 215, S / 2)]
    d.polygon(tri, fill=W)
    # subtle "rewind" arc + arrowhead
    d.arc([m + 95, m + 95, S - m - 95, S - m - 95], start=140, end=220,
          fill=W, width=int(GLYPH_LINE * 0.6))
    return img


def glyph_advanced():
    img, d = glyph_canvas()
    cx = cy = S / 2
    for i in range(8):
        a = i * 45 + 22.5
        rotated_rect(d, cx + 300 * math.cos(math.radians(a)),
                     cy + 300 * math.sin(math.radians(a)), 150, 128, a, W)
    d.ellipse([cx - 300, cy - 300, cx + 300, cy + 300], fill=W)
    d.ellipse([cx - 140, cy - 140, cx + 140, cy + 140], fill=(0, 0, 0, 0))
    # inner tick marks, watch-face detail
    for i in range(4):
        a = math.radians(i * 90 + 45)
        x1, y1 = cx + 170 * math.cos(a), cy + 170 * math.sin(a)
        x2, y2 = cx + 225 * math.cos(a), cy + 225 * math.sin(a)
        d.line([x1, y1, x2, y2], fill=(0, 0, 0, 0), width=int(GLYPH_LINE * 0.5))
    return img


# Profile glyphs: silhouettes that read as different drone classes.
def glyph_profile_whoop():
    img, d = glyph_canvas()
    # tiny ducted whoop: 4 fat touching ducts, small body
    r, off = 205, 215
    for ox, oy in ((-1, -1), (1, -1), (-1, 1), (1, 1)):
        mx, my = S / 2 + ox * off, S / 2 + oy * off
        d.ellipse([mx - r, my - r, mx + r, my + r], outline=W, width=int(GLYPH_LINE * 1.2))
    d.rounded_rectangle([S / 2 - 95, S / 2 - 95, S / 2 + 95, S / 2 + 95], radius=44, fill=W)
    return img


def glyph_profile_racer():
    img, d = glyph_canvas()
    quad_glyph(d, S / 2, S / 2, 0.94)
    # speed slashes
    for i, y in enumerate((S / 2 - 60, S / 2, S / 2 + 60)):
        d.line([70, y, 180 - i * 20, y], fill=W, width=int(GLYPH_LINE * 0.6))
    return img


def glyph_profile_heavy():
    img, d = glyph_canvas()
    # hexacopter: 6 arms + big rotors
    for i in range(6):
        a = i * 60
        rotated_rect(d, S / 2 + 235 * math.cos(math.radians(a)) / 2,
                     S / 2 + 235 * math.sin(math.radians(a)) / 2,
                     235, GLYPH_LINE, a, W)
        mx = S / 2 + 300 * math.cos(math.radians(a))
        my = S / 2 + 300 * math.sin(math.radians(a))
        d.ellipse([mx - 108, my - 108, mx + 108, my + 108], outline=W,
                  width=int(GLYPH_LINE * 0.9))
    d.ellipse([S / 2 - 130, S / 2 - 130, S / 2 + 130, S / 2 + 130], fill=W)
    return img


def glyph_profile_default():
    img, d = glyph_canvas()
    quad_glyph(d, S / 2, S / 2, 1.0)
    return img


def glyph_profile_custom():
    """Default face of user-made profiles: a quad plus a small gear badge,
    kept apart so neither overlaps the other."""
    img, d = glyph_canvas()
    quad_glyph(d, S * 0.40, S * 0.40, 0.62)
    gx, gy = S * 0.80, S * 0.80
    # clear a disc behind the gear so it reads as a separate badge
    d.ellipse([gx - 175, gy - 175, gx + 175, gy + 175], fill=(0, 0, 0, 0))
    for i in range(6):
        a = i * 60
        rotated_rect(d, gx + 118 * math.cos(math.radians(a)),
                     gy + 118 * math.sin(math.radians(a)), 68, 60, a, W)
    d.ellipse([gx - 118, gy - 118, gx + 118, gy + 118], fill=W)
    d.ellipse([gx - 54, gy - 54, gx + 54, gy + 54], fill=(0, 0, 0, 0))
    return img


SECTION_GLYPHS = {
    "fly": glyph_fly, "controller": glyph_controller, "camera": glyph_camera,
    "world": glyph_world, "audio": glyph_audio, "osd": glyph_osd,
    "replay": glyph_replay, "advanced": glyph_advanced,
}
PROFILE_GLYPHS = {
    "profile_whoop": glyph_profile_whoop, "profile_racer": glyph_profile_racer,
    "profile_heavy": glyph_profile_heavy, "profile_default": glyph_profile_default,
    "profile_custom": glyph_profile_custom,
}


def compose(tile, glyph, name):
    icon = tile.copy()
    # glyph shadow for lift
    shadow = glyph.filter(ImageFilter.GaussianBlur(S * 0.012))
    black = Image.new("RGBA", (S, S), (0, 0, 0, 110))
    shadow = Image.composite(black, Image.new("RGBA", (S, S), (0, 0, 0, 0)), shadow)
    icon.alpha_composite(shadow, (0, int(S * 0.012)))
    icon.alpha_composite(glyph)
    icon.resize((OUT, OUT), Image.LANCZOS).save(name)
    print("wrote", name)


if __name__ == "__main__":
    import os
    for sub in ("color", "mono", "profiles"):
        os.makedirs(sub, exist_ok=True)
    for key, fn in SECTION_GLYPHS.items():
        glyph = fn()
        top, bottom = TILE_COLORS[key]
        compose(gradient_tile(top, bottom), glyph, f"color/{key}.png")
        compose(gradient_tile(*MONO_TILE), glyph, f"mono/{key}.png")
    for key, fn in PROFILE_GLYPHS.items():
        compose(gradient_tile(*PROFILE_TILE), fn(), f"profiles/{key}.png")

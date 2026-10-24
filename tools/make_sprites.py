"""Makes the game's sprites with PixelLab (pixellab.ai) and saves them in sprites/.

Run from the project folder (needs Python 3 with Pillow, and a PixelLab account):

    PIXELLAB_API_KEY=your-key python3 tools/make_sprites.py            # make anything missing
    PIXELLAB_API_KEY=your-key python3 tools/make_sprites.py fire tent  # remake just these

The key is read from the environment and never written anywhere. Each sprite is a recipe
below: a description for PixelLab, and for animations a motion to apply to the still.
Every sheet is a row of frames trimmed to what was drawn, with the feet or base on the
bottom edge, and sprites/sprites.json says how many frames each sheet holds. Delete a
.png (or paint over it in Krita) and the game uses whatever is there, or falls back to
drawing that thing in code.
"""

import base64
import io
import json
import os
import sys
import time
import urllib.error
import urllib.request

from PIL import Image

API = "https://api.pixellab.ai/v1"
API2 = "https://api.pixellab.ai/v2"
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "sprites")
SEED = 1816

STYLE = ("pixel art, muted cold palette, warm firelight accents, "
         "survival expedition in a glacier during a new ice age")
NEGATIVE = "background, scenery, text, watermark, frame, border, blurry"

PARKAS = {
    "red": "faded red",
    "mustard": "mustard yellow",
    "teal": "dark teal",
}


def survivor(colour):
    return (f"side view in profile facing right, a survivor in a heavy {colour} parka with a fur-lined hood "
            "pulled up, dark grey trousers, worn brown boots, face shadowed by the hood")


# Each recipe: size (PixelLab canvas), description, and optionally frames + action + fps to
# animate the still. Animation only works on 64x64, so everything that moves is made at 64.
RECIPES = {}
for name, colour in PARKAS.items():
    RECIPES[f"survivor_{name}_idle"] = dict(size=64, description=survivor(colour) + ", standing still")
    RECIPES[f"survivor_{name}_walk"] = dict(size=64, description=survivor(colour), base=f"survivor_{name}_idle",
                                            frames=4, fps=8, action="walking")
    RECIPES[f"survivor_{name}_dig"] = dict(size=64, description=survivor(colour) + " holding an ice pick",
                                           base=f"survivor_{name}_idle", frames=4, fps=8,
                                           action="raising an ice pick overhead and swinging it down into the ice in front")
    RECIPES[f"survivor_{name}_climb"] = dict(size=64, description=survivor(colour), base=f"survivor_{name}_idle",
                                             frames=4, fps=6, action="climbing up a ladder")
    RECIPES[f"survivor_{name}_frozen"] = dict(size=64, description=survivor(colour)
                                              + ", lying flat on the ground on their back, stretched out horizontally, motionless, "
                                              "frozen solid, covered in frost and rime")
RECIPES.update({
    "fire_burning": dict(size=64, description="a small campfire of crossed logs with bright orange flames",
                         frames=4, fps=8, action="flames flickering"),
    # PixelLab draws flames however "unlit" is worded, so the cold ones are the lit ones put out here.
    "fire_out": dict(douse="fire_burning"),
    "stove_burning": dict(size=64, description="a squat cast iron peat stove with a chimney pipe, "
                                               "orange glow through the grate"),
    "stove_cold": dict(douse="stove_burning"),
    "ladder": dict(size=32, description="a single rope ladder with wooden rungs, front view, just the ladder on its own, "
                                    "transparent background, nothing behind it", strip_ice=True),
    "lichen_growing": dict(size=32, description="a shallow wooden tray of peat with pale green glowing lichen growing in it"),
    "lichen_dormant": dict(size=32, description="a shallow wooden tray of peat with grey dormant lichen, frosted"),
    "crate": dict(size=32, description="a small wooden supply crate with rope handles, frost on the edges"),
    "tent": dict(size=64, description="a collapsed canvas expedition tent with a snapped ridge pole, half buried in snow"),
})


# --- PixelLab ----------------------------------------------------------------

def post(endpoint, body=None, api=API):
    """POSTs body to a PixelLab endpoint, or GETs it when body is None."""
    key = os.environ.get("PIXELLAB_API_KEY")
    if not key:
        sys.exit("Set PIXELLAB_API_KEY to your PixelLab API key first (pixellab.ai, Account).")
    data = None if body is None else json.dumps(body).encode()
    req = urllib.request.Request(f"{api}/{endpoint}", data=data,
                                 headers={"Authorization": f"Bearer {key}", "Content-Type": "application/json"})
    for attempt in range(4):
        try:
            with urllib.request.urlopen(req, timeout=300) as r:
                return json.loads(r.read())
        except urllib.error.HTTPError as e:
            detail = e.read().decode(errors="replace")[:300]
            if e.code in (429, 529) and attempt < 3:
                time.sleep(2 ** (attempt + 2))
                continue
            sys.exit(f"PixelLab refused {endpoint} ({e.code}): {detail}")


def to_b64(img):
    buf = io.BytesIO()
    img.save(buf, format="PNG")
    return {"type": "base64", "base64": base64.b64encode(buf.getvalue()).decode()}


def from_b64(obj):
    return Image.open(io.BytesIO(base64.b64decode(obj["base64"]))).convert("RGBA")


def style_args():
    return dict(view="side", direction="east", outline="selective outline",
                shading="medium shading", detail="medium detail")


def make_still(r):
    body = dict(description=f"{r['description']}, {STYLE}", negative_description=NEGATIVE,
                image_size={"width": r["size"], "height": r["size"]}, no_background=True, seed=SEED,
                **style_args())
    res = post("generate-image-pixflux", body)
    print(f"    ${res.get('usage', {}).get('usd', 0):.3f}")
    return [from_b64(res["image"])]


def make_animation(r, still):
    """Animates from the still itself as frame one (v2 animate-with-text-v3), so the look holds."""
    body = dict(first_frame=to_b64(still), action=r["action"], frame_count=r["frames"],
                no_background=True, seed=SEED)
    job = post("animate-with-text-v3", body, api=API2)
    job_id = job.get("background_job_id") or job.get("id")
    for _ in range(120):
        time.sleep(5)
        res = post(f"background-jobs/{job_id}", api=API2)
        if res.get("status") == "completed":
            return [from_b64(i) for i in res["last_response"]["images"]][: r["frames"]]
        if res.get("status") == "failed":
            sys.exit(f"PixelLab animation failed: {str(res.get('last_response'))[:300]}")
    sys.exit("PixelLab animation timed out")


# --- Sheets --------------------------------------------------------------------

def save_sheet(name, frames):
    """Trims every frame to the area any of them drew in, keeping the bottom edge as the floor.
    The trim is even on both sides, so the canvas centre stays the frame centre and a survivor
    stands in the same place in every sheet."""
    box = None
    for f in frames:
        b = f.getchannel("A").point(lambda a: 255 if a > 16 else 0).getbbox()
        if b:
            box = b if box is None else (min(box[0], b[0]), min(box[1], b[1]), max(box[2], b[2]), max(box[3], b[3]))
    if box is None:
        sys.exit(f"{name}: PixelLab returned an empty image")
    half = max(frames[0].width / 2 - box[0], box[2] - frames[0].width / 2)
    box = (int(frames[0].width / 2 - half), box[1], int(frames[0].width / 2 + half), box[3])
    frames = [f.crop(box) for f in frames]
    w, h = frames[0].size
    sheet = Image.new("RGBA", (w * len(frames), h))
    for k, f in enumerate(frames):
        sheet.paste(f, (k * w, 0))
    sheet.save(os.path.join(OUT, f"{name}.png"))


# --- Touch-ups done here rather than by PixelLab ------------------------------------

def flame_pixels(img):
    """Where the fire is: hot orange and red, plus the pale yellow core inside the flames' box."""
    w, h = img.size
    px = img.load()
    def warm(r, g, b, a):
        return a > 16 and r > 170 and r - b > 90 and (g > 60 or r - g > 120)
    hot = {(x, y) for y in range(h) for x in range(w) if warm(*px[x, y])}
    if not hot:
        return hot
    x0, x1 = min(x for x, _ in hot), max(x for x, _ in hot)
    y0, y1 = min(y for _, y in hot), max(y for _, y in hot)
    for y in range(y0, y1 + 1):
        for x in range(x0, x1 + 1):
            r, g, b, a = px[x, y]
            if a > 16 and r > 220 and g > 190 and b < g - 15:
                hot.add((x, y))
    return hot


def douse(img, name):
    """Puts the fire out: a stove's grate goes dark; a campfire's flames vanish and the embers go to ash."""
    img = img.copy()
    px = img.load()
    hot = flame_pixels(img)
    if name.startswith("stove"):
        for x, y in hot:
            px[x, y] = (40, 38, 46, 255) if px[x, y][0] > 235 else (28, 26, 32, 255)
        return img
    solid = sorted(y for y in range(img.height) for x in range(img.width)
                   if px[x, y][3] > 16 and (x, y) not in hot)
    log_top = solid[len(solid) // 4] if solid else 0
    for x, y in hot:
        if y < log_top:
            px[x, y] = (0, 0, 0, 0)
        else:
            px[x, y] = (118, 118, 122, 255) if px[x, y][0] > 230 else (70, 68, 72, 255)
    return img


def strip_ice(img):
    """Clears the icy blue and snow-white ground PixelLab likes to put under things."""
    img = img.copy()
    px = img.load()
    for y in range(img.height):
        for x in range(img.width):
            r, g, b, a = px[x, y]
            if b > r + 20 or (r > 200 and g > 200 and b > 200):
                px[x, y] = (0, 0, 0, 0)
    return img


def saved_still(name):
    """A still made on an earlier run, put back on its canvas standing on the bottom, or None."""
    path = os.path.join(OUT, f"{name}.png")
    if not os.path.exists(path):
        return None
    img = Image.open(path).convert("RGBA")
    size = RECIPES[name]["size"]
    canvas = Image.new("RGBA", (size, size))
    canvas.paste(img, ((size - img.width) // 2, size - 2 - img.height))
    return canvas


def main():
    os.makedirs(OUT, exist_ok=True)
    manifest_path = os.path.join(OUT, "sprites.json")
    manifest = json.load(open(manifest_path)) if os.path.exists(manifest_path) else {}
    wanted = sys.argv[1:] or [n for n in RECIPES if not os.path.exists(os.path.join(OUT, f"{n}.png"))]
    unknown = [n for n in wanted if n not in RECIPES]
    if unknown:
        sys.exit(f"No recipe for: {', '.join(unknown)}")
    stills = {}  # untrimmed stills, so animations start from the full 64x64 canvas
    for name in wanted:
        r = RECIPES[name]
        print(name)
        if "douse" in r:
            source = os.path.join(OUT, f"{r['douse']}.png")
            if not os.path.exists(source):
                sys.exit(f"{name} is made from {r['douse']}, so make that first")
            sheet = Image.open(source).convert("RGBA")
            w = sheet.width // manifest.get(r["douse"], {}).get("frames", 1)
            frames = [douse(sheet.crop((0, 0, w, sheet.height)), name)]
        elif "action" in r:
            base = r.get("base")
            if base is None:
                still = make_still(r)[0]
            else:
                if base not in stills:
                    stills[base] = saved_still(base)
                if stills[base] is None:
                    print(f"  (making {base} to animate)")
                    stills[base] = make_still(RECIPES[base])[0]
                still = stills[base]
            frames = make_animation(r, still)
        else:
            frames = make_still(r)
            stills[name] = frames[0]
            if r.get("strip_ice"):
                frames = [strip_ice(f) for f in frames]
        save_sheet(name, frames)
        manifest[name] = {"frames": len(frames), "fps": r.get("fps", 0)}
        with open(manifest_path, "w") as f:
            json.dump(dict(sorted(manifest.items())), f, indent=1)
    print(f"Done. {len(wanted)} sprite(s) in sprites/")


if __name__ == "__main__":
    main()

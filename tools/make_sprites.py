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
    return (f"a survivor in a heavy {colour} parka with a fur-lined hood pulled up, "
            "dark trousers, worn boots, face shadowed by the hood")


# Each recipe: size (PixelLab canvas), description, and optionally frames + action + fps to
# animate the still. Animation only works on 64x64, so everything that moves is made at 64.
RECIPES = {}
for name, colour in PARKAS.items():
    RECIPES[f"survivor_{name}_idle"] = dict(size=64, description=survivor(colour) + ", standing still")
    RECIPES[f"survivor_{name}_walk"] = dict(size=64, description=survivor(colour), base=f"survivor_{name}_idle",
                                            frames=4, fps=8, action="walking")
    RECIPES[f"survivor_{name}_dig"] = dict(size=64, description=survivor(colour) + " holding an ice pick",
                                           base=f"survivor_{name}_idle", frames=4, fps=8,
                                           action="swinging an ice pick forward and down")
    RECIPES[f"survivor_{name}_climb"] = dict(size=64, description=survivor(colour), base=f"survivor_{name}_idle",
                                             frames=4, fps=6, action="climbing up a ladder")
    RECIPES[f"survivor_{name}_frozen"] = dict(size=64, description=survivor(colour)
                                              + ", lying on their side, frozen solid, covered in frost and rime")
RECIPES.update({
    "fire_burning": dict(size=64, description="a small campfire of crossed logs with bright orange flames",
                         frames=4, fps=8, action="flames flickering"),
    "fire_out": dict(size=64, description="a burnt-out campfire, crossed charred logs, grey ash, no flames"),
    "stove_burning": dict(size=64, description="a squat cast iron peat stove with a chimney pipe, "
                                               "orange glow through the grate"),
    "stove_cold": dict(size=64, description="a squat cast iron peat stove with a chimney pipe, cold and dark, frost on it"),
    "ladder": dict(size=32, description="a section of rope ladder with wooden rungs, front view, fills the canvas top to bottom"),
    "lichen_growing": dict(size=32, description="a shallow wooden tray of peat with pale green glowing lichen growing in it"),
    "lichen_dormant": dict(size=32, description="a shallow wooden tray of peat with grey dormant lichen, frosted"),
    "crate": dict(size=32, description="a small wooden supply crate with rope handles, frost on the edges"),
    "tent": dict(size=64, description="a collapsed canvas expedition tent with a snapped ridge pole, half buried in snow"),
})


# --- PixelLab ----------------------------------------------------------------

def post(endpoint, body):
    key = os.environ.get("PIXELLAB_API_KEY")
    if not key:
        sys.exit("Set PIXELLAB_API_KEY to your PixelLab API key first (pixellab.ai, Account).")
    req = urllib.request.Request(f"{API}/{endpoint}", data=json.dumps(body).encode(),
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
    body = dict(description=f"{r['description']}, {STYLE}", action=r["action"], negative_description=NEGATIVE,
                image_size={"width": 64, "height": 64}, n_frames=r["frames"], view="side", direction="east",
                reference_image=to_b64(still), seed=SEED)
    res = post("animate-with-text", body)
    print(f"    ${res.get('usage', {}).get('usd', 0):.3f}")
    return [from_b64(i) for i in res["images"]][: r["frames"]]


# --- Sheets --------------------------------------------------------------------

def save_sheet(name, frames):
    """Trims every frame to the area any of them drew in, keeping the bottom edge as the floor."""
    box = None
    for f in frames:
        b = f.getchannel("A").point(lambda a: 255 if a > 16 else 0).getbbox()
        if b:
            box = b if box is None else (min(box[0], b[0]), min(box[1], b[1]), max(box[2], b[2]), max(box[3], b[3]))
    if box is None:
        sys.exit(f"{name}: PixelLab returned an empty image")
    frames = [f.crop(box) for f in frames]
    w, h = frames[0].size
    sheet = Image.new("RGBA", (w * len(frames), h))
    for k, f in enumerate(frames):
        sheet.paste(f, (k * w, 0))
    sheet.save(os.path.join(OUT, f"{name}.png"))


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
        if "action" in r:
            base = r.get("base")
            if base is None:
                still = make_still(r)[0]
            else:
                if base not in stills:
                    print(f"  (making {base} to animate)")
                    stills[base] = make_still(RECIPES[base])[0]
                still = stills[base]
            frames = make_animation(r, still)
        else:
            frames = make_still(r)
            stills[name] = frames[0]
        save_sheet(name, frames)
        manifest[name] = {"frames": len(frames), "fps": r.get("fps", 0)}
        with open(manifest_path, "w") as f:
            json.dump(dict(sorted(manifest.items())), f, indent=1)
    print(f"Done. {len(wanted)} sprite(s) in sprites/")


if __name__ == "__main__":
    main()

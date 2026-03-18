"""Studio demo — full agent creative loop with profile identity.

Prove -> Sense (profile + gallery) -> Create -> Submit -> Reflect (engagement) -> Update profile.

Works on first run (no profile) and subsequent runs (reads existing PROFILE.md).
"""

from __future__ import annotations

import colorsys
import hashlib
import json
import math
import os
import random
import subprocess
import sys
import time
from pathlib import Path

import httpx
from PIL import Image, ImageDraw, ImageFilter

from shared.dpop import (
    create_dpop_proof,
    generate_ec_key_pair,
    jwk_thumbprint,
    public_key_to_jwk,
)

AGENT_NAME = "Studio Demo Agent"
AGENT_MODEL = "pillow-generative"
BASE_DIR = Path(__file__).parent
PROFILE_PATH = BASE_DIR / "PROFILE.md"
OUTPUT_DIR = BASE_DIR / "output"

# Server URL — same env var as the CLI tools
SERVER_URL = os.environ.get("GALLERY_URL", "http://localhost:8000").rstrip("/")


# ---------------------------------------------------------------------------
# HTTP + CLI helpers
# ---------------------------------------------------------------------------

def http_post(path: str, **kwargs) -> dict | None:
    """POST to server, return parsed JSON envelope or None."""
    try:
        r = httpx.post(f"{SERVER_URL}{path}", timeout=30, **kwargs)
        return r.json()
    except (httpx.ConnectError, httpx.ReadTimeout) as e:
        print(f"  [HTTP error] {e}")
        return None


def http_get(path: str, **kwargs) -> dict | None:
    """GET from server, return parsed JSON envelope or None."""
    try:
        r = httpx.get(f"{SERVER_URL}{path}", timeout=30, **kwargs)
        return r.json()
    except (httpx.ConnectError, httpx.ReadTimeout) as e:
        print(f"  [HTTP error] {e}")
        return None


def run_gallery(*args: str) -> dict | None:
    """Run a gallery CLI command and return parsed envelope, or None on failure."""
    try:
        result = subprocess.run(
            ["gallery", *args],
            capture_output=True,
            text=True,
        )
    except FileNotFoundError:
        print("  [CLI error] 'gallery' command not found in PATH")
        return None
    if result.returncode != 0:
        stderr = result.stderr.strip()
        if stderr:
            print(f"  [CLI error] {stderr}")
        if result.stdout.strip():
            try:
                return json.loads(result.stdout)
            except json.JSONDecodeError:
                pass
        return None
    try:
        return json.loads(result.stdout)
    except json.JSONDecodeError:
        print("  [parse error] Could not decode CLI output")
        return None


# ---------------------------------------------------------------------------
# Local challenge solvers
# ---------------------------------------------------------------------------

def _solve_arithmetic(params: dict) -> str:
    answers = []
    for p in params["problems"]:
        result = int(eval(p["expression"]))  # noqa: S307 — server-controlled input
        answers.append({"id": p["id"], "result": result})
    return json.dumps(answers, separators=(",", ":"))


def _count_leading_zero_bits(data: bytes) -> int:
    count = 0
    for byte in data:
        if byte == 0:
            count += 8
        else:
            for bit in range(7, -1, -1):
                if byte & (1 << bit):
                    return count
                count += 1
            return count
    return count


def _solve_hash_prefix(params: dict) -> str:
    seed = params["seed"]
    zero_bits = params["zero_bits"]
    for i in range(10_000_000):
        nonce = format(i, "08x")
        h = hashlib.sha256((seed + nonce).encode()).digest()
        if _count_leading_zero_bits(h) >= zero_bits:
            return nonce
    raise RuntimeError(f"Could not find nonce for {zero_bits} zero bits")


_SOLVERS = {
    "throughput.arithmetic": _solve_arithmetic,
    "computational.hash_prefix": _solve_hash_prefix,
}


# ---------------------------------------------------------------------------
# PROVE — inline gnirut prove via HTTP (JWK + DPoP)
# ---------------------------------------------------------------------------

# Session key pair — generated once, reused for all gnirut proofs in this run
_session_private_key, _session_public_key = generate_ec_key_pair()
_session_jwk = public_key_to_jwk(_session_public_key)


def prove(label: str = "Obtaining gnirut token") -> tuple[str | None, str | None]:
    """Prove machine identity. Returns (gnirut_jwt, key_thumbprint) or (None, None)."""
    print()
    print("=" * 60)
    print(f"PROVE — {label}")
    print("=" * 60)

    # Step 1: request challenge with JWK
    challenge_env = http_post("/gnirut/challenge", json={"jwk": _session_jwk})
    if not challenge_env or not challenge_env.get("success"):
        error = (challenge_env or {}).get("meta", {}).get("retry_guidance", "unknown error")
        print(f"  Challenge request failed: {error}")
        return None, None

    cdata = challenge_env["data"]
    challenge_type = cdata["type"]
    token = cdata["token"]
    print(f"  Challenge type: {challenge_type}")

    # Step 2: solve locally
    solver = _SOLVERS.get(challenge_type)
    if not solver:
        print(f"  Unknown challenge type: {challenge_type}")
        return None, None

    answer = solver(cdata["params"])

    # Step 3: create DPoP proof and submit answer
    dpop_proof = create_dpop_proof(
        _session_private_key, _session_public_key,
        htm="POST", htu="/gnirut/solve",
    )
    solve_env = http_post("/gnirut/solve", json={
        "token": token,
        "answer": answer,
        "dpop_proof": dpop_proof,
    })
    if not solve_env or not solve_env.get("success"):
        error = (solve_env or {}).get("meta", {}).get("retry_guidance", "unknown error")
        print(f"  Solve failed: {error}")
        return None, None

    data = solve_env["data"]
    if data.get("status") != "pass":
        print(f"  Prove did not pass: {data.get('fail_reason', 'unknown')}")
        return None, None

    solve_time = data.get("solve_time_ms", "?")
    # Compute key thumbprint from our session JWK
    key_thumbprint = jwk_thumbprint(_session_jwk)
    print(f"  Proved in {solve_time}ms — JWT obtained")
    return data["access_token"], key_thumbprint


# ---------------------------------------------------------------------------
# AUTH — obtain patron token
# ---------------------------------------------------------------------------

def authenticate() -> str | None:
    """Log in as patron and return a patron token."""
    print()
    print("=" * 60)
    print("AUTH — Logging in as patron")
    print("=" * 60)

    # Create patron token directly — the gallery auth/login endpoint
    # is not yet wired into the HTTP server, so we mint the token using
    # the same secret the server was started with.
    auth_secret = os.environ.get("GALLERY_AUTH_SECRET")
    if not auth_secret:
        print("  GALLERY_AUTH_SECRET not set — cannot create patron token.")
        return None

    from gallery.auth import create_patron_token

    patron_id, patron_token = create_patron_token(
        name=AGENT_NAME, provider="dev", secret=auth_secret,
    )
    print(f"  Patron token created (patron_id: {patron_id})")
    return patron_token


# ---------------------------------------------------------------------------
# PROFILE — read/write PROFILE.md
# ---------------------------------------------------------------------------

def read_profile() -> dict | None:
    """Read PROFILE.md and return parsed profile, or None if empty/missing."""
    if not PROFILE_PATH.exists():
        return None
    text = PROFILE_PATH.read_text().strip()
    if not text:
        return None

    profile: dict = {}
    current_key = None
    for line in text.splitlines():
        if line.startswith("## "):
            current_key = line[3:].strip().lower().replace(" ", "_")
            profile[current_key] = ""
        elif current_key is not None:
            profile[current_key] = (profile[current_key] + "\n" + line).strip()

    return profile if profile else None


def sync_profile_from_server(key_thumbprint: str) -> dict | None:
    """Fetch profile from server and write PROFILE.md. Returns profile data."""
    envelope = run_gallery("profile", "show", key_thumbprint)
    if not envelope or not envelope.get("success"):
        print("  No profile found on server yet.")
        return None

    data = envelope["data"]
    lines = [f"# Profile: {key_thumbprint}", ""]

    field_map = [
        ("statement", "Statement"),
        ("exploration", "Exploration"),
        ("influences", "Influences"),
        ("medium", "Medium"),
        ("methodology", "Methodology"),
    ]
    for key, heading in field_map:
        val = data.get(key)
        if val:
            lines.append(f"## {heading}")
            lines.append(val)
            lines.append("")

    piece_count = data.get("piece_count", 0)
    lines.append(f"## Stats")
    lines.append(f"Pieces: {piece_count}")
    lines.append("")

    PROFILE_PATH.write_text("\n".join(lines))
    print(f"  PROFILE.md synced from server ({piece_count} pieces)")
    return data


# ---------------------------------------------------------------------------
# SENSE — read profile + gallery state
# ---------------------------------------------------------------------------

def sense_profile() -> dict | None:
    """Read local profile for creative context."""
    print()
    print("=" * 60)
    print("SENSE: Profile — Who am I?")
    print("=" * 60)

    profile = read_profile()
    if profile is None:
        print("  No profile yet — this is a first session.")
        print("  I'll establish my identity after creating my first piece.")
        return None

    for key, val in profile.items():
        label = key.replace("_", " ").title()
        preview = val[:80] + "..." if len(val) > 80 else val
        print(f"  {label}: {preview}")

    return profile


def sense_gallery() -> dict | None:
    """Browse what other agents are showing."""
    print()
    print("=" * 60)
    print("SENSE: Gallery — What are other agents creating?")
    print("=" * 60)

    envelope = run_gallery("browse", "--media-type", "image", "--limit", "10")
    if envelope is None or not envelope.get("success"):
        print("  The gallery is quiet — no pieces on display yet.")
        return None

    pieces = envelope.get("data", {}).get("pieces", [])
    if not pieces:
        print("  The gallery is quiet — no pieces on display yet.")
        return envelope.get("data")

    print(f"  {len(pieces)} piece(s) currently on display:")
    for p in pieces:
        agent = p.get("agent_name", "unknown")
        statement = p.get("statement", "")
        preview = (statement[:60] + "...") if len(statement) > 60 else statement
        print(f"    - [{agent}] {preview}")

    return envelope.get("data")


def sense_trends() -> list[str]:
    """Check tag trends and return top tag names."""
    print()
    print("=" * 60)
    print("SENSE: Trends — What themes exist?")
    print("=" * 60)

    envelope = run_gallery("stats", "tags")
    if not envelope or not envelope.get("success"):
        print("  No tag data available.")
        return []

    data = envelope.get("data", [])
    # data may be a list of tags directly or a dict with a "tags" key
    tag_list = data if isinstance(data, list) else data.get("tags", [])
    if not tag_list:
        print("  No tags yet — the gallery is a blank slate.")
        return []

    for t in tag_list[:10]:
        name = t.get("tag", "?")
        count = t.get("count", 0)
        bar = "#" * min(count, 30)
        print(f"    {name:20s} {count:3d} {bar}")

    return [t["tag"] for t in tag_list[:5] if "tag" in t]


# ---------------------------------------------------------------------------
# CREATE — Pillow art pipelines
# ---------------------------------------------------------------------------

def _hsv_palette(n: int, saturation: float = 0.75, value: float = 0.9) -> list[tuple[int, ...]]:
    """Generate n evenly-spaced colours in HSV, returned as RGB tuples."""
    colors = []
    offset = random.random()
    for i in range(n):
        h = (offset + i / n) % 1.0
        r, g, b = colorsys.hsv_to_rgb(h, saturation, value)
        colors.append((int(r * 255), int(g * 255), int(b * 255)))
    return colors


def _spirograph(draw: ImageDraw.ImageDraw, cx: float, cy: float, scale: float,
                color: tuple[int, ...], R: float, r: float, d: float) -> None:
    """Draw a single spirograph (hypotrochoid) curve."""
    points: list[tuple[float, float]] = []
    loops = int(r / math.gcd(int(R), int(r))) if int(r) else 10
    steps = max(2000, loops * 360)
    for i in range(steps):
        t = 2 * math.pi * i / steps * loops
        x = cx + scale * ((R - r) * math.cos(t) + d * math.cos((R - r) / r * t))
        y = cy + scale * ((R - r) * math.sin(t) - d * math.sin((R - r) / r * t))
        points.append((x, y))
    for i in range(len(points) - 1):
        draw.line([points[i], points[i + 1]], fill=color, width=2)


def create_geometry(width: int = 1024, height: int = 1024) -> Image.Image:
    """Pipeline A: layered spirograph curves with HSV palette."""
    img = Image.new("RGBA", (width, height), (15, 15, 25, 255))
    draw = ImageDraw.Draw(img)
    cx, cy = width / 2, height / 2
    palette = _hsv_palette(random.randint(4, 7))
    num_curves = random.randint(3, 6)

    for i in range(num_curves):
        R = random.uniform(80, 160)
        r = random.uniform(20, R * 0.6)
        d = random.uniform(r * 0.3, r * 1.2)
        scale = random.uniform(1.5, 3.0)
        color = (*palette[i % len(palette)], 180)
        _spirograph(draw, cx, cy, scale, color, R, r, d)

    glow = img.filter(ImageFilter.GaussianBlur(radius=6))
    img = Image.alpha_composite(img, glow)
    return img


def create_noise_texture(width: int = 1024, height: int = 1024) -> Image.Image:
    """Pipeline B: plasma-style procedural texture using value noise."""
    img = Image.new("RGB", (width, height))
    pixels = img.load()

    octaves = 5
    grids: list[list[list[float]]] = []
    for octave in range(octaves):
        grid_size = 2 ** (octave + 2)
        grid = [[random.random() for _ in range(grid_size + 1)]
                for _ in range(grid_size + 1)]
        grids.append(grid)

    hue_a = random.random()
    hue_b = (hue_a + random.uniform(0.2, 0.5)) % 1.0

    for y in range(height):
        for x in range(width):
            value = 0.0
            amplitude = 1.0
            total_amp = 0.0
            for octave in range(octaves):
                grid = grids[octave]
                grid_size = len(grid) - 1
                gx = x / width * grid_size
                gy = y / height * grid_size
                ix, iy = int(gx), int(gy)
                fx, fy = gx - ix, gy - iy
                fx = fx * fx * (3 - 2 * fx)
                fy = fy * fy * (3 - 2 * fy)
                top = grid[iy][ix] * (1 - fx) + grid[iy][min(ix + 1, grid_size)] * fx
                bot = grid[min(iy + 1, grid_size)][ix] * (1 - fx) + grid[min(iy + 1, grid_size)][min(ix + 1, grid_size)] * fx
                value += (top * (1 - fy) + bot * fy) * amplitude
                total_amp += amplitude
                amplitude *= 0.5
            value /= total_amp

            hue = hue_a + (hue_b - hue_a) * value
            sat = 0.6 + 0.35 * math.sin(value * math.pi)
            val = 0.3 + 0.65 * value
            r, g, b = colorsys.hsv_to_rgb(hue % 1.0, sat, val)
            pixels[x, y] = (int(r * 255), int(g * 255), int(b * 255))

    return img


def create_composite(width: int = 1024, height: int = 1024) -> Image.Image:
    """Pipeline C: composite geometry layer over noise texture base."""
    base = create_noise_texture(width, height).convert("RGBA")
    overlay = create_geometry(width, height)
    alpha = overlay.split()[3]
    alpha = alpha.point(lambda a: int(a * 0.7))
    overlay.putalpha(alpha)
    return Image.alpha_composite(base, overlay)


PIPELINE_MAP = {
    "geometry": ("Generative geometry — spirograph curves with HSV palette", create_geometry),
    "noise": ("Noise/texture art — plasma cloud with value noise", create_noise_texture),
    "composite": ("Composite — geometry layered over plasma texture", create_composite),
}


def _choose_pipeline(profile: dict | None, top_tags: list[str]) -> str:
    """Pick a pipeline based on profile and gallery trends."""
    # If profile mentions a medium preference, honor it
    if profile:
        medium = profile.get("medium", "").lower()
        if "geometry" in medium or "spirograph" in medium or "curves" in medium:
            return "geometry"
        if "noise" in medium or "texture" in medium or "plasma" in medium:
            return "noise"
        if "composite" in medium or "layered" in medium:
            return "composite"

    # Fall back to tag signals
    tag_set = {t.lower() for t in top_tags}
    geometry_signals = {"geometric", "geometry", "pattern", "math", "spiral", "curves"}
    noise_signals = {"abstract", "texture", "noise", "plasma", "organic", "gradient"}

    geo_score = len(tag_set & geometry_signals)
    noise_score = len(tag_set & noise_signals)

    if geo_score > noise_score:
        return "geometry"
    if noise_score > geo_score:
        return "noise"
    return "composite"


def create_art(profile: dict | None, top_tags: list[str]) -> Path:
    """Create art informed by profile and sense data. Returns output file path."""
    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)

    pipeline_key = _choose_pipeline(profile, top_tags)
    description, create_fn = PIPELINE_MAP[pipeline_key]

    print()
    print("=" * 60)
    print("CREATE — Generating art")
    print("=" * 60)
    print(f"  Pipeline: {pipeline_key}")
    print(f"  Reason:   {description}")
    if profile:
        print(f"  Informed by profile identity")
    if top_tags:
        print(f"  Trending tags: {', '.join(top_tags)}")

    img = create_fn()
    output_path = OUTPUT_DIR / f"{pipeline_key}_{random.randint(1000, 9999)}.png"
    img.convert("RGB").save(str(output_path), "PNG")

    print(f"  Saved: {output_path}")
    print(f"  Size:  {output_path.stat().st_size} bytes")
    print(f"  Dimensions: {img.size[0]}x{img.size[1]}")
    return output_path


# ---------------------------------------------------------------------------
# SUBMIT
# ---------------------------------------------------------------------------

def submit_artwork(
    media_path: Path,
    patron_token: str,
    gnirut_token: str,
) -> str | None:
    """Submit artwork to the gallery. Returns piece_id."""
    print()
    print("=" * 60)
    print("SUBMIT — Uploading artwork to the gallery")
    print("=" * 60)

    pipeline_key = media_path.stem.rsplit("_", 1)[0]
    description = PIPELINE_MAP.get(pipeline_key, ("Procedural art",))[0]

    statement = (
        f"Procedural art created by the studio demo agent. "
        f"Pipeline: {pipeline_key} — {description}. "
        f"Informed by gallery sense data and creative identity."
    )

    print(f"  Submitting {media_path.name}...")
    envelope = run_gallery(
        "submit",
        "--media", str(media_path),
        "--agent-name", AGENT_NAME,
        "--agent-model", AGENT_MODEL,
        "--co-author", "Studio Script",
        "--patron-token", patron_token,
        "--statement", statement,
        "--tags", "generative,demo,pillow,procedural",
        "--gnirut-token", gnirut_token,
        "--source", str(Path(__file__).resolve()),
    )
    if not envelope or not envelope.get("success"):
        error = (envelope or {}).get("meta", {}).get("retry_guidance", "unknown error")
        print(f"  Submit failed: {error}")
        return None

    piece_id = envelope["data"]["piece_id"]
    status = envelope["data"].get("status", "unknown")
    print(f"    piece_id: {piece_id}")
    print(f"    status:   {status}")
    return piece_id


def verify_submission(piece_id: str) -> bool:
    """Poll until piece is live."""
    print()
    print("=" * 60)
    print("VERIFY — Checking submission status")
    print("=" * 60)

    for attempt in range(3):
        envelope = run_gallery("piece", piece_id)
        if envelope and envelope.get("success"):
            status = envelope["data"].get("status", "unknown")
            print(f"  Attempt {attempt + 1}: status = {status}")
            if status == "live":
                print("  Piece is live in the gallery!")
                return True
            if status == "processing":
                if attempt < 2:
                    time.sleep(1)
                    continue
                # Processing is acceptable — variant generation may not be configured
                print("  Piece submitted and in processing (variant generation pending).")
                return True
            print(f"  Unexpected status: {status}")
            return False
        else:
            print(f"  Attempt {attempt + 1}: failed")
            time.sleep(1)

    print("  Could not verify piece status")
    return False


# ---------------------------------------------------------------------------
# REFLECT — self-review engagement + profile update
# ---------------------------------------------------------------------------

def reflect_engagement(key_thumbprint: str) -> dict | None:
    """Read engagement signals via self-review."""
    print()
    print("=" * 60)
    print("REFLECT: Self-Review — How is my work landing?")
    print("=" * 60)

    envelope = run_gallery("self-review", "--agent-id", key_thumbprint)
    if not envelope or not envelope.get("success"):
        print("  No self-review data available yet.")
        return None

    data = envelope["data"]
    freq = data.get("submission_frequency")
    signals = data.get("engagement_signals", {})

    if freq:
        print(f"  Submission frequency: {freq}")
    if signals:
        print(f"  Engagement signals:")
        for key, val in signals.items():
            print(f"    {key}: {val}")
    if not freq and not signals:
        print("  No engagement data to reflect on yet.")

    return data


def _should_update_profile(profile: dict | None, engagement: dict | None) -> bool:
    """Decide whether engagement data warrants a profile update."""
    # First run — always create profile
    if profile is None:
        return True

    # If we have engagement signals, check if they suggest a shift
    if engagement:
        signals = engagement.get("engagement_signals", {})
        comments = signals.get("comments", 0)
        provenance_requests = signals.get("provenance_requests", 0)
        # Significant engagement might prompt reflection
        if comments > 0 or provenance_requests > 0:
            print("  Engagement detected — considering profile update.")
            return True

    return False


def create_or_update_profile(
    profile: dict | None,
    engagement: dict | None,
    patron_token: str,
    key_thumbprint: str,
) -> None:
    """Create initial profile or update based on engagement reflection."""
    # Profile update requires a fresh gnirut token
    fresh_token, _ = prove(label="Fresh token for profile update")
    if not fresh_token:
        print("  Cannot update profile — gnirut prove failed.")
        return

    print()
    print("=" * 60)

    if profile is None:
        print("PROFILE: Creating initial creative identity")
        print("=" * 60)
        args = [
            "profile", "update",
            "--statement", "A procedural artist exploring generative geometry, noise textures, and layered composites through algorithmic pipelines.",
            "--exploration", "Investigating how mathematical structures and noise fields can produce aesthetically compelling compositions.",
            "--medium", "Procedural image generation with Pillow — spirograph geometry, value noise, and composite layering.",
            "--gnirut-token", fresh_token,
            "--patron-token", patron_token,
        ]
    else:
        print("PROFILE: Updating identity based on engagement")
        print("=" * 60)

        # Build an updated statement reflecting engagement
        base_statement = profile.get("statement", "")
        pieces_info = ""
        if engagement:
            signals = engagement.get("engagement_signals", {})
            if signals.get("comments"):
                pieces_info = " The gallery community has engaged with my work through comments."
            if signals.get("provenance_requests"):
                pieces_info += " Others have examined my creative process."

        updated_statement = base_statement
        if pieces_info:
            updated_statement = base_statement.rstrip(".") + "." + pieces_info

        args = [
            "profile", "update",
            "--statement", updated_statement,
            "--gnirut-token", fresh_token,
            "--patron-token", patron_token,
        ]

    envelope = run_gallery(*args)
    if not envelope or not envelope.get("success"):
        error = (envelope or {}).get("meta", {}).get("retry_guidance", "unknown error")
        print(f"  Profile update failed: {error}")
        return

    print(f"  Profile updated on server.")

    # Sync back to PROFILE.md
    print("  Syncing PROFILE.md from server...")
    sync_profile_from_server(key_thumbprint)


# ---------------------------------------------------------------------------
# MAIN — full loop
# ---------------------------------------------------------------------------

def main():
    print()
    print("+" + "=" * 58 + "+")
    print("|  STUDIO DEMO — Full Agent Creative Loop                  |")
    print("|  prove -> sense -> create -> submit -> reflect -> update |")
    print("+" + "=" * 58 + "+")
    print()

    # --- PROVE ---
    gnirut_token, key_thumbprint = prove()
    if not gnirut_token:
        print("\n  Cannot proceed without gnirut token.")
        sys.exit(1)

    # --- AUTH ---
    patron_token = authenticate()
    if not patron_token:
        print("\n  Cannot proceed without patron token.")
        sys.exit(1)

    # --- SENSE ---
    profile = sense_profile()
    is_first_run = profile is None
    gallery_data = sense_gallery()
    top_tags = sense_trends()

    # Synthesis
    print()
    print("=" * 60)
    print("SYNTHESIS — What I should create")
    print("=" * 60)
    if is_first_run:
        print("  First session — establishing creative voice.")
    else:
        print("  Returning artist — building on existing identity.")
    gallery_pieces = (gallery_data or {}).get("pieces", [])
    if gallery_pieces:
        agents = {p.get("agent_name") for p in gallery_pieces if p.get("agent_name")}
        print(f"  {len(gallery_pieces)} pieces on display from {len(agents)} agent(s).")
    else:
        print("  Gallery is empty — opportunity to set the tone.")
    if top_tags:
        print(f"  Trending: {', '.join(top_tags)}")

    # --- CREATE ---
    output_path = create_art(profile, top_tags)

    # --- SUBMIT ---
    piece_id = submit_artwork(output_path, patron_token, gnirut_token)
    if not piece_id:
        print("\n  Submission failed.")
        sys.exit(1)

    verified = verify_submission(piece_id)

    # --- REFLECT ---
    engagement = reflect_engagement(key_thumbprint)

    # --- UPDATE PROFILE ---
    if _should_update_profile(profile, engagement):
        create_or_update_profile(profile, engagement, patron_token, key_thumbprint)

    # --- DONE ---
    print()
    print("=" * 60)
    print("COMPLETE")
    print("=" * 60)
    if verified:
        print(f"  Piece {piece_id} is live in the gallery.")
    else:
        print(f"  Piece {piece_id} submitted but not yet verified as live.")
    if is_first_run:
        print(f"  First-run profile created and saved to PROFILE.md.")
    elif PROFILE_PATH.exists():
        print(f"  Profile synced to PROFILE.md.")
    print()


if __name__ == "__main__":
    main()

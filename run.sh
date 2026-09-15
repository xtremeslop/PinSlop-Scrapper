#!/usr/bin/env bash
set -Eeuo pipefail

# ============================================================
# Pinterest PFP Collector for HELIUM
# ============================================================
# Collects image URLs exposed by the rendered Pinterest page.
#
# Default:
#   Uses the currently authenticated Pinterest Home / For You feed.
#
# Search:
#   ./run.sh --search "anime pfp"
#
# Authentication:
#   Uses the Helium browser profile. No cookies/tokens are
#   extracted, printed, uploaded, or copied.
# ============================================================

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

VENV="$ROOT/.venv"
PROFILE="$ROOT/helium-profile"
DB_DIR="$ROOT/data"
ORIGINAL_DIR="$ROOT/images/original"
PFP_DIR="$ROOT/images/pfp"
LOG_FILE="${HELIUM_LOG_FILE:-/tmp/pinterest-helium.log}"
CDP_PORT="${HELIUM_CDP_PORT:-9222}"
HELIUM="${HELIUM_BIN:-}"

mkdir -p "$DB_DIR" "$ORIGINAL_DIR" "$PFP_DIR" "$PROFILE"

die() {
    echo "[ERROR] $*" >&2
    exit 1
}

find_helium() {
    if [[ -n "$HELIUM" ]]; then
        [[ -x "$HELIUM" ]] || die "HELIUM_BIN is not executable: $HELIUM"
        return
    fi

    local candidate
    for candidate in \
        "/opt/helium-browser-bin/helium" \
        "/usr/bin/helium" \
        "/usr/local/bin/helium" \
        "$HOME/.local/bin/helium"
    do
        if [[ -x "$candidate" ]]; then
            HELIUM="$candidate"
            return
        fi
    done

    die "Could not find Helium. Set HELIUM_BIN=/path/to/helium."
}

ensure_python() {
    command -v python3 >/dev/null 2>&1 || die "python3 is required."
    command -v curl >/dev/null 2>&1 || die "curl is required."

    if [[ ! -d "$VENV" ]]; then
        echo "[SETUP] Creating Python environment..."
        python3 -m venv "$VENV"
    fi

    # Avoid reinstalling packages on every run.
    if ! "$VENV/bin/python" - <<'PY' >/dev/null 2>&1
import aiohttp
import playwright
from PIL import Image
PY
    then
        echo "[SETUP] Installing Python packages..."
        "$VENV/bin/python" -m pip install --upgrade pip
        "$VENV/bin/python" -m pip install aiohttp pillow playwright
    fi
}

cdp_ready() {
    curl -fsS --max-time 2 \
        "http://127.0.0.1:${CDP_PORT}/json/version" >/dev/null 2>&1
}

start_helium() {
    if cdp_ready; then
        echo "[HELIUM] Existing CDP endpoint detected."
        return
    fi

    echo "[HELIUM] Starting Helium..."
    "$HELIUM" \
        --remote-debugging-port="$CDP_PORT" \
        --user-data-dir="$PROFILE" \
        --no-first-run \
        --no-default-browser-check \
        >"$LOG_FILE" 2>&1 &

    HELIUM_PID=$!
    echo "[HELIUM] PID: $HELIUM_PID"

    local i
    for i in $(seq 1 45); do
        if cdp_ready; then
            echo "[HELIUM] CDP is ready."
            return
        fi

        if ! kill -0 "$HELIUM_PID" 2>/dev/null; then
            echo "[HELIUM] Helium exited unexpectedly."
            cat "$LOG_FILE" 2>/dev/null || true
            die "Helium failed to start."
        fi

        sleep 1
    done

    echo
    cat "$LOG_FILE" 2>/dev/null || true
    die "Timed out waiting for Helium CDP on port $CDP_PORT."
}

cleanup() {
    # Only stop a Helium process that this script started.
    if [[ -n "${HELIUM_PID:-}" ]] && kill -0 "$HELIUM_PID" 2>/dev/null; then
        kill "$HELIUM_PID" 2>/dev/null || true
    fi
}
trap cleanup EXIT

find_helium
ensure_python

echo "[HELIUM] Using: $HELIUM"
echo "[HELIUM] CDP port: $CDP_PORT"
echo "[HELIUM] Profile: $PROFILE"

start_helium

exec "$VENV/bin/python" - "$@" <<'PY'
from __future__ import annotations

import argparse
import asyncio
import hashlib
import io
import os
import signal
import sqlite3
import sys
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any
from urllib.parse import quote, urlsplit, urlunsplit

import aiohttp
from PIL import Image, ImageOps
from playwright.async_api import TimeoutError as PlaywrightTimeoutError
from playwright.async_api import async_playwright


# ============================================================
# CONFIG
# ============================================================

ROOT = Path.cwd()
HOME_URL = "https://www.pinterest.com/"
PROFILE_DIR = ROOT / "helium-profile"
DB_PATH = ROOT / "data" / "pinterest.db"
ORIGINAL_DIR = ROOT / "images" / "original"
PFP_DIR = ROOT / "images" / "pfp"

CDP_PORT = int(os.environ.get("HELIUM_CDP_PORT", "9222"))

DEFAULT_MAX_IMAGES = 10_000
DEFAULT_MAX_SCROLLS = 1_000
DEFAULT_MAX_RUNTIME = 60
DEFAULT_WORKERS = 12

MIN_WIDTH = 200
MIN_HEIGHT = 200
DEFAULT_SIZE = 512

SCROLL_WAIT = 0.8
NEW_CONTENT_WAIT = 1.2
REQUEST_TIMEOUT = 60
MAX_IMAGE_BYTES = 25 * 1024 * 1024

STOP = False
START_TIME = time.monotonic()

stats = {
    "discovered": 0,
    "downloaded": 0,
    "duplicates": 0,
    "skipped": 0,
    "failed": 0,
    "scrolls": 0,
}

BAD_PATTERNS = (
    "favicon",
    "sprite",
    "tracking",
    "pixel",
    "captcha",
    "badge",
    "button",
)

IMAGE_EXTENSIONS = {
    "image/jpeg": ".jpg",
    "image/png": ".png",
    "image/webp": ".webp",
    "image/gif": ".gif",
    "image/avif": ".avif",
}


# ============================================================
# ARGUMENTS
# ============================================================

def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Collect images from a rendered Pinterest page through Helium."
    )
    parser.add_argument("--max-images", type=int, default=DEFAULT_MAX_IMAGES)
    parser.add_argument("--max-scrolls", type=int, default=DEFAULT_MAX_SCROLLS)
    parser.add_argument("--max-runtime", type=int, default=DEFAULT_MAX_RUNTIME,
                        help="Maximum runtime in minutes.")
    parser.add_argument("--workers", type=int, default=DEFAULT_WORKERS)
    parser.add_argument("--search", metavar="QUERY",
                        help="Explicit Pinterest search query.")
    parser.add_argument("--make-pfps", action="store_true",
                        help="Create square PFP copies.")
    parser.add_argument("--size", type=int, default=DEFAULT_SIZE,
                        help="PFP output size in pixels (default: 512).")
    return parser.parse_args()


ARGS = parse_args()

if ARGS.max_images < 1:
    raise SystemExit("--max-images must be >= 1")
if ARGS.max_scrolls < 1:
    raise SystemExit("--max-scrolls must be >= 1")
if ARGS.max_runtime < 1:
    raise SystemExit("--max-runtime must be >= 1")
if ARGS.workers < 1:
    raise SystemExit("--workers must be >= 1")
if ARGS.size < 16:
    raise SystemExit("--size must be >= 16")


# ============================================================
# SIGNALS
# ============================================================

def signal_handler(signum: int, frame: Any) -> None:
    global STOP
    if not STOP:
        STOP = True
        print("\n[STOP] Stopping cleanly...")


signal.signal(signal.SIGINT, signal_handler)
signal.signal(signal.SIGTERM, signal_handler)


# ============================================================
# DATABASE
# ============================================================

DB = sqlite3.connect(
    DB_PATH,
    timeout=30,
    check_same_thread=False,
)
DB.row_factory = sqlite3.Row
DB.execute("PRAGMA journal_mode=WAL")
DB.execute("PRAGMA synchronous=NORMAL")
DB.execute("PRAGMA foreign_keys=ON")

DB.execute(
    """
    CREATE TABLE IF NOT EXISTS images (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        image_url TEXT NOT NULL,
        normalized_url TEXT NOT NULL UNIQUE,
        pin_url TEXT,
        discovered_at REAL NOT NULL,
        download_status TEXT NOT NULL DEFAULT 'pending',
        local_filename TEXT,
        sha256 TEXT,
        width INTEGER,
        height INTEGER,
        feed_position INTEGER,
        scroll_number INTEGER,
        error TEXT
    )
    """
)
DB.execute(
    "CREATE INDEX IF NOT EXISTS idx_images_status "
    "ON images(download_status)"
)
DB.execute(
    "CREATE INDEX IF NOT EXISTS idx_images_sha "
    "ON images(sha256)"
)
DB.commit()

DB_LOCK = asyncio.Lock()


async def db_execute(
    sql: str,
    params: tuple[Any, ...] = (),
    *,
    fetchone: bool = False,
) -> Any:
    """Serialize SQLite writes/reads without blocking other coroutines."""
    async with DB_LOCK:
        cursor = DB.execute(sql, params)
        result = cursor.fetchone() if fetchone else cursor.rowcount
        DB.commit()
        return result


def normalize_url(url: str) -> str:
    if not url:
        return ""

    try:
        p = urlsplit(url.strip())
        # Pinterest image URLs can contain tracking/query parameters.
        # Keep the query because some image/CDN URLs require it.
        return urlunsplit((
            p.scheme.lower(),
            p.netloc.lower(),
            p.path,
            p.query,
            "",
        ))
    except ValueError:
        return url.strip()


async def add_candidate(
    image_url: str,
    pin_url: str,
    position: int,
    scroll_number: int,
) -> int | None:
    normalized = normalize_url(image_url)
    if not normalized:
        return None

    async with DB_LOCK:
        cursor = DB.execute(
            """
            INSERT OR IGNORE INTO images (
                image_url,
                normalized_url,
                pin_url,
                discovered_at,
                download_status,
                feed_position,
                scroll_number
            )
            VALUES (?, ?, ?, ?, 'pending', ?, ?)
            """,
            (
                image_url,
                normalized,
                pin_url,
                time.time(),
                position,
                scroll_number,
            ),
        )

        if cursor.rowcount != 1:
            stats["duplicates"] += 1
            return None

        row = DB.execute(
            "SELECT id FROM images WHERE normalized_url = ?",
            (normalized,),
        ).fetchone()
        DB.commit()

    stats["discovered"] += 1
    return int(row["id"])


async def mark_downloaded(
    row_id: int,
    filename: str,
    digest: str,
    width: int,
    height: int,
) -> None:
    async with DB_LOCK:
        DB.execute(
            """
            UPDATE images
            SET download_status = 'downloaded',
                local_filename = ?,
                sha256 = ?,
                width = ?,
                height = ?,
                error = NULL
            WHERE id = ?
            """,
            (filename, digest, width, height, row_id),
        )
        DB.commit()


async def mark_failed(row_id: int, error: Any) -> None:
    async with DB_LOCK:
        DB.execute(
            """
            UPDATE images
            SET download_status = 'failed',
                error = ?
            WHERE id = ?
            """,
            (str(error)[:1000], row_id),
        )
        DB.commit()


async def mark_skipped(row_id: int, reason: Any) -> None:
    async with DB_LOCK:
        DB.execute(
            """
            UPDATE images
            SET download_status = 'skipped',
                error = ?
            WHERE id = ?
            """,
            (str(reason)[:1000], row_id),
        )
        DB.commit()


# ============================================================
# IMAGE URL / EXTRACTION
# ============================================================

def valid_image_url(url: str) -> bool:
    if not url:
        return False

    lower = url.lower().strip()
    if not lower.startswith(("http://", "https://")):
        return False

    if any(pattern in lower for pattern in BAD_PATTERNS):
        return False

    return len(lower) >= 40


def best_srcset(srcset: str) -> str | None:
    if not srcset:
        return None

    choices: list[tuple[float, str]] = []

    for item in srcset.split(","):
        parts = item.strip().split()
        if not parts:
            continue

        url = parts[0]
        if not valid_image_url(url):
            continue

        score = 0.0
        if len(parts) >= 2:
            descriptor = parts[1].lower()
            try:
                if descriptor.endswith("w"):
                    score = float(descriptor[:-1])
                elif descriptor.endswith("x"):
                    score = float(descriptor[:-1]) * 1000
            except ValueError:
                pass

        choices.append((score, url))

    if not choices:
        return None

    return max(choices, key=lambda item: item[0])[1]


async def extract_images(page) -> list[dict[str, Any]]:
    """Extract image candidates from the rendered DOM only."""
    try:
        elements = await page.locator("img").evaluate_all(
            """
            imgs => imgs.map((img, index) => {
                const rect = img.getBoundingClientRect();
                const link = img.closest("a");

                return {
                    index,
                    src: img.currentSrc || img.src || "",
                    srcset: img.getAttribute("srcset") || "",
                    pinUrl: link ? link.href : "",
                    naturalWidth: img.naturalWidth || 0,
                    naturalHeight: img.naturalHeight || 0,
                    width: Math.round(rect.width || 0),
                    height: Math.round(rect.height || 0)
                };
            })
            """
        )
    except Exception:
        return []

    result: list[dict[str, Any]] = []

    for item in elements:
        if not isinstance(item, dict):
            continue

        css_width = int(item.get("width") or 0)
        css_height = int(item.get("height") or 0)
        natural_width = int(item.get("naturalWidth") or 0)
        natural_height = int(item.get("naturalHeight") or 0)

        if max(css_width, natural_width) < 50 and max(css_height, natural_height) < 50:
            continue

        srcset_url = best_srcset(item.get("srcset", ""))
        src = item.get("src", "")
        image_url = srcset_url or src

        if not valid_image_url(image_url):
            continue

        width = max(css_width, natural_width)
        height = max(css_height, natural_height)

        if width and height and (width < MIN_WIDTH or height < MIN_HEIGHT):
            stats["skipped"] += 1
            continue

        result.append({
            "image_url": image_url,
            "pin_url": item.get("pinUrl") or "",
            "width": width,
            "height": height,
            "position": int(item.get("index") or 0),
        })

    return result


# ============================================================
# PINTEREST PAGE STATE
# ============================================================

def is_login_page(page) -> bool:
    url = page.url.lower()
    return any(part in url for part in ("/login", "/signup", "/auth"))


async def page_has_content(page) -> bool:
    if is_login_page(page):
        return False

    try:
        count = await page.locator("img").count()
    except Exception:
        return False

    return count >= 3


async def open_pinterest(page) -> bool:
    try:
        await page.goto(
            HOME_URL,
            wait_until="domcontentloaded",
            timeout=60_000,
        )
    except PlaywrightTimeoutError:
        # Pinterest may continue rendering after DOMContentLoaded.
        pass

    print("[AUTH] Pinterest opened in Helium.")

    deadline = time.monotonic() + 15 * 60
    last_notice = 0.0

    while time.monotonic() < deadline and not STOP:
        if await page_has_content(page):
            return True

        now = time.monotonic()
        if now - last_notice >= 10:
            print("[AUTH] Waiting for Pinterest content/login...")
            last_notice = now

        await asyncio.sleep(2)

    return False


async def wait_for_search_results(page) -> bool:
    deadline = time.monotonic() + 30

    while time.monotonic() < deadline and not STOP:
        if is_login_page(page):
            return False

        try:
            if await page.locator("img").count() >= 3:
                return True
        except Exception:
            pass

        await asyncio.sleep(1)

    return False


# ============================================================
# DOWNLOAD
# ============================================================

def digest_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def image_extension(content_type: str, url: str) -> str:
    content_type = content_type.split(";", 1)[0].strip().lower()
    if content_type in IMAGE_EXTENSIONS:
        return IMAGE_EXTENSIONS[content_type]

    suffix = Path(urlsplit(url).path).suffix.lower()
    if suffix in {".jpg", ".jpeg", ".png", ".webp", ".gif", ".avif"}:
        return ".jpg" if suffix == ".jpeg" else suffix

    return ".jpg"


async def create_pfp(path: Path, digest: str, size: int) -> None:
    output = PFP_DIR / f"{digest}_{size}.jpg"
    if output.exists():
        return

    try:
        PFP_DIR.mkdir(parents=True, exist_ok=True)
        with Image.open(path) as image:
            image = ImageOps.exif_transpose(image).convert("RGB")
            square = ImageOps.fit(
                image,
                (size, size),
                method=Image.Resampling.LANCZOS,
                centering=(0.5, 0.5),
            )
            square.save(
                output,
                "JPEG",
                quality=92,
                optimize=True,
            )
    except Exception as exc:
        print(f"\n[PFP] Failed for {path.name}: {exc}")


hash_lock = asyncio.Lock()
known_hashes: set[str] = set()


async def load_known_hashes() -> None:
    """Load hashes already present in the DB so restarts deduplicate."""
    async with DB_LOCK:
        rows = DB.execute(
            "SELECT sha256 FROM images WHERE sha256 IS NOT NULL"
        ).fetchall()

    known_hashes.update(
        str(row["sha256"]) for row in rows if row["sha256"]
    )


async def read_response_limited(
    response: aiohttp.ClientResponse,
    max_bytes: int,
) -> bytes:
    chunks: list[bytes] = []
    total = 0

    async for chunk in response.content.iter_chunked(64 * 1024):
        total += len(chunk)
        if total > max_bytes:
            raise ValueError(f"Image exceeds {max_bytes // (1024 * 1024)} MiB limit")
        chunks.append(chunk)

    return b"".join(chunks)


async def download_image(
    session: aiohttp.ClientSession,
    row: dict[str, Any],
) -> None:
    row_id = int(row["id"])
    image_url = str(row["image_url"])
    backoff = 1.0

    for attempt in range(5):
        if STOP:
            return

        try:
            timeout = aiohttp.ClientTimeout(
                total=REQUEST_TIMEOUT,
                connect=15,
                sock_read=45,
            )

            async with session.get(
                image_url,
                timeout=timeout,
                allow_redirects=True,
                headers={"Referer": HOME_URL},
            ) as response:
                if response.status in (403, 429):
                    if attempt == 4:
                        await mark_failed(row_id, f"HTTP {response.status}")
                        stats["failed"] += 1
                        return

                    wait = min(60.0, backoff)
                    print(
                        f"\n[RATE] HTTP {response.status}; "
                        f"retrying in {wait:.1f}s"
                    )
                    await asyncio.sleep(wait)
                    backoff *= 2
                    continue

                if 500 <= response.status <= 599:
                    if attempt == 4:
                        await mark_failed(row_id, f"HTTP {response.status}")
                        stats["failed"] += 1
                        return

                    await asyncio.sleep(backoff)
                    backoff *= 2
                    continue

                if response.status != 200:
                    await mark_failed(row_id, f"HTTP {response.status}")
                    stats["failed"] += 1
                    return

                content_type = response.headers.get("Content-Type", "")
                if not content_type.lower().startswith("image/"):
                    await mark_skipped(row_id, "Response is not an image")
                    stats["skipped"] += 1
                    return

                data = await read_response_limited(
                    response,
                    MAX_IMAGE_BYTES,
                )

            if len(data) < 1000:
                await mark_skipped(row_id, "Image response too small")
                stats["skipped"] += 1
                return

            try:
                with Image.open(io.BytesIO(data)) as image:
                    width, height = image.size

                    if width < MIN_WIDTH or height < MIN_HEIGHT:
                        await mark_skipped(
                            row_id,
                            f"Image {width}x{height}",
                        )
                        stats["skipped"] += 1
                        return

                    # Force Pillow to actually decode the image.
                    image.load()
            except Exception as exc:
                await mark_skipped(row_id, f"Invalid image: {exc}")
                stats["skipped"] += 1
                return

            digest = digest_bytes(data)

            async with hash_lock:
                if digest in known_hashes:
                    stats["duplicates"] += 1
                    await mark_downloaded(
                        row_id, "", digest, width, height
                    )
                    return

                async with DB_LOCK:
                    existing = DB.execute(
                        """
                        SELECT id
                        FROM images
                        WHERE sha256 = ?
                        LIMIT 1
                        """,
                        (digest,),
                    ).fetchone()

                if existing:
                    known_hashes.add(digest)
                    stats["duplicates"] += 1
                    await mark_downloaded(
                        row_id, "", digest, width, height
                    )
                    return

                known_hashes.add(digest)

            ext = image_extension(content_type, image_url)
            path = ORIGINAL_DIR / f"{digest}{ext}"

            if not path.exists():
                # Atomic write prevents half-written files if interrupted.
                temp = path.with_suffix(path.suffix + ".part")
                temp.write_bytes(data)
                temp.replace(path)

            await mark_downloaded(
                row_id,
                str(path.relative_to(ROOT)),
                digest,
                width,
                height,
            )
            stats["downloaded"] += 1

            if ARGS.make_pfps:
                await create_pfp(path, digest, ARGS.size)

            return

        except asyncio.CancelledError:
            raise
        except Exception as exc:
            if attempt == 4:
                await mark_failed(row_id, repr(exc))
                stats["failed"] += 1
                return

            await asyncio.sleep(backoff)
            backoff *= 2


# ============================================================
# WORKERS / STATS
# ============================================================

async def worker(
    session: aiohttp.ClientSession,
    queue: asyncio.Queue[dict[str, Any] | None],
) -> None:
    while True:
        row = await queue.get()
        try:
            if row is None:
                return

            await download_image(session, row)
        finally:
            queue.task_done()


def show_stats(final: bool = False) -> None:
    elapsed = max(0.001, time.monotonic() - START_TIME)
    rate = stats["downloaded"] / elapsed

    line = (
        f"[SCROLL] {stats['scrolls']}  "
        f"[DISCOVERED] {stats['discovered']:,}  "
        f"[DOWNLOADED] {stats['downloaded']:,}  "
        f"[DUPLICATES] {stats['duplicates']:,}  "
        f"[SKIPPED] {stats['skipped']:,}  "
        f"[FAILED] {stats['failed']:,}  "
        f"[RATE] {rate:.1f}/s"
    )

    if final:
        print(line)
    else:
        print(f"\r{line}", end="", flush=True)


# ============================================================
# MAIN
# ============================================================

async def main() -> int:
    print()
    print("=" * 60)
    print(" Pinterest PFP Collector - HELIUM")
    print("=" * 60)
    print()

    if ARGS.search:
        print(f"[MODE] Pinterest search: {ARGS.search}")
    else:
        print("[MODE] Authenticated Home / For You feed")

    print(f"[CONFIG] MAX_IMAGES  = {ARGS.max_images:,}")
    print(f"[CONFIG] MAX_SCROLLS = {ARGS.max_scrolls:,}")
    print(f"[CONFIG] MAX_RUNTIME = {ARGS.max_runtime} minutes")
    print(f"[CONFIG] WORKERS     = {ARGS.workers}")
    print()

    await load_known_hashes()

    async with async_playwright() as playwright:
        print("[HELIUM] Connecting through CDP...")
        browser = await playwright.chromium.connect_over_cdp(
            f"http://127.0.0.1:{CDP_PORT}"
        )

        if not browser.contexts:
            print("[ERROR] Helium has no browser context.")
            return 1

        context = browser.contexts[0]

        # Prefer an existing Pinterest tab. Otherwise create one.
        page = next(
            (p for p in context.pages if "pinterest." in p.url.lower()),
            None,
        )
        if page is None:
            page = context.pages[0] if context.pages else await context.new_page()

        if not ARGS.search:
            print("[AUTH] Checking Pinterest session...")
            if not await open_pinterest(page):
                print()
                print("[ERROR] Pinterest content was not detected.")
                print("        Log in normally in the Helium window, then retry.")
                print()
                print("Possible causes:")
                print("  - login/signup page")
                print("  - CAPTCHA")
                print("  - temporary Pinterest error")
                print("  - feed has not loaded")
                return 1

            print("[AUTH] Pinterest session/content detected.")
            print("[FEED] Using Home / For You feed.")
        else:
            # Search mode should not require the Home feed to be authenticated.
            search_url = (
                "https://www.pinterest.com/search/pins/?q="
                + quote(ARGS.search, safe="")
            )
            print(f"[SEARCH] Opening: {ARGS.search}")

            try:
                await page.goto(
                    search_url,
                    wait_until="domcontentloaded",
                    timeout=60_000,
                )
            except PlaywrightTimeoutError:
                pass

            if not await wait_for_search_results(page):
                print("[ERROR] Pinterest search results were not detected.")
                return 1

            print("[SEARCH] Results loaded.")

        connector = aiohttp.TCPConnector(
            limit=max(1, ARGS.workers),
            limit_per_host=max(1, ARGS.workers),
            ttl_dns_cache=300,
        )

        headers = {
            "User-Agent": (
                "Mozilla/5.0 (X11; Linux x86_64) "
                "AppleWebKit/537.36 (KHTML, like Gecko) "
                "Chrome/140 Safari/537.36"
            ),
            "Accept": "image/avif,image/webp,image/apng,image/*,*/*;q=0.8",
        }

        queue: asyncio.Queue[dict[str, Any] | None] = asyncio.Queue(
            maxsize=max(ARGS.workers * 4, 32)
        )

        async with aiohttp.ClientSession(
            connector=connector,
            headers=headers,
        ) as session:
            workers = [
                asyncio.create_task(worker(session, queue))
                for _ in range(ARGS.workers)
            ]

            seen_urls: set[str] = set()
            deadline = time.monotonic() + ARGS.max_runtime * 60
            position = 0

            try:
                for scroll_number in range(ARGS.max_scrolls):
                    if STOP:
                        break

                    if time.monotonic() >= deadline:
                        print("\n[RUNTIME] Maximum runtime reached.")
                        break

                    if stats["discovered"] >= ARGS.max_images:
                        print("\n[LIMIT] Maximum images reached.")
                        break

                    stats["scrolls"] = scroll_number + 1

                    images = await extract_images(page)
                    new_images = 0

                    for item in images:
                        if STOP:
                            break

                        if stats["discovered"] >= ARGS.max_images:
                            break

                        url = item["image_url"]
                        normalized = normalize_url(url)

                        if not normalized or normalized in seen_urls:
                            continue

                        seen_urls.add(normalized)

                        row_id = await add_candidate(
                            image_url=url,
                            pin_url=item["pin_url"],
                            position=position,
                            scroll_number=scroll_number,
                        )
                        position += 1

                        if row_id is None:
                            continue

                        await queue.put({
                            "id": row_id,
                            "image_url": url,
                        })
                        new_images += 1

                    show_stats()

                    if STOP:
                        break

                    await asyncio.sleep(SCROLL_WAIT)

                    # Scroll only the main document. Pinterest's virtualized
                    # feed will load more pins as the viewport advances.
                    try:
                        await page.evaluate(
                            """
                            () => window.scrollBy({
                                top: Math.max(window.innerHeight * 0.9, 700),
                                left: 0,
                                behavior: "smooth"
                            })
                            """
                        )
                    except Exception:
                        pass

                    await asyncio.sleep(NEW_CONTENT_WAIT)

                    if new_images == 0:
                        await asyncio.sleep(1.5)

                    show_stats()

                print()
                print("[DOWNLOAD] Waiting for queued downloads...")
                await queue.join()

            finally:
                # Stop accepting new work and let the queue drain if possible.
                for _ in workers:
                    await queue.put(None)

                await asyncio.gather(*workers, return_exceptions=True)

        print()
        print("=" * 60)
        print(" Finished")
        print("=" * 60)
        show_stats(final=True)
        print(f"[OUTPUT]   {ORIGINAL_DIR}")
        if ARGS.make_pfps:
            print(f"[PFP]      {PFP_DIR}")
        print(f"[DATABASE] {DB_PATH}")
        print()

        # Do not call browser.close(): connect_over_cdp attaches to the
        # user's Helium instance. Exiting Playwright disconnects instead.
        await browser.close()

    DB.close()
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(asyncio.run(main()))
    except KeyboardInterrupt:
        print("\n[STOP] Stopped by user.")
        raise SystemExit(130)

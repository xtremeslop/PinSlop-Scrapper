# Pinterest PFP Collector 🐈

> Collect pictures. Make PFPs. Create unnecessary amounts of infrastructure.

A lightweight Pinterest image collector built around **Helium + Playwright + aiohttp + Pillow + SQLite**.

It connects to your existing Helium browser through CDP, uses the Pinterest page you're viewing to discover images, downloads them concurrently, removes duplicates using SHA-256, and can optionally generate square PFP versions.

Basically:

```text
Pinterest
   ↓
Helium
   ↓
Playwright
   ↓
👀 find images
   ↓
📥 download
   ↓
🔐 SHA-256
   ↓
🗄️ SQLite
   ↓
🐈 PFP
```

Because manually saving images was apparently too primitive.

## ✨ Features

* 🌐 Uses an existing Helium browser session
* 🔐 Works with your authenticated Pinterest session
* 🔎 Pinterest search mode
* 🏠 Home / For You feed collection
* ⚡ Concurrent image downloads
* 🧬 SHA-256 duplicate detection
* 🔗 URL normalization
* 🗄️ SQLite metadata database
* 🖼️ Image validation with Pillow
* ✂️ Automatic square PFP generation
* ⏱️ Runtime and scroll limits
* 🛑 Graceful Ctrl+C shutdown
* 🔁 Automatic retries for temporary HTTP errors
* 📊 Live collection statistics
* 🐧 Linux-friendly
* 🧹 Doesn't require copying your Pinterest cookies into the program

## 🚀 Usage

### Start normally

```bash
./run.sh
```

This uses the authenticated Pinterest Home / For You feed.

### Search Pinterest

```bash
./run.sh --search "anime pfp"
```

Other examples:

```bash
./run.sh --search "funny cat memes"
./run.sh --search "cute black cats"
./run.sh --search "cursed images"
```

### Generate PFPs

```bash
./run.sh --make-pfps
```

Specify the size:

```bash
./run.sh --make-pfps --size 512
```

### Bigger collection

```bash
./run.sh \
    --search "funny cats" \
    --max-images 5000 \
    --workers 16 \
    --make-pfps
```

## ⚙️ Options

| Option            | Description                          |
| ----------------- | ------------------------------------ |
| `--max-images N`  | Maximum number of images to discover |
| `--max-scrolls N` | Maximum number of page scrolls       |
| `--max-runtime N` | Maximum runtime in minutes           |
| `--workers N`     | Number of concurrent downloads       |
| `--search QUERY`  | Search Pinterest                     |
| `--make-pfps`     | Generate square PFP images           |
| `--size N`        | PFP output size                      |
| `--help`          | Show help                            |

Example:

```bash
./run.sh \
    --search "black cat pfp" \
    --max-images 1000 \
    --max-scrolls 500 \
    --max-runtime 30 \
    --workers 12 \
    --make-pfps \
    --size 512
```

## 🌐 Helium

The script automatically looks for Helium in common locations.

You can also specify it manually:

```bash
HELIUM_BIN=/path/to/helium ./run.sh
```

The default CDP port is:

```text
9222
```

Change it with:

```bash
HELIUM_CDP_PORT=9223 ./run.sh
```

The collector connects to Helium using Chrome DevTools Protocol.

It does **not** launch a separate Playwright Chromium browser.

## 🔐 Authentication

The collector opens Pinterest through Helium.

If you're already logged in, it can use the existing session.

If Pinterest asks you to log in, simply log in normally through the Helium window.

No need to paste cookies or authentication tokens into the script.

Your browser profile stays local.

## 📁 Output

Downloaded originals are stored in:

```text
images/original/
```

Generated PFPs are stored in:

```text
images/pfp/
```

The SQLite database is stored at:

```text
data/pinterest.db
```

Example:

```text
.
├── run.sh
├── helium-profile/
├── data/
│   └── pinterest.db
└── images/
    ├── original/
    │   ├── abc123....jpg
    │   └── def456....webp
    └── pfp/
        ├── abc123...._512.jpg
        └── def456...._512.jpg
```

## 🧬 Deduplication

Images are identified using their SHA-256 hash.

This means different Pinterest URLs pointing to the exact same image can still be detected as duplicates.

Pinterest:

```text
/image123
/image123?foo=bar
/image123?utm_source=pinterest
/image123?random=why
```

Collector:

```text
"bro it's literally the same JPEG"
```

## 🗄️ Database

The SQLite database stores information such as:

* Image URL
* Normalized URL
* Pin URL
* Discovery timestamp
* Download status
* Local filename
* SHA-256
* Image dimensions
* Feed position
* Scroll number
* Error information

This makes it possible to keep track of what happened even after the collector exits.

## 🖼️ PFP generation

When `--make-pfps` is enabled, downloaded images are converted into square images using Pillow.

Example:

```bash
./run.sh \
    --search "cute cats" \
    --make-pfps \
    --size 512
```

Output:

```text
images/pfp/<sha256>_512.jpg
```

The image is cropped to a square while preserving the important parts of the image as much as possible.

## 📊 Live statistics

While running, the collector displays information such as:

```text
[SCROLL] 42
[DISCOVERED] 837
[DOWNLOADED] 791
[DUPLICATES] 31
[SKIPPED] 15
[FAILED] 0
[RATE] 4.8 images/sec
```

So you can stare at numbers while pretending you're running a massive distributed data pipeline.

## 🧪 Image validation

Images are checked before being saved.

The collector verifies things including:

* HTTP status
* Content type
* Minimum file size
* Actual image format
* Image dimensions

Very small or invalid files are skipped instead of being dumped into your image directory.

## 🔄 Retries

Temporary failures such as:

```text
403
429
5xx
```

are handled with retry/backoff logic.

This helps avoid immediately giving up when a CDN temporarily says:

> no ❤️

## 🛑 Stopping

Press:

```text
Ctrl+C
```

The collector will stop accepting new work and clean up its workers.

You can also configure limits so it stops automatically:

```bash
./run.sh --max-runtime 30
```

or:

```bash
./run.sh --max-images 5000
```

## 📦 Dependencies

The project uses:

* Python 3
* Playwright
* aiohttp
* Pillow
* SQLite
* Helium Browser

The launcher creates a local virtual environment and installs the required Python packages automatically.

## 🧹 Recommended `.gitignore`

Do **not** commit your browser profile or collected images.

A reasonable `.gitignore` is:

```gitignore
.venv/
helium-profile/
data/
images/
*.db
*.log
__pycache__/
```

Especially:

```text
helium-profile/
```

That's your browser profile. Keep it private.

## 🧠 Why Helium?

The project intentionally controls the browser you're already using instead of implementing Pinterest authentication itself.

That keeps authentication inside the browser and lets Playwright interact with the rendered page.

The collector simply observes the images exposed by the page.

## ⚠️ Responsible use

Use the collector responsibly.

Respect:

* Pinterest's Terms of Service
* copyright
* image creators
* applicable laws
* reasonable request rates

Don't crank the worker count to 9000 and then wonder why the website starts looking at you like:

```text
👁️👄👁️
```

## 🐛 Troubleshooting

### Helium cannot be found

Specify the binary manually:

```bash
HELIUM_BIN=/path/to/helium ./run.sh
```

### CDP connection fails

Check the port:

```bash
HELIUM_CDP_PORT=9222 ./run.sh
```

Make sure another Helium instance isn't already occupying the profile or CDP configuration.

### Pinterest isn't loading images

Pinterest is heavily dynamic.

Try allowing more runtime:

```bash
./run.sh --max-runtime 60
```

or simply give the page a few seconds to load between scrolls.

### Everything is being skipped

Check whether the images actually meet the minimum dimensions.

The collector intentionally ignores tiny images because downloading 37×37 tracking garbage isn't exactly the goal.

## 🗿 Example: Maximum Slop

```bash
./run.sh \
    --search "funny black cat memes" \
    --max-images 10000 \
    --max-scrolls 1000 \
    --max-runtime 60 \
    --workers 16 \
    --make-pfps \
    --size 512
```

Expected workflow:

```text
Pinterest:
    here is cat

Collector:
    DOWNLOAD

Pinterest:
    another cat

Collector:
    DOWNLOAD

Pinterest:
    same cat

Collector:
    DUPLICATE 💀

Pinterest:
    another 400 copies of the same cat

Collector:
    I have seen this before.
```

## 📜 License

Choose and add the license you want to use for the project.

---

## ⭐ Final statement

This project exists because someone needed a PFP and decided:

> "I could save one image..."

and then immediately chose:

> **"No. I will build an automated image collection system."**

Peak engineering.

🐈

# Memebooru

A local collection of pictures, GIFs, videos, audio, text and tweets with tags, search, staging, deduplication and sync. The native macOS/iOS application and web gallery use English.

The web gallery exposes **one explicitly published collection**. Search titles and tags with prefix suggestions (including `-` exclusions; select with the pointer or arrow keys and Enter), combine tags, exclude exact tag names (`-anime`; `-l` does not exclude `yellow`), filter by category/orientation/resolution, sort, save browser-local favorites and download originals. The layout follows the native application: header search, a 208 px sidebar, uncropped thumbnails in 150 px areas, and an inline detail page. Images load progressively as you scroll. On phones, the sidebar becomes a drawer. Arrow keys navigate images; Escape and browser Back return to the gallery. Changing images clears the previous image immediately while the next loads.

The gallery is read-only. Importing, editing and syncing remain in the native app/CLI. A static server and CDN can serve the public export without exposing the database.

## Run the web gallery

Requires Docker Compose and a prepared public export containing `index.html`, `app.js`, `style.css`, `favicon.svg`, `catalogue.json`, `media/` and `thumbs/`.

```sh
PUBLIC_GALLERY=/absolute/path/to/public-gallery \
  docker compose -f docker-compose.web.yml up -d --build
```

The default bind is `127.0.0.1:8080`. Put an HTTPS reverse proxy in front. Set `WEB_BIND` and appropriate firewall rules if using another interface. See [deployment](deploy/README.md).

**Never mount a private collection or home directory as the public web root.** Only use `gallery publish` output: explicit allowlisted images and manifest metadata, without collection databases, device identity, staging, history, credentials or private database tags/descriptions.

## Frutiger Aero Archive collection

Snapshot from October 20, 2026: **38 selected sections, 6,069 source URLs, 6,002 unique images**, with 6–16 English tags per file (median 10). See [collection provenance](Collections/README.md).

Source: <https://frutigeraeroarchive.org/wallpapers>. The downloader preserves source URLs, original bytes, dimensions and SHA-256; repeated runs resume missing downloads. Coverage refers to discovered images in the selected sections on that date, not the entire website.

**Images are not in Git and are not licensed under BSD.** Rights remain with their respective authors. Preserve attribution and respect the owners' terms when publishing.

```sh
python3 -m venv .venv
. .venv/bin/activate
pip install "Pillow>=11,<13"
python scripts/wallpapers/download.py /path/to/FrutigerAeroCollection \
  --manifest Collections/frutiger-aero.json
```

The published manifest already includes English tags; downloading it needs no model. Omit `--manifest` for a new full website crawl. To generate new tags, install `scripts/wallpapers/requirements.txt` and run `python scripts/wallpapers/tag.py /path/to/FrutigerAeroCollection`.

OpenCLIP proposes semantic/style tags locally. Colors, orientation, aspect ratio and resolution are measured from pixels. Images are not sent to an API. Automatic tags can be wrong; `tagging.method`, `suggested` and `reviewed` record provenance. Edit `tagged.json` before importing/publishing to correct tags.

## Prepare a native collection and public export

Imports always enter **Staging**. On Linux, install `ffmpeg` and `ffprobe` (Debian/Ubuntu: `sudo apt-get install --no-install-recommends ffmpeg`). Three archive JPEGs require the existing FFmpeg fallback for preview decoding; originals are preserved. Dockerfile.server includes FFmpeg. A server serving the finished static export does not need it.

```sh
swift build -c release --product memebooru
# Locate executable: swift build -c release --show-bin-path
memebooru init /path/to/Aero.memebooru
memebooru gallery import /path/to/FrutigerAeroCollection/tagged.json -c /path/to/Aero.memebooru
memebooru stage ls -c /path/to/Aero.memebooru
# Explicitly commit after reviewing; --force preserves visually similar variants.
memebooru stage commit all --force --no-convert -c /path/to/Aero.memebooru
memebooru gallery publish /path/to/FrutigerAeroCollection/tagged.json \
  -c /path/to/Aero.memebooru --output /path/to/public-gallery --web Web
```

Put `memebooru` on PATH or use its absolute executable path. Import verifies every file hash before making changes, skips known exact duplicates and preserves original formats. Publication requires a new output directory, uses temporary output and aborts if an allowlisted image is absent or corrupt.

## Native application

Swift 6.0+, Xcode with macOS/iOS 26+ SDKs, and XcodeGen. The core package supports macOS 15+; the app currently targets macOS/iOS 26+.

```sh
cd Apps/Memebooru
xcodegen generate
open Memebooru.xcodeproj
```

For iOS, supply your signing team and App Group entitlements. Optional multimedia tools are built with `scripts/build-ffmpeg-macos.sh` and `scripts/build-ffmpeg-ios.sh`. Image browsing works without FFmpeg; conversion and some video operations require it. iOS builds with FFmpeg require `Vendor/ffmpeg-ios/MBFFmpeg.xcframework` beforehand.

Collections are `.memebooru` directories containing SQLite, media and previews. Keep backups. File, Telegram and tweet imports enter staging; tweet replies and quotes preserve their context. UI language does not rewrite private user content.

## CLI and sync server

```sh
swift run memebooru --help
swift run memebooru gallery --help
swift test
```

The Linux sync server and Telegram bot are separate: `Dockerfile.server`, `docker-compose.server.yml`, `.env.example`. They are not needed for the public gallery. Keep credentials in environment variables outside Git; do not expose sync ports just to publish a website.

## Checks

```sh
swift test --filter GalleryTests
node --test Tests/Web/gallery.test.mjs
python3 -m unittest discover -s Tests/Web -p 'test_*.py' # requires Pillow
# Optional browser checks: pip install playwright && playwright install chromium
python3 Tests/Web/browser.py http://127.0.0.1:8080
python3 Tests/Web/spacing.py http://127.0.0.1:8080
```

Gallery tests cover staging, idempotent imports, hashes, path traversal, partial-publication refusal and private-data exclusion. Browser checks cover navigation, progressive loading, delayed-image replacement, mobile layout and public-path boundaries. Spacing checks measure text insets, header gaps, content padding and overflow in gallery/detail views at 11 viewport widths from 320 to 1920 px.

## Layout

- `Sources/MemebooruCore`: database, models, tags, search, staging, deduplication and sync.
- `Sources/MemebooruPlatformApple`, `Sources/MemebooruPlatformLinux`: platform services.
- `Sources/memebooru`: CLI, catalogue import and publication.
- `Apps/Memebooru`: native macOS/iOS UI.
- `Web`: responsive gallery without a bundler or external scripts.
- `deploy`: HTTP server configuration and documentation.
- `scripts/wallpapers`: reproducible downloading and local tagging.

## License

Original Memebooru code: [BSD-2-Clause](LICENSE). Third-party components retain their own licenses: [THIRD_PARTY.md](THIRD_PARTY.md). Collections, images and user content are not covered by the code license.

# ShelfSync

A PDF reader for **Linux desktop** and **Android tablets** that keeps your books
and your place in them in sync through **your own Google Drive**. Add a book on
one device and it shows up on the other; put the tablet down at page 214 and the
PC offers to jump there.

- **No server, no cost.** Everything lives in your Google Drive: the books in a
  visible `ShelfSync` folder, and reading positions in a hidden app-data folder.
- **Private by design.** The app only asks for the `drive.file` and
  `drive.appdata` scopes, which cover files ShelfSync created and nothing else.
  It can't see the rest of your Drive.
- **Resumes exactly where you left off.** It remembers the page, your position
  on that page, and the zoom.
- **Dark pages.** Text and background are inverted while photos and diagrams
  keep their real colours.
- **Offline first.** Reading works without a connection. Sync catches up later.

**Download:** [home page](https://thisara-g.github.io/shelfsync/) ·
[latest release](https://github.com/thisara-g/shelfsync/releases/latest) ·
[privacy policy](https://thisara-g.github.io/shelfsync/privacy.html)

The rest of this README is for building ShelfSync yourself.

## Setup

You need a Linux PC (Ubuntu/Debian) to build from, and optionally an Android
tablet. Clone and run the setup script:

```bash
git clone https://github.com/thisara-g/shelfsync.git
cd shelfsync
./setup
```

`./setup` walks you through everything, and you can run it again at any time:
it skips steps that are already done. It does these steps:

1. **Installs the build tools**, after asking first: system packages via apt,
   the Flutter SDK (`~/development/flutter`) and the Android SDK
   (`~/Android/Sdk`). Tools you already have are reused.
2. **Connects the app to your Google account.** Google requires every app that
   uses Drive to have its own free Google Cloud project, so you create one. If
   `gcloud` is installed it does this for you. Otherwise the script opens each
   Google Cloud Console page and prints exactly what to type. It takes about
   five minutes, once:
   - create the project and enable the Drive API,
   - fill in the consent screen (app name, your email) and click **Publish
     app**, so sign-ins don't expire after 7 days. No Google review is needed
     for these scopes,
   - create a **Desktop app** OAuth client, then paste its ID and secret (or
     the downloaded JSON file's path) into the script,
   - create an **Android** OAuth client from the package name and the SHA-1
     fingerprint that the script prints.
3. **Writes `config/google_oauth.json`**. This file is git-ignored, so it never
   leaves your machine.
4. **Builds and installs:**
   - The Linux app gets added to your app launcher.
   - The Android APK gets installed on the tablet if one is connected with USB
     debugging. Otherwise the script prints the APK's path and how to install
     it.

Then open ShelfSync on each device, tap **Sign in**, and use the same Google
account everywhere. A `ShelfSync` folder appears in your Drive the first time.

### Installing on the tablet

1. On the tablet, enable **Developer options**: Settings → About tablet → tap
   *Build number* seven times.
2. In Developer options, turn on **USB debugging**.
3. Plug the tablet into the PC, accept the prompt on the tablet, and re-run
   `./setup` (or `adb install -r build/app/outputs/flutter-apk/app-release.apk`).

You can also copy the APK to the tablet and open it there. Allow installs from
that app when Android asks.

## Using it

| | |
|---|---|
| **Add books** | **Add PDF**, or on Linux drag PDF files onto the window (Ctrl+O also works). They upload to Drive in the background. |
| **Continue reading** | The top of the library shows what you're reading on any device, where you were and when. One tap or click to continue. |
| **Find books** | Search, filter (Reading, Finished, In Drive, On this device) and sort. On Linux the sidebar holds the filters and Ctrl+K jumps to search. |
| **Books from your other device** | Shown with a cloud badge. Tap one to download and open it. |
| **Shelves** | Group books into shelves ("Textbooks", "Novels"). Create them from the sidebar (Linux) or the pills (tablet); drag a cover onto a shelf or use a book's **Shelves…** menu. Shelves sync between devices. |
| **Reader (tablet)** | Tap the page to show or hide the controls. Drag the slider to move through the book (ticks mark chapters). Search, contents/pages/bookmarks and the bookmark button are in the top bar. |
| **Reader (Linux)** | **Single** (one whole page at a time) or **Two pages** (both always fit). ↑/↓ scroll and carry on to the next or previous page; ←/→ and PgUp/PgDn turn pages. Side panel with contents, page thumbnails and bookmarks (Ctrl+B). Search (Ctrl+F), bookmark (Ctrl+D), go to page (Ctrl+G), zoom and **Fit width** (Ctrl+0), full screen (F11). Press ? for all shortcuts. |
| **Bookmarks** | Bookmarked pages sync between devices along with shelves. |
| **Page colour** | Light, Sepia or Dark. Dark inverts text but keeps images in their real colours. |
| **Resume from another device** | If another device has a newer position, the tablet shows a sheet and Linux shows a corner notification (press J to jump). Tick *Always jump* to move there automatically from then on. |
| **Sync** | Automatic on start, when you return to the app, after adding books and every 5 minutes. The status pill (tablet) or account box (Linux) shows the state and opens the account menu. |
| **Remove** | Right-click (desktop) or long-press (tablet) a book:<br>• **Remove download** frees space but keeps the book in the cloud.<br>• **Delete everywhere** moves it to the Drive trash and removes it from all devices. |

## Good to know

- **Only books added through ShelfSync sync.** The `drive.file` permission
  means ShelfSync can't see files you drop into the Drive folder via the
  website. Add books from the app instead.
- **A book's identity is its content**, a SHA-256 hash. Renaming the file
  doesn't create a duplicate, and two copies of the same PDF are stored once.
- **Switching Google accounts** unlinks your books from the old Drive. Nothing
  gets deleted locally, and the books upload to the new account.
- **Your own builds are signed with your machine's debug key** (unless you
  create `android/key.properties`). That's fine for personal use. Android
  won't install it over the official release or a build from another computer,
  so uninstall the old app first. Each build machine needs its own Android
  OAuth client (run `./setup` there).

## Troubleshooting

| Symptom | Fix |
|---|---|
| Cloud button says *Sync not set up* | `config/google_oauth.json` was missing when the app was built. Run `./setup`, which rebuilds. |
| Linux: browser shows *Error 400: redirect_uri_mismatch* | The Linux client must be of type **Desktop app**. Create a new one and run `./setup --reconfigure`. |
| Android: sign-in fails or closes immediately | The Android OAuth client's package name or SHA-1 doesn't match. Run `./setup` to print the correct values and compare them in the Cloud Console. Changes can take a few minutes to apply. |
| *Access blocked: app has not completed verification* / sign-in expires weekly | The consent screen is still in **Testing**. Open Google Auth Platform → Audience → **Publish app**. |
| First Android build is very slow | Normal: Gradle downloads its tooling (NDK, CMake) once. Later builds take seconds. |

## Development

```bash
flutter run -d linux        # run on the desktop
flutter run -d <device-id>  # run on a connected Android device (flutter devices)
flutter test                # unit tests, including two-device sync against a fake Drive
flutter analyze
python3 tool/make_icons.py  # regenerate the app icons
```

Project layout:

```
lib/
  main.dart                    app wiring
  models/book.dart             library entry: id (content hash), position, Drive link
  services/library_store.dart  library.json + books/<hash>.pdf in the app data dir
  services/cover_renderer.dart first-page thumbnails
  services/page_image_regions.dart  finds images on a page (PDFium) for dark mode
  screens/                     welcome, library, reader (+ reader_parts), sync status
  sync/google_auth.dart        sign-in: loopback OAuth (Linux), Play services (Android)
  sync/drive_service.dart      Drive v3 calls: folder, books, progress records
  sync/library_sync.dart       the sync engine: books + reading positions
  sync/progress_record.dart    appDataFolder record format
docs/                          home page and privacy policy (GitHub Pages)
setup                          guided setup script
```

Reading-position records are stored as `progress-<sha256>.json` in Drive's
`appDataFolder`:

```json
{ "book_id": "<sha256>", "page": 214, "percent": 0.38, "offset_x": 0.0, "offset_y": 0.42,
  "device": "ubuntu-pc", "device_id": "<random>", "updated": 1793212345 }
```

## License

ShelfSync is free software under the [GNU General Public License v3.0](LICENSE).
You may use, study, change and share it. If you distribute a modified version,
it must also be under GPL-3.0 with its source available.

The ShelfSync name and icon identify the official app and aren't covered by the
license. Please use a different name and icon for your own fork.

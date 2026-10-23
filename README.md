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
| **Add books** | **Add PDF** in the library. They upload to Drive in the background. |
| **Books from your other device** | Shown with a cloud badge. Tap one to download and open it. |
| **Sync** | Automatic on start, when you return to the app, after adding books and every 5 minutes. Pull down (tablet) or use the cloud button → *Sync now*. |
| **Reading position** | Saved continuously. If the other device read further, the reader asks *"Jump to page X (from …)?"*. **Stay here** keeps your position and makes it the newest instead. |
| **Dark pages** | The moon button in the reader. |
| **Navigate** | Scroll or swipe; click the page number to jump to a page. On desktop, PgUp/PgDn and the arrow keys work too. |
| **Remove** | Right-click (desktop) or long-press (tablet) a book:<br>• **Remove download** frees space but keeps the book in the cloud.<br>• **Delete everywhere** moves it to the Drive trash and removes it from all devices. |

## Good to know

- **Only books added through ShelfSync sync.** The `drive.file` permission
  means ShelfSync can't see files you drop into the Drive folder via the
  website. Add books from the app instead.
- **A book's identity is its content**, a SHA-256 hash. Renaming the file
  doesn't create a duplicate, and two copies of the same PDF are stored once.
- **Switching Google accounts** unlinks your books from the old Drive. Nothing
  gets deleted locally, and the books upload to the new account.
- **The APK is signed with your build machine's debug key.** That's fine for
  personal use. To install a build from a different computer over an existing
  one, uninstall the old app first. That computer also needs its own Android
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
  screens/                     library grid, reader, sync button
  sync/google_auth.dart        sign-in: loopback OAuth (Linux), Play services (Android)
  sync/drive_service.dart      Drive v3 calls: folder, books, progress records
  sync/library_sync.dart       the sync engine: books + reading positions
  sync/progress_record.dart    appDataFolder record format
setup                          guided setup script
```

Reading-position records are stored as `progress-<sha256>.json` in Drive's
`appDataFolder`:

```json
{ "book_id": "<sha256>", "page": 214, "percent": 0.38, "offset_x": 0.0, "offset_y": 0.42,
  "device": "ubuntu-pc", "device_id": "<random>", "updated": 1793212345 }
```

# ShelfSync — project handoff

Context carried over from a claude.ai chat (2026-10-22). Read this before starting.

## What we're building
**ShelfSync**: a cross-platform book reader (PDF first, EPUB later) for **Ubuntu (Linux desktop)** and an **Android tablet**, built with **Flutter** (one codebase).

Problem it solves: reading the same book on PC and tablet without manually copying files, and always resuming where you left off.

### Requirements (from the user)
- Upload a book on one device → it appears in the library on the other device automatically.
- Reading position syncs between devices.
- Google Drive is the sync backend, and setup must be **seamless**: on first Google sign-in the app automatically creates a `ShelfSync` folder in the user's Drive. No manual Drive setup, no reading docs.
- **Anyone who clones the repo** must be able to set it up themselves (not just the author).
- Must actually work on this Ubuntu PC and on the user's Android tablet.
- Git repo with a **commit at each working stage**. Repo: **private GitHub repo `thisara-g/shelfsync`**.
- Build **locally on this Ubuntu PC** (user chose this over GitHub Actions).
- Must cost nothing to run: no backend server (local-first; all storage is the user's own Google Drive).

## Design decisions already made
- **Drive scopes:** `drive.file` (app only sees files it created) + `drive.appdata` (hidden app-data folder). Both are non-sensitive, so no Google app verification is needed. Consequence: books must be uploaded *through the app* (files added via the Drive website won't be visible). This is acceptable.
- **Books:** stored in a visible `ShelfSync` folder in Drive, auto-created on first sign-in.
- **Reading progress:** small JSON records in `appDataFolder`, keyed by a content hash of the book file (not the filename), e.g.
  `{ "book_id": "<hash>", "page": 214, "percent": 0.38, "device": "ubuntu-pc", "updated": <unix ts> }`
  Conflict rule: latest `updated` wins; if the remote position differs from local, prompt "Jump to page X (from <device>)?" rather than moving silently.
- **Google OAuth client:** cannot be created by script/API — a human must click through Google Cloud Console once. Each person who clones creates **their own** Google Cloud project via a guided `./setup` script that automates everything possible (create project + enable Drive API via `gcloud` if available, compute Android debug-key SHA-1, write the config file) and, for the console-only steps, opens the exact page and prints the exact values to paste. Client IDs live in an untracked config file (e.g. `config/google_oauth.json`, with a committed `.example`).
  - Linux desktop: OAuth "Desktop app" client, loopback redirect (127.0.0.1) flow.
  - Android: OAuth "Android" client tied to package name + signing-key SHA-1.
  - OAuth consent screen should be set to "In production" (not "Testing") so refresh tokens don't expire after 7 days; with only non-sensitive scopes no verification is required.

## Stages (one commit each, each must build and run)
1. Flutter scaffold + PDF reader with a local library that remembers the last page per book (offline, both platforms).
2. Google sign-in on Linux and Android; auto-create the `ShelfSync` Drive folder.
3. Upload a book on one device → listed and downloadable on the other.
4. Reading-position sync via `appDataFolder`, with the "jump to page X?" prompt.
5. `./setup` script + README so anyone can clone and set it up without reading external docs.

## Status (2026-10-23)
All five stages are implemented and committed, and they build for Linux and Android. Only the steps that need the user are left (see below).
Extras beyond the original plan:
- cover grid with first-page thumbnails
- exact in-page resume position
- dark pages that keep images un-inverted (via PDFium image bounds)

Still to do with the user (physical checks):
- run `./setup` for real to create the Cloud project and OAuth clients
- test sign-in on Linux and Android
- test the two-device book and position sync
- install the APK on the tablet
- create the private GitHub repo `thisara-g/shelfsync` and push (confirm with the user first)

## Environment on this PC (installed)
- Flutter: `~/development/flutter` (stable).
- Android SDK: `~/Android/Sdk`.
- JDK 21: Flutter is configured with `--jdk-dir`. The system default is Java 25, which Gradle can't use.
- PATH and ANDROID_HOME are set in `~/.bashrc`. Non-interactive shells need `export PATH=~/development/flutter/bin:$PATH`.
- sudo can't prompt from Claude's shell. `pkexec <cmd>` works: the user approves a GUI password dialog.
- Android cmdline-tools 23+ replaced sdkmanager with the `android` CLI:
  - use `android --no-metrics --sdk=$ANDROID_HOME sdk install platform-tools platforms/android-36 …`, with slash paths, not semicolons
  - an orphaned `android` process once caused a "Text file busy" error
- The Gradle heap is lowered to 2.5 GB in `android/gradle.properties`, because the machine has 6.9 GB RAM.
- The first Android build took about 35 minutes, since Gradle fetched the NDK and CMake. Later builds take seconds.

## About the user
Thisara Gunawardana (GitHub: thisara-g), final-year Electronic & Telecommunication Engineering student. Comfortable with Linux and the terminal. Was previously going to use KOReader + Syncthing for this, but wanted something with no manual file copying.

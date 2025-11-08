# Flutter Radio

![Main Screen](/screenshots/home.png)

A small internet radio app for Android built with Flutter.
Supports live stream playback, play/pause/next/previous, volume control, station list editing, a **web remote over Wi-Fi**, and a local **REST API**.

## Features

- Dark theme and fullscreen mode
- Play / Pause / Next / Previous station controls
- Volume control with a slider
- Station list editing: add, delete, and reorder (drag-and-drop)
- Displays the currently playing track title (from ICY metadata, if provided by the stream)
- Built-in web remote over Wi-Fi:
    - Remote control from any device on the same local network
    - Local REST API (OpenAPI-style specification available)
- Auto-scroll to the currently playing station, including wrap-around from last → first

## Requirements (Android)

- Android 7.0+ (API 24+), Android 8.0+ recommended
- Internet connection (for streaming)
- For web remote: the phone and the controlling device must be on the **same local Wi-Fi network**


### App permissions

In `AndroidManifest.xml`:
- `android.permission.INTERNET` — required for audio streaming and web remote
- (Optional) `android.permission.WAKE_LOCK` — if you choose to add `wakelock_plus` to keep the screen awake during playback.

## Technologies used

- **Flutter** (Material 3).
- **[just_audio]** — audio player for streaming.
- **[audio_service]** — background playback service and system media controls integration.
- Чистый `dart:io` HTTP server (no extra dependencies)
- ICY metadata parsing via `just_audio` (`icyMetadataStream`).

[just_audio]: https://pub.dev/packages/just_audio
[audio_service]: https://pub.dev/packages/audio_service

## Build and run

```bash
# 1) Get dependencies
flutter pub get

# 2) Run on a connected device (debug mode)
flutter run

# 3) Build release APK
flutter build apk --release
# The APK will be at: build/app/outputs/flutter-apk/app-release.apk
```

## Settings menu

![Settings menu 1](/screenshots/settings1.png)

![Settings menu 2](/screenshots/settings2.png)

## Web interface
A view of the web remote UI opened from another device on the same Wi-Fi network:

![Web interface](/screenshots/web_ui.png)
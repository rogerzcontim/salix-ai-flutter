# SALIX AI Personal Flutter — PROGRESS

Started: 2026-04-28
Target: Android APK ChatGPT-style consuming meta-agent SSE + STT/TTS + onboarding + multi-user

## Tasks

- [x] Verify Flutter SDK 3.27+ available (3.27.4 detected)
- [x] Create directory structure
- [x] Write `pubspec.yaml`
- [x] Write `lib/main.dart` with Riverpod + cyberpunk theme
- [x] Write `lib/pages/onboarding_page.dart` (name, voice, persona)
- [x] Write `lib/pages/chat_page.dart` ChatGPT-style + SSE streaming
- [x] Write `lib/pages/settings_page.dart` (multi-user, persona)
- [x] Write `lib/services/meta_agent_client.dart` (SSE)
- [x] Write `lib/services/voice.dart` (STT + TTS)
- [x] Write `lib/services/persona_store.dart` (SharedPreferences)
- [x] Write `lib/services/intent_launcher.dart` (url_launcher)
- [x] Write `android/app/build.gradle` config
- [x] Write `AndroidManifest.xml` with RECORD_AUDIO, INTERNET
- [x] Write `README.md`
- [x] Generated android/ scaffold via `flutter create --platforms=android --org ai.ironedge`
- [x] Patched AndroidManifest.xml with INTERNET + RECORD_AUDIO + queries
- [x] Patched android/app/build.gradle to Java 17 + minSdk 24
- [x] Run `flutter pub get` (~50 deps OK)
- [x] Run `flutter analyze` (24 issues — only deprecations + broken auto-gen test/widget_test.dart removed)
- [x] Removed test/widget_test.dart (referenced non-existent MyApp class)
- [ ] Run `flutter build apk --debug` (waiting for IronEdge build slot)
- [ ] Copy APK to Desktop
- [ ] SHA256 + size

Last update: 2026-04-28 awaiting IronEdge build before SALIX

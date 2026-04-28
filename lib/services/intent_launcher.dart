import 'package:android_intent_plus/android_intent.dart';
import 'package:url_launcher/url_launcher.dart';

/// Detects [OPEN_INTENT package=... url=...] tokens in assistant output and
/// dispatches them as Android intents.
class IntentLauncher {
  static final _intentPattern =
      RegExp(r'\[OPEN_INTENT(?:\s+package=([^\s\]]+))?(?:\s+url=([^\s\]]+))?\]');

  /// Scans [text] and launches every match (URL or package).
  /// Returns the cleaned text with the tokens stripped out.
  static Future<String> dispatch(String text) async {
    String cleaned = text;
    for (final m in _intentPattern.allMatches(text)) {
      final pkg = m.group(1);
      final url = m.group(2);
      try {
        if (url != null && url.isNotEmpty) {
          await launchUrl(Uri.parse(url),
              mode: LaunchMode.externalApplication);
        } else if (pkg != null && pkg.isNotEmpty) {
          final intent = AndroidIntent(
            action: 'android.intent.action.MAIN',
            category: 'android.intent.category.LAUNCHER',
            package: pkg,
            componentName: null,
          );
          await intent.launch();
        }
      } catch (_) {
        // ignore — intent may fail if package not installed
      }
      cleaned = cleaned.replaceAll(m.group(0)!, '').trim();
    }
    return cleaned;
  }
}

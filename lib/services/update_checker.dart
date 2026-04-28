import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';

class UpdateInfo {
  final String version;
  final int build;
  final String url;
  final String changelog;
  UpdateInfo(
      {required this.version,
      required this.build,
      required this.url,
      required this.changelog});
}

class UpdateChecker {
  static const _manifestUrl =
      'https://ironedgeai.com/api/mobile/updates/latest.json';
  static const _appKey = 'salix_ai_app';

  Future<UpdateInfo?> checkForUpdate() async {
    try {
      final res = await http
          .get(Uri.parse(_manifestUrl))
          .timeout(const Duration(seconds: 10));
      if (res.statusCode != 200) return null;
      final j = jsonDecode(res.body) as Map<String, dynamic>;
      final entry = (j['latest'] as Map?)?[_appKey] as Map?;
      if (entry == null) return null;
      final pkg = await PackageInfo.fromPlatform();
      final cur = int.tryParse(pkg.buildNumber) ?? 0;
      final remote = int.tryParse('${entry['build'] ?? 0}') ?? 0;
      if (remote <= cur) return null;
      return UpdateInfo(
        version: entry['version']?.toString() ?? '0.0.0',
        build: remote,
        url: entry['url']?.toString() ?? '',
        changelog: entry['changelog']?.toString() ?? '',
      );
    } catch (_) {
      return null;
    }
  }
}

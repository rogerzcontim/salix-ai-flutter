// SALIX onda 4 — Deep links contextuais
//
// Builds OS-specific deep links for popular apps. The LLM passes
// {app_name, action, data} and we resolve to a URL/intent that opens the
// right thing.
//
// Coverage:
//   youtube  search | watch
//   spotify  search | track | playlist
//   whatsapp send
//   maps     navigate | search
//   tel      call
//   sms      send
//   mailto   send
//   browser  open
//
// Returned URLs feed into [DeviceControl.openUrl] which uses url_launcher.

class AppIntent {
  final String url;
  final String description;
  const AppIntent(this.url, this.description);
}

class AppIntents {
  /// Resolve a deep link.
  ///
  /// [appName] : youtube|spotify|whatsapp|maps|tel|sms|email|browser
  /// [action]  : search|watch|send|navigate|call|open|track|playlist
  /// [data]    : { query, video_id, phone, text, lat, lng, place, address,
  ///               number, body, to, subject, url, track_id, playlist_id }
  static AppIntent? build({
    required String appName,
    required String action,
    required Map<String, dynamic> data,
  }) {
    final n = appName.toLowerCase().trim();
    final a = action.toLowerCase().trim();
    String? s(String k) => data[k]?.toString();

    switch (n) {
      case 'youtube':
      case 'yt':
        if (a == 'watch' && s('video_id') != null) {
          return AppIntent(
            'https://www.youtube.com/watch?v=${Uri.encodeComponent(s('video_id')!)}',
            'YouTube watch',
          );
        }
        // default: search
        final q = s('query') ?? s('text') ?? '';
        return AppIntent(
          'https://www.youtube.com/results?search_query=${Uri.encodeComponent(q)}',
          'YouTube search "$q"',
        );

      case 'spotify':
        if (a == 'track' && s('track_id') != null) {
          return AppIntent(
            'https://open.spotify.com/track/${Uri.encodeComponent(s('track_id')!)}',
            'Spotify track',
          );
        }
        if (a == 'playlist' && s('playlist_id') != null) {
          return AppIntent(
            'https://open.spotify.com/playlist/${Uri.encodeComponent(s('playlist_id')!)}',
            'Spotify playlist',
          );
        }
        final q = s('query') ?? s('text') ?? '';
        return AppIntent(
          'https://open.spotify.com/search/${Uri.encodeComponent(q)}',
          'Spotify search "$q"',
        );

      case 'whatsapp':
      case 'wa':
        final phone = (s('phone') ?? '').replaceAll(RegExp(r'[^0-9]'), '');
        final text = Uri.encodeComponent(s('text') ?? '');
        if (phone.isEmpty) {
          // Universal WA send (pick contact)
          return AppIntent(
            'https://wa.me/?text=$text',
            'WhatsApp pick contact',
          );
        }
        return AppIntent(
          'https://wa.me/$phone?text=$text',
          'WhatsApp -> +$phone',
        );

      case 'maps':
      case 'map':
        if (a == 'navigate') {
          final dest = s('address') ?? s('place') ?? '';
          if (dest.isNotEmpty) {
            return AppIntent(
              'https://www.google.com/maps/dir/?api=1&destination=${Uri.encodeComponent(dest)}',
              'Maps navigate to $dest',
            );
          }
        }
        // search lat,lng?q=place OR query
        final lat = s('lat');
        final lng = s('lng');
        final place = s('place') ?? s('address') ?? s('query') ?? '';
        if (lat != null && lng != null) {
          return AppIntent(
            'geo:$lat,$lng?q=${Uri.encodeComponent(place)}',
            'Maps geo $lat,$lng',
          );
        }
        return AppIntent(
          'https://www.google.com/maps/search/?api=1&query=${Uri.encodeComponent(place)}',
          'Maps search "$place"',
        );

      case 'tel':
      case 'call':
      case 'phone':
        final number = (s('number') ?? s('phone') ?? '');
        if (number.isEmpty) return null;
        return AppIntent('tel:$number', 'Call $number');

      case 'sms':
        final num = (s('number') ?? s('phone') ?? '');
        final body = Uri.encodeComponent(s('body') ?? s('text') ?? '');
        if (num.isEmpty) return null;
        return AppIntent('sms:$num?body=$body', 'SMS to $num');

      case 'email':
      case 'mailto':
      case 'mail':
        final to = s('to') ?? s('email') ?? '';
        final subject = Uri.encodeComponent(s('subject') ?? '');
        final body = Uri.encodeComponent(s('body') ?? s('text') ?? '');
        if (to.isEmpty) {
          return AppIntent('mailto:?subject=$subject&body=$body',
              'Compose email');
        }
        return AppIntent(
          'mailto:$to?subject=$subject&body=$body',
          'Email to $to',
        );

      case 'browser':
      case 'web':
      case 'url':
        final url = s('url');
        if (url == null || url.isEmpty) return null;
        final clean = url.startsWith('http') ? url : 'https://$url';
        return AppIntent(clean, 'Open $clean');

      default:
        return null;
    }
  }
}

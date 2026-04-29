// SALIX onda 4 — Tabela de deep links contextuais
//
// Este service ESTENDE [AppIntents] (app_intents.dart) com mais aplicativos
// populares no Brasil: Waze, Uber, 99, iFood, Mercado Livre, Instagram, Telegram.
// Cada entrada gera (1) URL nativa do app quando possível e (2) fallback web.
//
// Convenção: `resolve(app, action, data)` retorna [DeepLink] com `.primary`
// (scheme nativo) e `.fallback` (https://). O caller tenta primary; se não
// instalado, abre fallback.
//
// Apps cobertos:
//   waze            navigate { address | lat,lng }
//   uber            request_ride { pickup_lat, pickup_lng, drop_lat, drop_lng,
//                                  drop_address }
//   99              request_ride { drop_address }
//   ifood           search { query } | restaurant { id }
//   mercadolivre    search { query }
//   instagram       profile { user } | open
//   telegram        chat { username | phone } | send { username, text }
//   youtube         (delegado pra AppIntents — mantém compat)
//   spotify         (delegado pra AppIntents — mantém compat)
//   whatsapp        (delegado pra AppIntents — mantém compat)
//   maps            (delegado pra AppIntents — mantém compat)
//
// Apps NÃO cobertos por enquanto (precisam OAuth ou app companion):
//   - Google Home / Alexa / HomeKit: smart home full = Onda futura
//   - Tuya / Smart Life: cada fabricante tem URL scheme próprio,
//     deixar pra quando Roger conectar conta
//   - IR blaster (Xiaomi): plugin flutter_ir_remote depende do device

import 'app_intents.dart';

class DeepLink {
  /// Native scheme (e.g. `waze://?q=...`). Pode falhar se app não instalado.
  final String primary;

  /// HTTPS fallback (sempre abre algo, mesmo no browser).
  final String fallback;

  /// Descrição humana, usada em logs/UI.
  final String description;

  const DeepLink({
    required this.primary,
    required this.fallback,
    required this.description,
  });
}

class DeepLinks {
  /// [appName]: waze | uber | 99 | ifood | mercadolivre | instagram | telegram
  ///           (ou qualquer um delegado pra AppIntents)
  /// [action]: navigate | request_ride | search | profile | chat | send | open
  /// [data]:   campos específicos do app
  static DeepLink? resolve({
    required String appName,
    required String action,
    required Map<String, dynamic> data,
  }) {
    final n = appName.toLowerCase().trim();
    final a = action.toLowerCase().trim();
    String? s(String k) => data[k]?.toString();
    String enc(String? v) => Uri.encodeComponent(v ?? '');

    switch (n) {
      // ---------------------------------------------------------------- Waze
      case 'waze':
        final lat = s('lat');
        final lng = s('lng');
        final address = s('address') ?? s('place') ?? s('query') ?? '';
        if (lat != null && lng != null) {
          return DeepLink(
            primary: 'waze://?ll=$lat,$lng&navigate=yes',
            fallback: 'https://www.waze.com/ul?ll=$lat%2C$lng&navigate=yes',
            description: 'Waze navigate $lat,$lng',
          );
        }
        return DeepLink(
          primary: 'waze://?q=${enc(address)}&navigate=yes',
          fallback: 'https://www.waze.com/ul?q=${enc(address)}&navigate=yes',
          description: 'Waze navigate $address',
        );

      // ---------------------------------------------------------------- Uber
      case 'uber':
        final dropLat = s('drop_lat') ?? s('lat');
        final dropLng = s('drop_lng') ?? s('lng');
        final dropAddr = s('drop_address') ?? s('address') ?? '';
        final pickupLat = s('pickup_lat');
        final pickupLng = s('pickup_lng');
        final params = <String, String>{
          'action': 'setPickup',
          if (pickupLat != null) 'pickup[latitude]': pickupLat,
          if (pickupLng != null) 'pickup[longitude]': pickupLng,
          if (pickupLat == null) 'pickup': 'my_location',
          if (dropLat != null) 'dropoff[latitude]': dropLat,
          if (dropLng != null) 'dropoff[longitude]': dropLng,
          if (dropAddr.isNotEmpty) 'dropoff[nickname]': dropAddr,
        };
        final qs = params.entries
            .map((e) => '${Uri.encodeComponent(e.key)}=${enc(e.value)}')
            .join('&');
        return DeepLink(
          primary: 'uber://?$qs',
          fallback: 'https://m.uber.com/ul/?$qs',
          description: 'Uber pra $dropAddr',
        );

      // ----------------------------------------------------------------- 99
      case '99':
      case 'noventa_e_nove':
        final drop = s('drop_address') ?? s('address') ?? s('destination') ?? '';
        return DeepLink(
          primary: 'taxis99://?dropoff=${enc(drop)}',
          fallback: 'https://99app.com/?dropoff=${enc(drop)}',
          description: '99 pra $drop',
        );

      // -------------------------------------------------------------- iFood
      case 'ifood':
        final q = s('query') ?? s('text') ?? '';
        final id = s('id') ?? s('restaurant_id');
        if (a == 'restaurant' && id != null) {
          return DeepLink(
            primary: 'ifood://restaurant/$id',
            fallback: 'https://www.ifood.com.br/delivery/$id',
            description: 'iFood restaurant $id',
          );
        }
        return DeepLink(
          primary: 'ifood://search?q=${enc(q)}',
          fallback: 'https://www.ifood.com.br/busca?q=${enc(q)}',
          description: 'iFood busca "$q"',
        );

      // -------------------------------------------------------- Mercado Livre
      case 'mercadolivre':
      case 'ml':
        final q = s('query') ?? s('text') ?? '';
        return DeepLink(
          primary: 'meli://search?as_word=${enc(q)}',
          fallback: 'https://lista.mercadolivre.com.br/${enc(q)}',
          description: 'ML busca "$q"',
        );

      // ----------------------------------------------------------- Instagram
      case 'instagram':
      case 'ig':
        final user = (s('user') ?? s('username') ?? '').replaceAll('@', '');
        if (user.isEmpty) {
          return const DeepLink(
            primary: 'instagram://app',
            fallback: 'https://www.instagram.com/',
            description: 'Instagram open',
          );
        }
        return DeepLink(
          primary: 'instagram://user?username=${enc(user)}',
          fallback: 'https://www.instagram.com/${enc(user)}/',
          description: 'IG perfil @$user',
        );

      // ------------------------------------------------------------- Telegram
      case 'telegram':
      case 'tg':
        final user = (s('username') ?? s('user') ?? '').replaceAll('@', '');
        final phone = (s('phone') ?? '').replaceAll(RegExp(r'[^0-9]'), '');
        final text = enc(s('text') ?? s('body') ?? '');
        if (a == 'send' && user.isNotEmpty) {
          return DeepLink(
            primary: 'tg://resolve?domain=$user&text=$text',
            fallback: 'https://t.me/$user?text=$text',
            description: 'Telegram send @$user',
          );
        }
        if (user.isNotEmpty) {
          return DeepLink(
            primary: 'tg://resolve?domain=$user',
            fallback: 'https://t.me/$user',
            description: 'Telegram chat @$user',
          );
        }
        if (phone.isNotEmpty) {
          return DeepLink(
            primary: 'tg://msg?to=$phone&text=$text',
            fallback: 'https://t.me/+$phone',
            description: 'Telegram phone +$phone',
          );
        }
        return const DeepLink(
          primary: 'tg://',
          fallback: 'https://web.telegram.org/',
          description: 'Telegram open',
        );

      // ---------------------------------------------- delegate to AppIntents
      default:
        final ai = AppIntents.build(appName: appName, action: action, data: data);
        if (ai == null) return null;
        return DeepLink(
          primary: ai.url,
          fallback: ai.url, // AppIntents já retorna https quando possível
          description: ai.description,
        );
    }
  }
}

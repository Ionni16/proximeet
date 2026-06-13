// lib/core/linkedin_config.dart
//
// Configurazione per l'integrazione con LinkedIn OAuth2.
//
// Lo `state` anti-CSRF viene generato con Random.secure() e DEVE essere
// verificato al ritorno dal callback (vedi LinkedInWebViewScreen):
// se lo state ricevuto non coincide con quello inviato, il flusso
// viene scartato.
// ─────────────────────────────────────────────────────────────

import 'dart:math';

class LinkedInConfig {
  LinkedInConfig._();

  /// Client ID dalla dashboard LinkedIn Developer.
  /// Nota: il client *secret* NON sta nell'app — vive solo in
  /// Secret Manager lato Cloud Functions (linkedinAuth).
  static const String clientId = '77ldn2lgmzxacy';

  /// Redirect URI registrato su LinkedIn Developer.
  /// Deve coincidere ESATTAMENTE con LINKEDIN_REDIRECT_URI in functions/index.js.
  static const String redirectUri =
      'https://proximeet-5ffe2.web.app/linkedin-callback';

  /// Scopes richiesti (OpenID Connect per profilo + email + foto).
  static const String scope = 'openid profile email';

  static const String _stateChars =
      'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789';

  /// Genera un valore `state` anti-CSRF imprevedibile (32 caratteri
  /// alfanumerici da Random.secure ≈ 190 bit di entropia).
  static String generateState() {
    final rng = Random.secure();
    return List.generate(
      32,
      (_) => _stateChars[rng.nextInt(_stateChars.length)],
    ).join();
  }

  /// URL di autorizzazione OAuth LinkedIn per lo `state` fornito.
  static String authorizationUrl(String state) {
    final params = <String, String>{
      'response_type': 'code',
      'client_id': clientId,
      'redirect_uri': redirectUri,
      'scope': scope,
      'state': state,
    };
    final query = params.entries
        .map((e) =>
            '${Uri.encodeComponent(e.key)}=${Uri.encodeComponent(e.value)}')
        .join('&');
    return 'https://www.linkedin.com/oauth/v2/authorization?$query';
  }
}

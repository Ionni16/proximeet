// lib/core/linkedin_config.dart
//
// Configurazione per l'integrazione con LinkedIn OAuth2.
// ─────────────────────────────────────────────────────────────

class LinkedInConfig {
  LinkedInConfig._();

  /// Client ID dalla dashboard LinkedIn Developer.
  
  static const String clientId = '77ldn2lgmzxacy';

  
  static const String redirectUri = 'https://proximeet-5ffe2.web.app/linkedin-callback';

  /// Scopes richiesti (OpenID Connect per profilo + email + foto)
  static const String scope = 'openid profile email';

  /// URL base per l'autorizzazione OAuth LinkedIn
  static String get authorizationUrl {
    final params = {
      'response_type': 'code',
      'client_id': clientId,
      'redirect_uri': redirectUri,
      'scope': scope,
      'state': DateTime.now().millisecondsSinceEpoch.toString(),
    };
    final query = params.entries
        .map((e) =>
            '${Uri.encodeComponent(e.key)}=${Uri.encodeComponent(e.value)}')
        .join('&');
    return 'https://www.linkedin.com/oauth/v2/authorization?$query';
  }
}

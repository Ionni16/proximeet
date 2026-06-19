import 'dart:math';

class LinkedInAuthRequest {
  final Uri uri;
  final String state;

  const LinkedInAuthRequest({required this.uri, required this.state});
}

class LinkedInConfig {
  LinkedInConfig._();

  static const String clientId = '77ldn2lgmzxacy';
  static const String redirectUri =
      'https://proximeet-5ffe2.web.app/linkedin-callback';
  static const String scope = 'openid profile email';

  static LinkedInAuthRequest createAuthorizationRequest() {
    final state = _randomState();
    final uri = Uri.https('www.linkedin.com', '/oauth/v2/authorization', {
      'response_type': 'code',
      'client_id': clientId,
      'redirect_uri': redirectUri,
      'scope': scope,
      'state': state,
      // Evita che una sessione LinkedIn rimasta nella WebView causi redirect
      // inattesi o l'accesso automatico con l'account sbagliato.
      'prompt': 'select_account',
    });
    return LinkedInAuthRequest(uri: uri, state: state);
  }

  static String _randomState() {
    const chars =
        'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~';
    final random = Random.secure();
    return List.generate(48, (_) => chars[random.nextInt(chars.length)]).join();
  }
}

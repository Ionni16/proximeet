import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../core/linkedin_config.dart';
import '../../core/logger.dart';

class LinkedInAuthCode {
  final String code;
  final String state;
  const LinkedInAuthCode({required this.code, required this.state});
}

class LinkedInWebViewScreen extends StatefulWidget {
  const LinkedInWebViewScreen({super.key});

  @override
  State<LinkedInWebViewScreen> createState() => _LinkedInWebViewScreenState();
}

class _LinkedInWebViewScreenState extends State<LinkedInWebViewScreen> {
  late final WebViewController _controller;
  late final LinkedInAuthRequest _authRequest;

  bool _loading = true;
  bool _handled = false;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _authRequest = LinkedInConfig.createAuthorizationRequest();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(const Color(0xFF050D1E))
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageStarted: (url) {
            if (_isCallback(url)) {
              _processCallbackUrl(url);
              return;
            }
            if (mounted) {
              setState(() {
                _loading = true;
                _errorMessage = null;
              });
            }
          },
          onPageFinished: (_) {
            if (mounted && !_handled) setState(() => _loading = false);
          },
          onWebResourceError: (error) {
            if (_handled || !mounted || error.isForMainFrame != true) return;
            Log.e('LINKEDIN', 'WebView error ${error.errorCode}: ${error.description}');
            setState(() {
              _loading = false;
              _errorMessage =
                  'Impossibile aprire LinkedIn. Controlla la connessione e riprova.';
            });
          },
          onNavigationRequest: (request) {
            if (_isCallback(request.url)) {
              _processCallbackUrl(request.url);
              return NavigationDecision.prevent;
            }
            return NavigationDecision.navigate;
          },
        ),
      );

    _startLogin();
  }

  Future<void> _startLogin() async {
    try {
      // Evita cookie/sessioni OAuth corrotte o rimaste da tentativi precedenti.
      await WebViewCookieManager().clearCookies();
      await _controller.clearCache();
      await _controller.loadRequest(_authRequest.uri);
    } catch (e) {
      Log.e('LINKEDIN', 'Errore avvio OAuth', e);
      if (mounted) {
        setState(() {
          _loading = false;
          _errorMessage = 'Impossibile avviare il login LinkedIn.';
        });
      }
    }
  }

  bool _isCallback(String url) =>
      url.startsWith(LinkedInConfig.redirectUri);

  void _processCallbackUrl(String url) {
    if (_handled) return;

    final uri = Uri.tryParse(url);
    if (uri == null) {
      _showCallbackError('Risposta LinkedIn non valida.');
      return;
    }

    final returnedState = uri.queryParameters['state'];
    final error = uri.queryParameters['error'];
    final errorDescription = uri.queryParameters['error_description'];
    final code = uri.queryParameters['code'];

    if (error != null) {
      _showCallbackError(
        errorDescription?.trim().isNotEmpty == true
            ? errorDescription!
            : 'Accesso LinkedIn annullato o non autorizzato.',
      );
      return;
    }

    // Verifica CSRF: lo state ricevuto deve essere esattamente quello generato
    // prima di aprire la pagina LinkedIn.
    if (returnedState == null || returnedState != _authRequest.state) {
      _showCallbackError('Verifica di sicurezza LinkedIn non riuscita. Riprova.');
      return;
    }

    if (code == null || code.trim().isEmpty) {
      _showCallbackError('LinkedIn non ha restituito il codice di accesso.');
      return;
    }

    _handled = true;
    if (mounted) {
      Navigator.of(context).pop(
        LinkedInAuthCode(code: code, state: returnedState),
      );
    }
  }

  void _showCallbackError(String message) {
    if (_handled || !mounted) return;
    setState(() {
      _loading = false;
      _errorMessage = message;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF050D1E),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0D1B30),
        foregroundColor: const Color(0xFFE8F0FE),
        title: const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _LinkedInIcon(),
            SizedBox(width: 10),
            Text(
              'Accedi con LinkedIn',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
            ),
          ],
        ),
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: () => Navigator.of(context).pop(null),
        ),
      ),
      body: Stack(
        children: [
          WebViewWidget(controller: _controller),
          if (_loading)
            const ColoredBox(
              color: Color(0xFF050D1E),
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _LinkedInIcon(size: 48),
                    SizedBox(height: 20),
                    CircularProgressIndicator(
                      color: Color(0xFF0A66C2),
                      strokeWidth: 2.5,
                    ),
                    SizedBox(height: 16),
                    Text(
                      'Connessione a LinkedIn...',
                      style: TextStyle(color: Color(0xFF8BA3C7), fontSize: 14),
                    ),
                  ],
                ),
              ),
            ),
          if (_errorMessage != null)
            ColoredBox(
              color: const Color(0xFF050D1E),
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.all(28),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.error_outline,
                          color: Color(0xFFFF6B6B), size: 48),
                      const SizedBox(height: 16),
                      Text(
                        _errorMessage!,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          color: Color(0xFFE8F0FE),
                          fontSize: 15,
                        ),
                      ),
                      const SizedBox(height: 20),
                      FilledButton.icon(
                        onPressed: () {
                          setState(() {
                            _errorMessage = null;
                            _loading = true;
                            _handled = false;
                          });
                          _startLogin();
                        },
                        icon: const Icon(Icons.refresh),
                        label: const Text('Riprova'),
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _LinkedInIcon extends StatelessWidget {
  final double size;
  const _LinkedInIcon({this.size = 22});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: const Color(0xFF0A66C2),
        borderRadius: BorderRadius.circular(size * 0.2),
      ),
      child: Center(
        child: Text(
          'in',
          style: TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.w900,
            fontSize: size * 0.52,
            letterSpacing: -0.5,
          ),
        ),
      ),
    );
  }
}

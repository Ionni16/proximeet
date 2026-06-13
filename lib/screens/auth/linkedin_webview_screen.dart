// lib/screens/auth/linkedin_webview_screen.dart
//
// Schermata WebView che gestisce il flusso OAuth di LinkedIn.
// Intercetta il redirect URI, VERIFICA lo `state` anti-CSRF e
// restituisce il codice autorizzativo.
//
// Sicurezza: lo `state` viene generato qui con Random.secure() e
// confrontato con quello restituito da LinkedIn nel callback. Se non
// coincidono il flusso è scartato (possibile tentativo CSRF / replay).
//
// FIX ANDROID: su Android, WebView NON chiama onNavigationRequest per i
// redirect HTTP 302 lato server (limitazione di shouldOverrideUrlLoading).
// La soluzione è intercettare il redirect anche in onPageStarted, che
// viene sempre chiamato indipendentemente dall'origine della navigazione.
// Il flag _handled evita doppia elaborazione nei casi in cui entrambi
// i callback scattano (es. iOS).

import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../core/linkedin_config.dart';
import '../../core/logger.dart';

/// Risultato del flusso OAuth LinkedIn.
/// Lo `state` è già stato verificato: chi riceve questo oggetto
/// può usare direttamente `code`.
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
  static const _tag = 'LINKEDIN-OAUTH';

  late final WebViewController _controller;

  /// State anti-CSRF generato per QUESTA sessione di login.
  late final String _expectedState;

  bool _loading = true;
  bool _handled = false; // evita callback doppi (onPageStarted + onNavigationRequest)

  @override
  void initState() {
    super.initState();

    _expectedState = LinkedInConfig.generateState();

    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageStarted: (url) {
            // ── FIX ANDROID ──────────────────────────────────────────────
            // Su Android i redirect HTTP 302 non passano per
            // onNavigationRequest. onPageStarted invece scatta sempre,
            // quindi intercettiamo qui.
            if (url.startsWith(LinkedInConfig.redirectUri)) {
              _processCallbackUrl(url);
              return;
            }
            setState(() => _loading = true);
          },
          onPageFinished: (_) => setState(() => _loading = false),
          onWebResourceError: (error) {
            // Se il redirect è già stato gestito, ignoriamo gli errori
            // del caricamento della pagina linkedin-callback (che può
            // non esistere come pagina reale).
            if (_handled) return;
            if (error.errorType == WebResourceErrorType.hostLookup ||
                error.errorType == WebResourceErrorType.connect) {
              setState(() => _loading = false);
            }
          },
          onNavigationRequest: (request) {
            // ── iOS / user-initiated navigation ──────────────────────────
            // Su iOS questo scatta anche per i redirect. Su Android solo
            // per navigazioni avviate dall'utente o da JavaScript.
            return _handleNavigationRequest(request.url);
          },
        ),
      )
      ..loadRequest(Uri.parse(LinkedInConfig.authorizationUrl(_expectedState)));
  }

  // ── Logica comune ────────────────────────────────────────────────────

  /// Estrae il codice OAuth dall'URL di callback, verifica lo `state`
  /// e chiude il WebView. Chiamato sia da onPageStarted che da
  /// onNavigationRequest.
  void _processCallbackUrl(String url) {
    if (_handled) return;
    _handled = true;

    final uri = Uri.parse(url);
    final code = uri.queryParameters['code'];
    final state = uri.queryParameters['state'];
    final error = uri.queryParameters['error'];

    if (!mounted) return;

    if (error != null) {
      // L'utente ha annullato o LinkedIn ha restituito un errore.
      Log.w(_tag, 'Callback con errore: $error');
      Navigator.of(context).pop(null);
      return;
    }

    // ── Verifica anti-CSRF ───────────────────────────────────────────
    // Lo state DEVE coincidere con quello che abbiamo generato noi.
    // Un mismatch indica una risposta non originata da questa sessione.
    if (state == null || state != _expectedState) {
      Log.e(_tag, 'State OAuth non valido: flusso scartato (possibile CSRF)');
      Navigator.of(context).pop(null);
      return;
    }

    if (code != null && code.isNotEmpty) {
      Navigator.of(context).pop(LinkedInAuthCode(code: code, state: state));
    } else {
      Navigator.of(context).pop(null);
    }
  }

  NavigationDecision _handleNavigationRequest(String url) {
    if (url.startsWith(LinkedInConfig.redirectUri)) {
      _processCallbackUrl(url);
      return NavigationDecision.prevent;
    }
    // Tutte le altre URL (pagine LinkedIn) → naviga normalmente.
    return NavigationDecision.navigate;
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
            Container(
              color: const Color(0xFF050D1E),
              child: const Center(
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
                      style: TextStyle(
                        color: Color(0xFF8BA3C7),
                        fontSize: 14,
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Icona LinkedIn inline (non dipende da asset esterni).
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

// lib/screens/splash_screen.dart
//
// Splash screen Flutter animata — mostrata mentre Firebase si inizializza
// e durante il check auth state. Dopo l'animazione naviga automaticamente
// a LoginScreen o EventListScreen in base allo stato auth.
//
// Sequenza animazioni:
//   0ms   → sfondo navy appare
//   200ms → anelli orbitanti iniziano a girare
//   400ms → logo scala da 0 a 1 con glow
//   700ms → "ProxiMeet" slide up + fade in
//   900ms → tagline fade in
//  1200ms → barra di caricamento pulse
//  2200ms → se auth pronto, transizione out verso la destinazione

import 'dart:math' show sin, cos, pi;
import 'package:flutter/material.dart';

class SplashScreen extends StatefulWidget {
  final Widget destination;
  final VoidCallback? onComplete;

  const SplashScreen({
    super.key,
    required this.destination,
    this.onComplete,
  });

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen>
    with TickerProviderStateMixin {
  // Anelli orbitanti — loop continuo
  late final AnimationController _orbitCtrl;

  // Logo scale + opacity
  late final AnimationController _logoCtrl;
  late final Animation<double> _logoScale;
  late final Animation<double> _logoOpacity;
  late final Animation<double> _glowOpacity;

  // Testo slide up
  late final AnimationController _textCtrl;
  late final Animation<Offset> _titleOffset;
  late final Animation<double> _titleOpacity;
  late final Animation<double> _taglineOpacity;

  // Barra pulse
  late final AnimationController _pulseCtrl;

  // Fade out verso destinazione
  late final AnimationController _exitCtrl;
  late final Animation<double> _exitOpacity;

  bool _navigating = false;

  @override
  void initState() {
    super.initState();

    // ── Orbit ──────────────────────────────────────────────────────────────────
    _orbitCtrl = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 10),
    )..repeat();

    // ── Logo ───────────────────────────────────────────────────────────────────
    _logoCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 700),
    );
    _logoScale = CurvedAnimation(
      parent: _logoCtrl,
      curve: Curves.elasticOut,
    );
    _logoOpacity = Tween<double>(begin: 0, end: 1).animate(
      CurvedAnimation(
        parent: _logoCtrl,
        curve: const Interval(0, 0.4, curve: Curves.easeIn),
      ),
    );
    _glowOpacity = Tween<double>(begin: 0, end: 1).animate(
      CurvedAnimation(
        parent: _logoCtrl,
        curve: const Interval(0.3, 1, curve: Curves.easeOut),
      ),
    );

    // ── Testo ──────────────────────────────────────────────────────────────────
    _textCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    );
    _titleOffset = Tween<Offset>(
      begin: const Offset(0, 0.5),
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: _textCtrl, curve: Curves.easeOutCubic));
    _titleOpacity = Tween<double>(begin: 0, end: 1).animate(
      CurvedAnimation(
          parent: _textCtrl,
          curve: const Interval(0, 0.6, curve: Curves.easeIn)),
    );
    _taglineOpacity = Tween<double>(begin: 0, end: 1).animate(
      CurvedAnimation(
          parent: _textCtrl,
          curve: const Interval(0.4, 1, curve: Curves.easeIn)),
    );

    // ── Pulse ──────────────────────────────────────────────────────────────────
    _pulseCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    )..repeat(reverse: true);

    // ── Exit ───────────────────────────────────────────────────────────────────
    _exitCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 400),
    );
    _exitOpacity = Tween<double>(begin: 1, end: 0).animate(
      CurvedAnimation(parent: _exitCtrl, curve: Curves.easeIn),
    );

    // ── Sequenza ───────────────────────────────────────────────────────────────
    _runSequence();
  }

  Future<void> _runSequence() async {
    await Future.delayed(const Duration(milliseconds: 300));
    if (!mounted) return;
    await _logoCtrl.forward();

    await Future.delayed(const Duration(milliseconds: 150));
    if (!mounted) return;
    await _textCtrl.forward();

    // La splash rimane visibile almeno 1.8s totali dall'avvio
    await Future.delayed(const Duration(milliseconds: 900));
    if (!mounted) return;

    _navigate();
  }

  void _navigate() {
    if (_navigating || !mounted) return;
    _navigating = true;
    _exitCtrl.forward().then((_) {
      if (!mounted) return;
      widget.onComplete?.call();
      if (widget.onComplete == null) {
        Navigator.of(context).pushReplacement(
          PageRouteBuilder(
            pageBuilder: (_, __, ___) => widget.destination,
            transitionDuration: const Duration(milliseconds: 500),
            transitionsBuilder: (_, animation, __, child) => FadeTransition(
              opacity: animation,
              child: child,
            ),
          ),
        );
      }
    });
  }

  @override
  void dispose() {
    _orbitCtrl.dispose();
    _logoCtrl.dispose();
    _textCtrl.dispose();
    _pulseCtrl.dispose();
    _exitCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;

    return Scaffold(
      backgroundColor: const Color(0xFF060D1A),
      body: FadeTransition(
        opacity: _exitOpacity,
        child: Stack(
          alignment: Alignment.center,
          children: [
            // ── Sfondo orbitante ──────────────────────────────────────────────
            Positioned.fill(
              child: AnimatedBuilder(
                animation: _orbitCtrl,
                builder: (_, __) => CustomPaint(
                  painter: _OrbitPainter(
                    progress: _orbitCtrl.value,
                    centerY: 0.42,
                  ),
                ),
              ),
            ),

            // ── Glow radiale ──────────────────────────────────────────────────
            AnimatedBuilder(
              animation: _glowOpacity,
              builder: (_, __) => Opacity(
                opacity: _glowOpacity.value,
                child: Container(
                  width: size.width * 0.85,
                  height: size.width * 0.85,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: RadialGradient(
                      colors: [
                        const Color(0xFF1A56DB).withOpacity(0.22),
                        const Color(0xFF1A56DB).withOpacity(0.08),
                        Colors.transparent,
                      ],
                      stops: const [0, 0.45, 1],
                    ),
                  ),
                ),
              ),
            ),

            // ── Contenuto centrato ────────────────────────────────────────────
            Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const SizedBox(height: 0),

                // Logo
                ScaleTransition(
                  scale: _logoScale,
                  child: FadeTransition(
                    opacity: _logoOpacity,
                    child: AnimatedBuilder(
                      animation: _pulseCtrl,
                      builder: (_, child) {
                        final pulse = _pulseCtrl.value;
                        return Container(
                          width: 96,
                          height: 96,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: const Color(0xFF0D1B30),
                            border: Border.all(
                              color: const Color(0xFF4D8EF7)
                                  .withOpacity(0.25 + 0.2 * pulse),
                              width: 1.5,
                            ),
                            boxShadow: [
                              BoxShadow(
                                color: const Color(0xFF1A56DB)
                                    .withOpacity(0.3 + 0.2 * pulse),
                                blurRadius: 32 + 16 * pulse,
                                spreadRadius: 2 + 2 * pulse,
                              ),
                              BoxShadow(
                                color: const Color(0xFF4D8EF7)
                                    .withOpacity(0.08 + 0.06 * pulse),
                                blurRadius: 60,
                                spreadRadius: 8,
                              ),
                            ],
                          ),
                          child: child,
                        );
                      },
                      child: const Icon(
                        Icons.wifi_tethering_rounded,
                        size: 44,
                        color: Color(0xFF4D8EF7),
                      ),
                    ),
                  ),
                ),

                const SizedBox(height: 28),

                // Titolo
                SlideTransition(
                  position: _titleOffset,
                  child: FadeTransition(
                    opacity: _titleOpacity,
                    child: const Text(
                      'ProxiMeet',
                      style: TextStyle(
                        fontSize: 36,
                        fontWeight: FontWeight.w800,
                        letterSpacing: -1.2,
                        color: Color(0xFFE8F0FE),
                        height: 1,
                      ),
                    ),
                  ),
                ),

                const SizedBox(height: 10),

                // Tagline
                FadeTransition(
                  opacity: _taglineOpacity,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 20,
                        height: 1,
                        color: const Color(0xFF4D8EF7).withOpacity(0.4),
                      ),
                      const SizedBox(width: 10),
                      Text(
                        'Networking di prossimità',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w400,
                          letterSpacing: 0.8,
                          color: const Color(0xFF8BA3C7).withOpacity(0.85),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Container(
                        width: 20,
                        height: 1,
                        color: const Color(0xFF4D8EF7).withOpacity(0.4),
                      ),
                    ],
                  ),
                ),

                const SizedBox(height: 64),

                // Indicatore di caricamento — 3 dot pulse sfasati
                FadeTransition(
                  opacity: _taglineOpacity,
                  child: _ThreeDotsLoader(),
                ),
              ],
            ),

            // ── Badge versione in basso ────────────────────────────────────────
            Positioned(
              bottom: 40,
              child: FadeTransition(
                opacity: _taglineOpacity,
                child: Text(
                  'Powered by BLE · Made in Italy',
                  style: TextStyle(
                    fontSize: 11,
                    color: const Color(0xFF4A6080).withOpacity(0.6),
                    letterSpacing: 0.5,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Tre punti animati sfasati ─────────────────────────────────────────────────

class _ThreeDotsLoader extends StatefulWidget {
  @override
  State<_ThreeDotsLoader> createState() => _ThreeDotsLoaderState();
}

class _ThreeDotsLoaderState extends State<_ThreeDotsLoader>
    with TickerProviderStateMixin {
  late final List<AnimationController> _ctrls;
  late final List<Animation<double>> _anims;

  @override
  void initState() {
    super.initState();
    _ctrls = List.generate(
      3,
      (i) => AnimationController(
        vsync: this,
        duration: const Duration(milliseconds: 600),
      ),
    );
    _anims = _ctrls
        .map((c) => Tween<double>(begin: 0, end: 1).animate(
              CurvedAnimation(parent: c, curve: Curves.easeInOut),
            ))
        .toList();

    for (int i = 0; i < 3; i++) {
      Future.delayed(Duration(milliseconds: i * 180), () {
        if (mounted) _ctrls[i].repeat(reverse: true);
      });
    }
  }

  @override
  void dispose() {
    for (final c in _ctrls) c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: List.generate(3, (i) {
        return AnimatedBuilder(
          animation: _anims[i],
          builder: (_, __) => Container(
            margin: const EdgeInsets.symmetric(horizontal: 4),
            width: 6,
            height: 6,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: const Color(0xFF4D8EF7)
                  .withOpacity(0.25 + 0.75 * _anims[i].value),
              boxShadow: [
                BoxShadow(
                  color: const Color(0xFF4D8EF7)
                      .withOpacity(0.3 * _anims[i].value),
                  blurRadius: 8,
                ),
              ],
            ),
          ),
        );
      }),
    );
  }
}

// ── Painter sfondo orbitante ──────────────────────────────────────────────────

class _OrbitPainter extends CustomPainter {
  final double progress;
  final double centerY;

  _OrbitPainter({required this.progress, required this.centerY});

  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width * 0.5;
    final cy = size.height * centerY;

    // Glow sfondo
    final bgGlow = Paint()
      ..shader = RadialGradient(
        colors: [
          const Color(0xFF1A56DB).withOpacity(0.10),
          Colors.transparent,
        ],
      ).createShader(
          Rect.fromCircle(center: Offset(cx, cy), radius: size.width * 0.6));
    canvas.drawCircle(Offset(cx, cy), size.width * 0.6, bgGlow);

    // Anelli con nodi
    final rings = [
      (size.width * 0.28, 0.07, 4, 1.0,  0.0),
      (size.width * 0.44, 0.05, 6, -0.7, 1.1),
      (size.width * 0.60, 0.03, 8, 0.5,  2.3),
      (size.width * 0.76, 0.02, 5, -0.3, 0.7),
    ];

    for (final (r, opacity, nodeCount, speed, phase) in rings) {
      // Anello
      final ringPaint = Paint()
        ..color = const Color(0xFF4D8EF7).withOpacity(opacity)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.6;
      canvas.drawCircle(Offset(cx, cy), r, ringPaint);

      // Nodi
      for (int i = 0; i < nodeCount; i++) {
        final angle =
            (2 * pi * i / nodeCount) + (2 * pi * progress * speed) + phase;
        final nx = cx + r * cos(angle);
        final ny = cy + r * sin(angle);

        // Nodo principale
        canvas.drawCircle(
          Offset(nx, ny),
          1.8,
          Paint()..color = const Color(0xFF4D8EF7).withOpacity(opacity * 5),
        );

        // Alone del nodo
        canvas.drawCircle(
          Offset(nx, ny),
          4,
          Paint()
            ..color = const Color(0xFF4D8EF7).withOpacity(opacity * 1.5)
            ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3),
        );
      }
    }
  }

  @override
  bool shouldRepaint(_OrbitPainter old) => old.progress != progress;
}

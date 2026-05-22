// lib/screens/auth/login_screen.dart
// Design: Premium dark networking app — deep navy, electric blue accents,
// particle-like animated rings, glassmorphism card.

import 'dart:math' show sin, cos, pi;
import 'package:flutter/material.dart';
import '../../services/auth_service.dart';
import '../../core/logger.dart';
import 'register_screen.dart';
import 'linkedin_webview_screen.dart';
import 'linkedin_complete_profile_screen.dart';
import '../events/event_list_screen.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});
  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen>
    with TickerProviderStateMixin {
  final _formKey        = GlobalKey<FormState>();
  final _emailCtrl      = TextEditingController();
  final _passwordCtrl   = TextEditingController();
  final _authService    = AuthService.instance;

  late final AnimationController _orbitCtrl;
  late final AnimationController _fadeCtrl;

  bool _loading         = false;
  bool _linkedInLoading = false;
  bool _obscurePassword = true;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _orbitCtrl = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 12),
    )..repeat();
    _fadeCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..forward();
  }

  @override
  void dispose() {
    _emailCtrl.dispose();
    _passwordCtrl.dispose();
    _orbitCtrl.dispose();
    _fadeCtrl.dispose();
    super.dispose();
  }

  // ── Auth ─────────────────────────────────────────────────────────────────────

  Future<void> _login() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() { _loading = true; _errorMessage = null; });
    try {
      await _authService.login(
        _emailCtrl.text.trim(),
        _passwordCtrl.text.trim(),
      );
    } catch (e) {
      setState(() => _errorMessage = 'Email o password errati');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _loginWithLinkedIn() async {
    setState(() { _linkedInLoading = true; _errorMessage = null; });
    try {
      final result = await Navigator.of(context).push<LinkedInAuthCode>(
        MaterialPageRoute(
          fullscreenDialog: true,
          builder: (_) => const LinkedInWebViewScreen(),
        ),
      );
      if (result == null || !mounted) {
        setState(() => _linkedInLoading = false);
        return;
      }
      final signInResult = await _authService.signInWithLinkedIn(result.code);
      if (!mounted) return;

      if (signInResult.isNewUser) {
        if (!mounted) return;
        await Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => LinkedInCompleteProfileScreen(
              linkedInProfile: signInResult.linkedInProfile,
            ),
          ),
        );
        return;
      }

      if (!mounted) return;
      final uid = _authService.currentUser?.uid;
      if (uid != null) {
        final existingProfile = await _authService.getUserProfile(uid);
        final needsCompletion = existingProfile == null ||
            existingProfile.uid.isEmpty ||
            existingProfile.company.isEmpty ||
            existingProfile.role.isEmpty;
        if (!mounted) return;
        if (needsCompletion) {
          Log.d('LOGIN', 'Profilo LinkedIn incompleto, redirect a completamento');
          await Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => LinkedInCompleteProfileScreen(
                linkedInProfile: signInResult.linkedInProfile,
              ),
            ),
          );
        } else {
          Navigator.of(context).pushAndRemoveUntil(
            MaterialPageRoute(builder: (_) => const EventListScreen()),
            (route) => false,
          );
        }
      }
    } catch (e) {
      Log.e('LOGIN', 'Errore LinkedIn login', e);
      if (mounted) setState(() => _errorMessage = 'Errore accesso con LinkedIn. Riprova.');
    } finally {
      if (mounted) setState(() => _linkedInLoading = false);
    }
  }

  // ── Build ─────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF060D1A),
      body: Stack(
        children: [
          // ── Sfondo animato ──────────────────────────────────────────────────
          Positioned.fill(child: _AnimatedBackground(controller: _orbitCtrl)),

          // ── Contenuto ───────────────────────────────────────────────────────
          SafeArea(
            child: FadeTransition(
              opacity: _fadeCtrl,
              child: SingleChildScrollView(
                physics: const ClampingScrollPhysics(),
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Form(
                  key: _formKey,
                  child: Column(
                    children: [
                      const SizedBox(height: 52),

                      // ── Logo ────────────────────────────────────────────────
                      _LogoSection(controller: _orbitCtrl),

                      const SizedBox(height: 44),

                      // ── LinkedIn ────────────────────────────────────────────
                      _LinkedInButton(
                        loading: _linkedInLoading,
                        onPressed: (_loading || _linkedInLoading)
                            ? null
                            : _loginWithLinkedIn,
                      ),

                      const SizedBox(height: 24),

                      // ── Divisore ────────────────────────────────────────────
                      Row(
                        children: [
                          Expanded(
                            child: Container(
                              height: 1,
                              decoration: BoxDecoration(
                                gradient: LinearGradient(
                                  colors: [
                                    Colors.transparent,
                                    const Color(0xFF1E3050),
                                  ],
                                ),
                              ),
                            ),
                          ),
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 14),
                            child: Text(
                              'oppure',
                              style: TextStyle(
                                color: const Color(0xFF4A6080).withOpacity(0.8),
                                fontSize: 12,
                                letterSpacing: 0.5,
                              ),
                            ),
                          ),
                          Expanded(
                            child: Container(
                              height: 1,
                              decoration: BoxDecoration(
                                gradient: LinearGradient(
                                  colors: [
                                    const Color(0xFF1E3050),
                                    Colors.transparent,
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),

                      const SizedBox(height: 24),

                      // ── Form card ───────────────────────────────────────────
                      _LoginCard(
                        emailCtrl: _emailCtrl,
                        passwordCtrl: _passwordCtrl,
                        obscurePassword: _obscurePassword,
                        onToggleObscure: () =>
                            setState(() => _obscurePassword = !_obscurePassword),
                        errorMessage: _errorMessage,
                        loading: _loading,
                        onLogin: _login,
                      ),

                      const SizedBox(height: 28),

                      // ── Registrazione ───────────────────────────────────────
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Text(
                            'Non hai un account? ',
                            style: TextStyle(
                              color: const Color(0xFF4A6080),
                              fontSize: 13,
                            ),
                          ),
                          GestureDetector(
                            onTap: () => Navigator.push(
                              context,
                              MaterialPageRoute(
                                  builder: (_) => const RegisterScreen()),
                            ),
                            child: const Text(
                              'Registrati',
                              style: TextStyle(
                                color: Color(0xFF4D8EF7),
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ],
                      ),

                      const SizedBox(height: 40),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ── Sfondo animato ────────────────────────────────────────────────────────────

class _AnimatedBackground extends StatelessWidget {
  final AnimationController controller;
  const _AnimatedBackground({required this.controller});

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (_, __) => CustomPaint(
        painter: _BackgroundPainter(controller.value),
      ),
    );
  }
}

class _BackgroundPainter extends CustomPainter {
  final double t;
  _BackgroundPainter(this.t);

  @override
  void paint(Canvas canvas, Size size) {
    // Sfondo base
    final bgPaint = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: const [Color(0xFF060D1A), Color(0xFF071428)],
      ).createShader(Rect.fromLTWH(0, 0, size.width, size.height));
    canvas.drawRect(Rect.fromLTWH(0, 0, size.width, size.height), bgPaint);

    final cx = size.width * 0.5;
    final cy = size.height * 0.28;

    // Glow centrale
    final glowPaint = Paint()
      ..shader = RadialGradient(
        colors: [
          const Color(0xFF1A56DB).withOpacity(0.18),
          const Color(0xFF1A56DB).withOpacity(0.06),
          Colors.transparent,
        ],
        stops: const [0, 0.4, 1],
      ).createShader(Rect.fromCircle(
          center: Offset(cx, cy), radius: size.width * 0.7));
    canvas.drawCircle(Offset(cx, cy), size.width * 0.7, glowPaint);

    // Anelli orbitanti
    final ringData = [
      (0.32, 0.10, 5, 0.0),
      (0.50, 0.06, 7, 0.3),
      (0.68, 0.04, 9, 0.6),
    ];

    for (final (radiusRatio, opacity, nodeCount, phaseOffset) in ringData) {
      final r = size.width * radiusRatio;
      final ringPaint = Paint()
        ..color = const Color(0xFF4D8EF7).withOpacity(opacity)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.5;
      canvas.drawCircle(Offset(cx, cy), r, ringPaint);

      // Nodi sugli anelli
      for (int i = 0; i < nodeCount; i++) {
        final angle = (2 * pi * i / nodeCount) +
            (2 * pi * t * (radiusRatio > 0.5 ? -1 : 1)) +
            phaseOffset;
        final nx = cx + r * cos(angle);
        final ny = cy + r * sin(angle);
        final nodePaint = Paint()
          ..color = const Color(0xFF4D8EF7).withOpacity(opacity * 4);
        canvas.drawCircle(Offset(nx, ny), 1.5, nodePaint);
      }
    }
  }

  @override
  bool shouldRepaint(_BackgroundPainter old) => old.t != t;
}

// ── Logo section ──────────────────────────────────────────────────────────────

class _LogoSection extends StatelessWidget {
  final AnimationController controller;
  const _LogoSection({required this.controller});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        AnimatedBuilder(
          animation: controller,
          builder: (_, child) {
            final pulse = 0.5 + 0.5 * sin(controller.value * 2 * pi);
            return Container(
              width: 80,
              height: 80,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: const Color(0xFF0D1B30),
                border: Border.all(
                  color: const Color(0xFF4D8EF7).withOpacity(0.2 + 0.25 * pulse),
                  width: 1.5,
                ),
                boxShadow: [
                  BoxShadow(
                    color: const Color(0xFF1A56DB).withOpacity(0.25 + 0.15 * pulse),
                    blurRadius: 28 + 10 * pulse,
                    spreadRadius: 1,
                  ),
                ],
              ),
              child: child,
            );
          },
          child: const Icon(
            Icons.wifi_tethering_rounded,
            size: 36,
            color: Color(0xFF4D8EF7),
          ),
        ),
        const SizedBox(height: 18),
        const Text(
          'ProxiMeet',
          style: TextStyle(
            fontSize: 30,
            fontWeight: FontWeight.w800,
            letterSpacing: -0.8,
            color: Color(0xFFE8F0FE),
          ),
        ),
        const SizedBox(height: 5),
        Text(
          'Networking di prossimità',
          style: TextStyle(
            fontSize: 13,
            color: const Color(0xFF8BA3C7).withOpacity(0.8),
            letterSpacing: 0.3,
          ),
        ),
      ],
    );
  }
}

// ── LinkedIn button ───────────────────────────────────────────────────────────

class _LinkedInButton extends StatelessWidget {
  final bool loading;
  final VoidCallback? onPressed;
  const _LinkedInButton({required this.loading, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onPressed,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        height: 54,
        decoration: BoxDecoration(
          color: const Color(0xFF0A66C2),
          borderRadius: BorderRadius.circular(14),
          boxShadow: onPressed != null
              ? [
                  BoxShadow(
                    color: const Color(0xFF0A66C2).withOpacity(0.4),
                    blurRadius: 20,
                    offset: const Offset(0, 6),
                  ),
                ]
              : [],
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (loading)
              const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(
                    strokeWidth: 2, color: Colors.white),
              )
            else ...[
              Container(
                width: 24,
                height: 24,
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(4),
                ),
                child: const Center(
                  child: Text(
                    'in',
                    style: TextStyle(
                      color: Color(0xFF0A66C2),
                      fontWeight: FontWeight.w900,
                      fontSize: 12,
                      letterSpacing: -0.5,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              const Text(
                'Continua con LinkedIn',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.1,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

// ── Login card ────────────────────────────────────────────────────────────────

class _LoginCard extends StatelessWidget {
  final TextEditingController emailCtrl;
  final TextEditingController passwordCtrl;
  final bool obscurePassword;
  final VoidCallback onToggleObscure;
  final String? errorMessage;
  final bool loading;
  final VoidCallback onLogin;

  const _LoginCard({
    required this.emailCtrl,
    required this.passwordCtrl,
    required this.obscurePassword,
    required this.onToggleObscure,
    required this.errorMessage,
    required this.loading,
    required this.onLogin,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(22),
      decoration: BoxDecoration(
        color: const Color(0xFF0A1628).withOpacity(0.85),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: const Color(0xFF1A2D47), width: 1),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.3),
            blurRadius: 30,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Accedi con email',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w700,
              color: Color(0xFFE8F0FE),
              letterSpacing: -0.2,
            ),
          ),
          const SizedBox(height: 18),

          // Email
          _PremiumField(
            controller: emailCtrl,
            label: 'Email',
            icon: Icons.alternate_email,
            keyboardType: TextInputType.emailAddress,
            validator: (v) {
              if (v == null || v.trim().isEmpty) return 'Inserisci email';
              if (!v.contains('@')) return 'Email non valida';
              return null;
            },
          ),
          const SizedBox(height: 12),

          // Password
          _PremiumField(
            controller: passwordCtrl,
            label: 'Password',
            icon: Icons.lock_outline_rounded,
            obscure: obscurePassword,
            onToggleObscure: onToggleObscure,
            validator: (v) =>
                (v == null || v.isEmpty) ? 'Inserisci password' : null,
          ),

          // Errore
          if (errorMessage != null) ...[
            const SizedBox(height: 14),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: const Color(0xFF4A1010).withOpacity(0.6),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                    color: const Color(0xFFEF5350).withOpacity(0.3)),
              ),
              child: Row(
                children: [
                  const Icon(Icons.error_outline,
                      color: Color(0xFFEF5350), size: 15),
                  const SizedBox(width: 8),
                  Text(
                    errorMessage!,
                    style: const TextStyle(
                        color: Color(0xFFEF9A9A), fontSize: 12.5),
                  ),
                ],
              ),
            ),
          ],

          const SizedBox(height: 18),

          // Bottone login
          GestureDetector(
            onTap: loading ? null : onLogin,
            child: Container(
              height: 50,
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: loading
                      ? [const Color(0xFF1A2D47), const Color(0xFF1A2D47)]
                      : [const Color(0xFF1A56DB), const Color(0xFF3D7BF0)],
                  begin: Alignment.centerLeft,
                  end: Alignment.centerRight,
                ),
                borderRadius: BorderRadius.circular(12),
                boxShadow: loading
                    ? []
                    : [
                        BoxShadow(
                          color: const Color(0xFF1A56DB).withOpacity(0.4),
                          blurRadius: 16,
                          offset: const Offset(0, 5),
                        ),
                      ],
              ),
              child: Center(
                child: loading
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white),
                      )
                    : const Text(
                        'Accedi',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                          letterSpacing: 0.2,
                        ),
                      ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ── Campo input premium ───────────────────────────────────────────────────────

class _PremiumField extends StatelessWidget {
  final TextEditingController controller;
  final String label;
  final IconData icon;
  final TextInputType keyboardType;
  final bool obscure;
  final VoidCallback? onToggleObscure;
  final String? Function(String?)? validator;

  const _PremiumField({
    required this.controller,
    required this.label,
    required this.icon,
    this.keyboardType = TextInputType.text,
    this.obscure = false,
    this.onToggleObscure,
    this.validator,
  });

  @override
  Widget build(BuildContext context) {
    return TextFormField(
      controller: controller,
      keyboardType: keyboardType,
      obscureText: obscure,
      autovalidateMode: AutovalidateMode.onUserInteraction,
      textInputAction: TextInputAction.next,
      style: const TextStyle(color: Color(0xFFE8F0FE), fontSize: 14.5),
      decoration: InputDecoration(
        labelText: label,
        labelStyle: const TextStyle(color: Color(0xFF4A6080), fontSize: 13.5),
        prefixIcon: Icon(icon, size: 18, color: const Color(0xFF4A6080)),
        suffixIcon: onToggleObscure != null
            ? IconButton(
                icon: Icon(
                  obscure
                      ? Icons.visibility_outlined
                      : Icons.visibility_off_outlined,
                  size: 18,
                  color: const Color(0xFF4A6080),
                ),
                onPressed: onToggleObscure,
              )
            : null,
        filled: true,
        fillColor: const Color(0xFF0D1B30),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: Color(0xFF1A2D47)),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: Color(0xFF1A2D47)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: Color(0xFF4D8EF7), width: 1.5),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide:
              const BorderSide(color: Color(0xFFEF5350), width: 1),
        ),
        focusedErrorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide:
              const BorderSide(color: Color(0xFFEF5350), width: 1.5),
        ),
        errorStyle: const TextStyle(fontSize: 11),
      ),
      validator: validator,
    );
  }
}

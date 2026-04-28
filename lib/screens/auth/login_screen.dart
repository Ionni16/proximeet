import 'dart:math' show sin, pi;
import 'package:flutter/material.dart';
import '../../services/auth_service.dart';
import 'register_screen.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen>
    with SingleTickerProviderStateMixin {
  final _formKey = GlobalKey<FormState>();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _authService = AuthService.instance;

  late final AnimationController _pulseCtrl;

  bool _loading = false;
  bool _obscurePassword = true;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _pulseCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 3000),
    )..repeat();
  }

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    _pulseCtrl.dispose();
    super.dispose();
  }

  Future<void> _login() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _loading = true;
      _errorMessage = null;
    });
    try {
      await _authService.login(
        _emailController.text.trim(),
        _passwordController.text.trim(),
      );
    } catch (e) {
      setState(() => _errorMessage = 'Email o password errati');
    } finally {
      setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF050D1E),
      body: Stack(
        children: [
          // Background gradient + glow orbs
          const _BackgroundGlow(),

          // Main content
          SafeArea(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 28),
              child: Form(
                key: _formKey,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const SizedBox(height: 60),

                    // ── Logo + title ──
                    Center(
                      child: Column(
                        children: [
                          // Logo con glow pulse
                          AnimatedBuilder(
                            animation: _pulseCtrl,
                            builder: (context, child) {
                              final glow = 0.5 + 0.5 * sin(_pulseCtrl.value * 2 * pi);
                              return Container(
                                width: 88,
                                height: 88,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: const Color(0xFF0D1B30),
                                  border: Border.all(
                                    color: const Color(0xFF4D8EF7).withOpacity(0.3 + 0.3 * glow),
                                    width: 1.5,
                                  ),
                                  boxShadow: [
                                    BoxShadow(
                                      color: const Color(0xFF1A56DB).withOpacity(0.3 + 0.2 * glow),
                                      blurRadius: 32 + 12 * glow,
                                      spreadRadius: 2,
                                    ),
                                    BoxShadow(
                                      color: const Color(0xFF4D8EF7).withOpacity(0.12 + 0.08 * glow),
                                      blurRadius: 60,
                                      spreadRadius: 8,
                                    ),
                                  ],
                                ),
                                child: child,
                              );
                            },
                            child: const Icon(
                              Icons.wifi_tethering,
                              size: 42,
                              color: Color(0xFF4D8EF7),
                            ),
                          ),

                          const SizedBox(height: 24),

                          // ProxiMeet wordmark
                          const Text(
                            'ProxiMeet',
                            style: TextStyle(
                              fontSize: 34,
                              fontWeight: FontWeight.w800,
                              letterSpacing: -1.0,
                              color: Color(0xFFE8F0FE),
                            ),
                          ),
                          const SizedBox(height: 6),
                          const Text(
                            'Networking di prossimità',
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w400,
                              letterSpacing: 0.2,
                              color: Color(0xFF8BA3C7),
                            ),
                          ),
                        ],
                      ),
                    ),

                    const SizedBox(height: 52),

                    // ── Glass card form ──
                    Container(
                      padding: const EdgeInsets.all(24),
                      decoration: BoxDecoration(
                        color: const Color(0xFF0D1B30),
                        borderRadius: BorderRadius.circular(24),
                        border: Border.all(
                          color: const Color(0xFF1A2D47),
                          width: 1,
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: const Color(0xFF1A56DB).withOpacity(0.08),
                            blurRadius: 40,
                            offset: const Offset(0, 16),
                          ),
                        ],
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'Accedi',
                            style: TextStyle(
                              fontSize: 20,
                              fontWeight: FontWeight.w700,
                              letterSpacing: -0.3,
                              color: Color(0xFFE8F0FE),
                            ),
                          ),
                          const SizedBox(height: 4),
                          const Text(
                            'Inserisci le tue credenziali per continuare',
                            style: TextStyle(
                              fontSize: 13,
                              color: Color(0xFF8BA3C7),
                            ),
                          ),
                          const SizedBox(height: 24),

                          // Email
                          TextFormField(
                            controller: _emailController,
                            keyboardType: TextInputType.emailAddress,
                            style: const TextStyle(
                              color: Color(0xFFE8F0FE),
                              fontSize: 15,
                            ),
                            decoration: const InputDecoration(
                              labelText: 'Email',
                              prefixIcon: Icon(Icons.alternate_email, size: 20),
                            ),
                            validator: (v) {
                              if (v == null || v.isEmpty) return 'Inserisci la tua email';
                              if (!v.contains('@')) return 'Email non valida';
                              return null;
                            },
                          ),

                          const SizedBox(height: 14),

                          // Password
                          TextFormField(
                            controller: _passwordController,
                            obscureText: _obscurePassword,
                            style: const TextStyle(
                              color: Color(0xFFE8F0FE),
                              fontSize: 15,
                            ),
                            decoration: InputDecoration(
                              labelText: 'Password',
                              prefixIcon: const Icon(Icons.lock_outlined, size: 20),
                              suffixIcon: IconButton(
                                icon: Icon(
                                  _obscurePassword
                                      ? Icons.visibility_outlined
                                      : Icons.visibility_off_outlined,
                                  size: 20,
                                ),
                                onPressed: () => setState(
                                  () => _obscurePassword = !_obscurePassword,
                                ),
                              ),
                            ),
                            validator: (v) {
                              if (v == null || v.isEmpty) return 'Inserisci la password';
                              if (v.length < 6) return 'Minimo 6 caratteri';
                              return null;
                            },
                            onFieldSubmitted: (_) => _login(),
                          ),

                          // Errore
                          if (_errorMessage != null) ...[
                            const SizedBox(height: 14),
                            Container(
                              padding: const EdgeInsets.all(12),
                              decoration: BoxDecoration(
                                color: const Color(0xFF4A1010),
                                borderRadius: BorderRadius.circular(10),
                                border: Border.all(
                                  color: const Color(0xFFEF5350).withOpacity(0.3),
                                ),
                              ),
                              child: Row(
                                children: [
                                  const Icon(Icons.error_outline,
                                      color: Color(0xFFEF5350), size: 16),
                                  const SizedBox(width: 8),
                                  Text(
                                    _errorMessage!,
                                    style: const TextStyle(
                                      color: Color(0xFFEF9A9A),
                                      fontSize: 13,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],

                          const SizedBox(height: 24),

                          // Gradient CTA button
                          _GradientButton(
                            onPressed: _loading ? null : _login,
                            child: _loading
                                ? const SizedBox(
                                    width: 20,
                                    height: 20,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      color: Colors.white,
                                    ),
                                  )
                                : const Text(
                                    'Accedi',
                                    style: TextStyle(
                                      fontSize: 16,
                                      fontWeight: FontWeight.w600,
                                      letterSpacing: 0.3,
                                      color: Colors.white,
                                    ),
                                  ),
                          ),
                        ],
                      ),
                    ),

                    const SizedBox(height: 28),

                    // Sign up link
                    Center(
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const Text(
                            'Non hai un account? ',
                            style: TextStyle(
                              color: Color(0xFF8BA3C7),
                              fontSize: 14,
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
                                fontWeight: FontWeight.w700,
                                fontSize: 14,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),

                    const SizedBox(height: 40),
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

// ── Background con glow orbs ─────────────────────────────────

class _BackgroundGlow extends StatelessWidget {
  const _BackgroundGlow();

  @override
  Widget build(BuildContext context) {
    return SizedBox.expand(
      child: Stack(
        children: [
          // Orb top-center (primary blue)
          Positioned(
            top: -80,
            left: 0,
            right: 0,
            child: Center(
              child: Container(
                width: 320,
                height: 320,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: RadialGradient(
                    colors: [
                      const Color(0xFF1A56DB).withOpacity(0.18),
                      Colors.transparent,
                    ],
                  ),
                ),
              ),
            ),
          ),
          // Orb bottom-right (lighter accent)
          Positioned(
            bottom: 20,
            right: -60,
            child: Container(
              width: 260,
              height: 260,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: RadialGradient(
                  colors: [
                    const Color(0xFF4D8EF7).withOpacity(0.10),
                    Colors.transparent,
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

// ── Gradient button ──────────────────────────────────────────

class _GradientButton extends StatelessWidget {
  final VoidCallback? onPressed;
  final Widget child;

  const _GradientButton({required this.onPressed, required this.child});

  @override
  Widget build(BuildContext context) {
    final disabled = onPressed == null;
    return SizedBox(
      width: double.infinity,
      height: 54,
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: disabled
                ? [const Color(0xFF1A2D47), const Color(0xFF1A2D47)]
                : [const Color(0xFF1A56DB), const Color(0xFF4D8EF7)],
            begin: Alignment.centerLeft,
            end: Alignment.centerRight,
          ),
          borderRadius: BorderRadius.circular(16),
          boxShadow: disabled
              ? []
              : [
                  BoxShadow(
                    color: const Color(0xFF1A56DB).withOpacity(0.45),
                    blurRadius: 24,
                    offset: const Offset(0, 8),
                  ),
                ],
        ),
        child: Material(
          color: Colors.transparent,
          borderRadius: BorderRadius.circular(16),
          child: InkWell(
            onTap: onPressed,
            borderRadius: BorderRadius.circular(16),
            child: Center(child: child),
          ),
        ),
      ),
    );
  }
}

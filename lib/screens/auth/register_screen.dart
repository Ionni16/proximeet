import 'package:flutter/material.dart';
import '../../services/auth_service.dart';
import '../events/event_list_screen.dart';

class RegisterScreen extends StatefulWidget {
  const RegisterScreen({super.key});

  @override
  State<RegisterScreen> createState() => _RegisterScreenState();
}

class _RegisterScreenState extends State<RegisterScreen> {
  final _formKey = GlobalKey<FormState>();

  final _firstNameCtrl      = TextEditingController();
  final _lastNameCtrl       = TextEditingController();
  final _emailCtrl          = TextEditingController();
  final _passwordCtrl       = TextEditingController();
  final _confirmPasswordCtrl= TextEditingController();
  final _companyCtrl        = TextEditingController();
  final _roleCtrl           = TextEditingController();
  final _phoneCtrl          = TextEditingController();
  final _linkedinCtrl       = TextEditingController();
  final _bioCtrl            = TextEditingController();

  bool _loading         = false;
  bool _obscurePassword = true;
  bool _obscureConfirm  = true;
  String? _errorMessage;
  int _currentStep = 0;

  @override
  void dispose() {
    _firstNameCtrl.dispose();
    _lastNameCtrl.dispose();
    _emailCtrl.dispose();
    _passwordCtrl.dispose();
    _confirmPasswordCtrl.dispose();
    _companyCtrl.dispose();
    _roleCtrl.dispose();
    _phoneCtrl.dispose();
    _linkedinCtrl.dispose();
    _bioCtrl.dispose();
    super.dispose();
  }

  void _nextStep() {
    if (_currentStep == 0) {
      final ok = _firstNameCtrl.text.trim().isNotEmpty &&
          _lastNameCtrl.text.trim().isNotEmpty &&
          _companyCtrl.text.trim().isNotEmpty &&
          _roleCtrl.text.trim().isNotEmpty;
      if (!ok) {
        setState(() => _errorMessage = 'Compila i campi obbligatori del profilo');
        return;
      }
    }
    setState(() {
      _errorMessage = null;
      _currentStep++;
    });
  }

  Future<void> _register() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() {
      _loading = true;
      _errorMessage = null;
    });

    try {
      await AuthService.instance.register(
        email:     _emailCtrl.text.trim().toLowerCase(),
        password:  _passwordCtrl.text,
        firstName: _firstNameCtrl.text.trim(),
        lastName:  _lastNameCtrl.text.trim(),
        company:   _companyCtrl.text.trim(),
        role:      _roleCtrl.text.trim(),
        phone:     _phoneCtrl.text.trim().replaceAll(' ', ''),
        linkedin:  _linkedinCtrl.text.trim(),
        bio:       _bioCtrl.text.trim(),
      );

      if (mounted) {
        Navigator.of(context).pushAndRemoveUntil(
          MaterialPageRoute(builder: (_) => const EventListScreen()),
          (route) => false,
        );
      }
    } catch (e) {
      final error = e.toString().toLowerCase();
      setState(() {
        if (error.contains('email-already-in-use')) {
          _errorMessage = 'Email già registrata';
        } else if (error.contains('weak-password')) {
          _errorMessage = 'Password troppo debole';
        } else if (error.contains('invalid-email')) {
          _errorMessage = 'Email non valida';
        } else if (error.contains('network-request-failed')) {
          _errorMessage = 'Errore di rete. Controlla la connessione';
        } else {
          _errorMessage = 'Errore durante la registrazione';
        }
      });
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Widget _buildField({
    required TextEditingController controller,
    required String label,
    required IconData icon,
    TextInputType keyboardType = TextInputType.text,
    String? Function(String?)? validator,
    bool obscure = false,
    VoidCallback? onToggleObscure,
    int maxLines = 1,
    String? hint,
  }) {
    return TextFormField(
      controller: controller,
      // KEY FIX: multiline fields must use TextInputType.multiline
      // to avoid Flutter assertion with TextInputAction.newline
      keyboardType: maxLines > 1 ? TextInputType.multiline : keyboardType,
      obscureText: obscure,
      maxLines: maxLines,
      autovalidateMode: AutovalidateMode.onUserInteraction,
      textInputAction:
          maxLines > 1 ? TextInputAction.newline : TextInputAction.next,
      style: const TextStyle(color: Color(0xFFE8F0FE), fontSize: 15),
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        prefixIcon: Icon(icon),
        suffixIcon: onToggleObscure != null
            ? IconButton(
                icon: Icon(
                  obscure
                      ? Icons.visibility_outlined
                      : Icons.visibility_off_outlined,
                  size: 20,
                ),
                onPressed: onToggleObscure,
              )
            : null,
      ),
      validator: validator,
    );
  }

  // ── Step 0: Profilo ─────────────────────────────────────────────────────────
  Widget _buildProfiloStep() {
    return Column(
      children: [
        Row(
          children: [
            Expanded(
              child: _buildField(
                controller: _firstNameCtrl,
                label: 'Nome',
                icon: Icons.person_outline,
                validator: (v) => v!.trim().isEmpty ? 'Obbligatorio' : null,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _buildField(
                controller: _lastNameCtrl,
                label: 'Cognome',
                icon: Icons.person_outline,
                validator: (v) => v!.trim().isEmpty ? 'Obbligatorio' : null,
              ),
            ),
          ],
        ),
        const SizedBox(height: 14),
        _buildField(
          controller: _companyCtrl,
          label: 'Azienda',
          icon: Icons.business_outlined,
          validator: (v) => v!.trim().isEmpty ? 'Obbligatorio' : null,
        ),
        const SizedBox(height: 14),
        _buildField(
          controller: _roleCtrl,
          label: 'Ruolo',
          icon: Icons.work_outline,
          hint: 'es. Software Engineer',
          validator: (v) => v!.trim().isEmpty ? 'Obbligatorio' : null,
        ),
        const SizedBox(height: 14),
        _buildField(
          controller: _phoneCtrl,
          label: 'Telefono (opzionale)',
          icon: Icons.phone_outlined,
          keyboardType: TextInputType.phone,
          validator: (v) {
            final value = v?.trim() ?? '';
            if (value.isEmpty) return null;
            final normalized = value.replaceAll(' ', '');
            if (!RegExp(r'^\+?[0-9]{6,15}$').hasMatch(normalized)) {
              return 'Numero non valido';
            }
            return null;
          },
        ),
        const SizedBox(height: 14),
        _buildField(
          controller: _linkedinCtrl,
          label: 'LinkedIn (opzionale)',
          icon: Icons.link_outlined,
          hint: 'linkedin.com/in/tuoprofilo',
          validator: (v) {
            final value = v?.trim() ?? '';
            if (value.isEmpty) return null;
            if (!value.toLowerCase().contains('linkedin.com/')) {
              return 'Inserisci un link LinkedIn valido';
            }
            return null;
          },
        ),
        const SizedBox(height: 14),
        _buildField(
          controller: _bioCtrl,
          label: 'Bio (opzionale)',
          icon: Icons.notes_outlined,
          hint: 'Presentati in poche righe...',
          maxLines: 3,
        ),
      ],
    );
  }

  // ── Step 1: Account ─────────────────────────────────────────────────────────
  Widget _buildAccountStep() {
    return Column(
      children: [
        _buildField(
          controller: _emailCtrl,
          label: 'Email',
          icon: Icons.alternate_email,
          keyboardType: TextInputType.emailAddress,
          validator: (v) {
            if (v == null || v.trim().isEmpty) return 'Obbligatorio';
            if (!RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(v.trim())) {
              return 'Email non valida';
            }
            return null;
          },
        ),
        const SizedBox(height: 14),
        _buildField(
          controller: _passwordCtrl,
          label: 'Password',
          icon: Icons.lock_outlined,
          obscure: _obscurePassword,
          onToggleObscure: () => setState(() => _obscurePassword = !_obscurePassword),
          validator: (v) {
            if (v == null || v.isEmpty) return 'Obbligatorio';
            if (v.length < 8) return 'Minimo 8 caratteri';
            if (!RegExp(r'[A-Z]').hasMatch(v)) return 'Inserisci almeno una maiuscola';
            if (!RegExp(r'[0-9]').hasMatch(v)) return 'Inserisci almeno un numero';
            return null;
          },
        ),
        const SizedBox(height: 14),
        _buildField(
          controller: _confirmPasswordCtrl,
          label: 'Ripeti password',
          icon: Icons.lock_outlined,
          obscure: _obscureConfirm,
          onToggleObscure: () => setState(() => _obscureConfirm = !_obscureConfirm),
          validator: (v) {
            if (v == null || v.isEmpty) return 'Obbligatorio';
            if (v != _passwordCtrl.text) return 'Le password non coincidono';
            return null;
          },
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF050D1E),
      appBar: AppBar(
        backgroundColor: const Color(0xFF050D1E),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new,
              size: 18, color: Color(0xFF8BA3C7)),
          onPressed: () => Navigator.pop(context),
        ),
        title: const Text(
          'Crea account',
          style: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.w700,
            color: Color(0xFFE8F0FE),
            letterSpacing: -0.3,
          ),
        ),
        centerTitle: true,
        elevation: 0,
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(1),
          child: Container(height: 1, color: const Color(0xFF1A2D47)),
        ),
      ),
      body: Form(
        key: _formKey,
        child: Column(
          children: [
            // ── Step indicator ──
            _StepIndicator(currentStep: _currentStep),

            // ── Content ──
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(24, 20, 24, 24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Step title
                    _StepHeader(
                      step: _currentStep,
                      titles: const ['Profilo professionale', 'Credenziali account'],
                      subtitles: const [
                        'Queste informazioni saranno visibili agli altri partecipanti',
                        'Usa una password sicura con lettere e numeri',
                      ],
                    ),

                    const SizedBox(height: 24),

                    // Form fields in glass card
                    Container(
                      padding: const EdgeInsets.all(20),
                      decoration: BoxDecoration(
                        color: const Color(0xFF0D1B30),
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(color: const Color(0xFF1A2D47)),
                        boxShadow: [
                          BoxShadow(
                            color: const Color(0xFF1A56DB).withOpacity(0.06),
                            blurRadius: 24,
                            offset: const Offset(0, 8),
                          ),
                        ],
                      ),
                      child: _currentStep == 0
                          ? _buildProfiloStep()
                          : _buildAccountStep(),
                    ),

                    // Error message
                    if (_errorMessage != null) ...[
                      const SizedBox(height: 16),
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
                            Expanded(
                              child: Text(
                                _errorMessage!,
                                style: const TextStyle(
                                  color: Color(0xFFEF9A9A),
                                  fontSize: 13,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],

                    const SizedBox(height: 28),

                    // ── Buttons ──
                    Row(
                      children: [
                        if (_currentStep > 0) ...[
                          Expanded(
                            flex: 1,
                            child: _OutlineBtn(
                              label: 'Indietro',
                              onPressed: _loading
                                  ? null
                                  : () => setState(() {
                                        _errorMessage = null;
                                        _currentStep--;
                                      }),
                            ),
                          ),
                          const SizedBox(width: 12),
                        ],
                        Expanded(
                          flex: 2,
                          child: _currentStep == 0
                              ? _GradientBtn(
                                  label: 'Avanti',
                                  icon: Icons.arrow_forward,
                                  onPressed: _loading ? null : _nextStep,
                                )
                              : _GradientBtn(
                                  label: _loading ? 'Registrazione...' : 'Crea account',
                                  icon: _loading ? null : Icons.check,
                                  loading: _loading,
                                  onPressed: _loading ? null : _register,
                                ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Componenti UI ────────────────────────────────────────────────────────────

class _StepIndicator extends StatelessWidget {
  final int currentStep;
  const _StepIndicator({required this.currentStep});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: Color(0xFF1A2D47), width: 1)),
      ),
      child: Row(
        children: [
          _StepDot(index: 0, current: currentStep, label: 'Profilo'),
          Expanded(
            child: Container(
              height: 1,
              margin: const EdgeInsets.symmetric(horizontal: 8),
              color: currentStep >= 1
                  ? const Color(0xFF4D8EF7)
                  : const Color(0xFF1A2D47),
            ),
          ),
          _StepDot(index: 1, current: currentStep, label: 'Account'),
        ],
      ),
    );
  }
}

class _StepDot extends StatelessWidget {
  final int index;
  final int current;
  final String label;

  const _StepDot({
    required this.index,
    required this.current,
    required this.label,
  });

  @override
  Widget build(BuildContext context) {
    final isActive   = index == current;
    final isComplete = index < current;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 28,
          height: 28,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: isActive || isComplete
                ? const Color(0xFF4D8EF7)
                : const Color(0xFF101E35),
            border: Border.all(
              color: isActive || isComplete
                  ? const Color(0xFF4D8EF7)
                  : const Color(0xFF1A2D47),
              width: 1.5,
            ),
            boxShadow: isActive
                ? [
                    BoxShadow(
                      color: const Color(0xFF4D8EF7).withOpacity(0.4),
                      blurRadius: 10,
                    )
                  ]
                : null,
          ),
          child: Center(
            child: isComplete
                ? const Icon(Icons.check, size: 14, color: Colors.white)
                : Text(
                    '${index + 1}',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: isActive
                          ? Colors.white
                          : const Color(0xFF4A6080),
                    ),
                  ),
          ),
        ),
        const SizedBox(height: 4),
        Text(
          label,
          style: TextStyle(
            fontSize: 10,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.3,
            color: isActive || isComplete
                ? const Color(0xFF4D8EF7)
                : const Color(0xFF4A6080),
          ),
        ),
      ],
    );
  }
}

class _StepHeader extends StatelessWidget {
  final int step;
  final List<String> titles;
  final List<String> subtitles;

  const _StepHeader({
    required this.step,
    required this.titles,
    required this.subtitles,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          titles[step],
          style: const TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.w700,
            color: Color(0xFFE8F0FE),
            letterSpacing: -0.3,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          subtitles[step],
          style: const TextStyle(
            fontSize: 13,
            color: Color(0xFF8BA3C7),
            height: 1.4,
          ),
        ),
      ],
    );
  }
}

class _GradientBtn extends StatelessWidget {
  final String label;
  final IconData? icon;
  final VoidCallback? onPressed;
  final bool loading;

  const _GradientBtn({
    required this.label,
    this.icon,
    required this.onPressed,
    this.loading = false,
  });

  @override
  Widget build(BuildContext context) {
    final disabled = onPressed == null;
    return GestureDetector(
      onTap: onPressed,
      child: Container(
        height: 52,
        decoration: BoxDecoration(
          gradient: disabled
              ? null
              : const LinearGradient(
                  colors: [Color(0xFF1A56DB), Color(0xFF4D8EF7)]),
          color: disabled ? const Color(0xFF1A2D47) : null,
          borderRadius: BorderRadius.circular(14),
          boxShadow: disabled
              ? null
              : [
                  BoxShadow(
                    color: const Color(0xFF1A56DB).withOpacity(0.4),
                    blurRadius: 20,
                    offset: const Offset(0, 6),
                  )
                ],
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (loading)
              const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: Colors.white,
                ),
              )
            else if (icon != null) ...[
              Icon(icon, size: 18, color: Colors.white),
              const SizedBox(width: 8),
            ],
            if (!loading)
              Text(
                label,
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  color: disabled ? const Color(0xFF4A6080) : Colors.white,
                  letterSpacing: 0.2,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _OutlineBtn extends StatelessWidget {
  final String label;
  final VoidCallback? onPressed;
  const _OutlineBtn({required this.label, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onPressed,
      child: Container(
        height: 52,
        decoration: BoxDecoration(
          color: const Color(0xFF0D1B30),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: const Color(0xFF1A2D47)),
        ),
        child: Center(
          child: Text(
            label,
            style: const TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w500,
              color: Color(0xFF8BA3C7),
            ),
          ),
        ),
      ),
    );
  }
}

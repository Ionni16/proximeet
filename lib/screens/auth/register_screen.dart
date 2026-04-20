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

  final _firstNameCtrl = TextEditingController();
  final _lastNameCtrl = TextEditingController();
  final _emailCtrl = TextEditingController();
  final _passwordCtrl = TextEditingController();
  final _confirmPasswordCtrl = TextEditingController();
  final _companyCtrl = TextEditingController();
  final _roleCtrl = TextEditingController();
  final _phoneCtrl = TextEditingController();
  final _linkedinCtrl = TextEditingController();
  final _bioCtrl = TextEditingController();

  bool _loading = false;
  bool _obscurePassword = true;
  bool _obscureConfirm = true;
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

  Future<void> _register() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() {
      _loading = true;
      _errorMessage = null;
    });

    try {
      await AuthService.instance.register(
        email: _emailCtrl.text.trim(),
        password: _passwordCtrl.text.trim(),
        firstName: _firstNameCtrl.text.trim(),
        lastName: _lastNameCtrl.text.trim(),
        company: _companyCtrl.text.trim(),
        role: _roleCtrl.text.trim(),
        phone: _phoneCtrl.text.trim(),
        linkedin: _linkedinCtrl.text.trim(),
        bio: _bioCtrl.text.trim(),
      );

      // Registrazione riuscita → vai DIRETTAMENTE alla EventListScreen
      // e rimuovi tutto lo stack di navigazione (Login + Register).
      // Più affidabile del popUntil che dipende dal timing di authStateChanges.
      if (mounted) {
        Navigator.of(context).pushAndRemoveUntil(
          MaterialPageRoute(builder: (_) => const EventListScreen()),
          (route) => false,
        );
      }
    } catch (e) {
      setState(() {
        _errorMessage = e.toString().contains('email-already-in-use')
            ? 'Email già registrata'
            : 'Errore durante la registrazione';
      });
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Widget _buildTextField({
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
      keyboardType: keyboardType,
      obscureText: obscure,
      maxLines: maxLines,
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        prefixIcon: Icon(icon),
        border: const OutlineInputBorder(
          borderRadius: BorderRadius.all(Radius.circular(12)),
        ),
        suffixIcon: onToggleObscure != null
            ? IconButton(
                icon: Icon(obscure
                    ? Icons.visibility_outlined
                    : Icons.visibility_off_outlined),
                onPressed: onToggleObscure,
              )
            : null,
      ),
      validator: validator,
    );
  }

  List<Step> get _steps => [
        Step(
          title: const Text('Profilo'),
          isActive: _currentStep >= 0,
          state: _currentStep > 0 ? StepState.complete : StepState.indexed,
          content: Column(
            children: [
              Row(
                children: [
                  Expanded(
                    child: _buildTextField(
                      controller: _firstNameCtrl,
                      label: 'Nome',
                      icon: Icons.person_outlined,
                      validator: (v) =>
                          v!.isEmpty ? 'Campo obbligatorio' : null,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _buildTextField(
                      controller: _lastNameCtrl,
                      label: 'Cognome',
                      icon: Icons.person_outlined,
                      validator: (v) =>
                          v!.isEmpty ? 'Campo obbligatorio' : null,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              _buildTextField(
                controller: _companyCtrl,
                label: 'Azienda',
                icon: Icons.business_outlined,
                validator: (v) => v!.isEmpty ? 'Campo obbligatorio' : null,
              ),
              const SizedBox(height: 16),
              _buildTextField(
                controller: _roleCtrl,
                label: 'Ruolo',
                icon: Icons.work_outlined,
                hint: 'es. Software Engineer',
                validator: (v) => v!.isEmpty ? 'Campo obbligatorio' : null,
              ),
              const SizedBox(height: 16),
              _buildTextField(
                controller: _phoneCtrl,
                label: 'Telefono (opzionale)',
                icon: Icons.phone_outlined,
                keyboardType: TextInputType.phone,
              ),
              const SizedBox(height: 16),
              _buildTextField(
                controller: _linkedinCtrl,
                label: 'LinkedIn (opzionale)',
                icon: Icons.link_outlined,
                hint: 'es. linkedin.com/in/tuoprofilo',
              ),
              const SizedBox(height: 16),
              _buildTextField(
                controller: _bioCtrl,
                label: 'Bio (opzionale)',
                icon: Icons.notes_outlined,
                hint: 'Presentati in poche righe...',
                maxLines: 3,
              ),
            ],
          ),
        ),
        Step(
          title: const Text('Account'),
          isActive: _currentStep >= 1,
          state: _currentStep > 1 ? StepState.complete : StepState.indexed,
          content: Column(
            children: [
              _buildTextField(
                controller: _emailCtrl,
                label: 'Email',
                icon: Icons.email_outlined,
                keyboardType: TextInputType.emailAddress,
                validator: (v) {
                  if (v!.isEmpty) return 'Campo obbligatorio';
                  if (!v.contains('@')) return 'Email non valida';
                  return null;
                },
              ),
              const SizedBox(height: 16),
              _buildTextField(
                controller: _passwordCtrl,
                label: 'Password',
                icon: Icons.lock_outlined,
                obscure: _obscurePassword,
                onToggleObscure: () =>
                    setState(() => _obscurePassword = !_obscurePassword),
                validator: (v) {
                  if (v!.isEmpty) return 'Campo obbligatorio';
                  if (v.length < 6) return 'Minimo 6 caratteri';
                  return null;
                },
              ),
              const SizedBox(height: 16),
              _buildTextField(
                controller: _confirmPasswordCtrl,
                label: 'Ripeti password',
                icon: Icons.lock_outlined,
                obscure: _obscureConfirm,
                onToggleObscure: () =>
                    setState(() => _obscureConfirm = !_obscureConfirm),
                validator: (v) {
                  if (v != _passwordCtrl.text) {
                    return 'Le password non coincidono';
                  }
                  return null;
                },
              ),
            ],
          ),
        ),
      ];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Crea account'),
        centerTitle: true,
      ),
      body: Form(
        key: _formKey,
        child: Column(
          children: [
            Expanded(
              child: Stepper(
                currentStep: _currentStep,
                onStepTapped: (step) => setState(() => _currentStep = step),
                controlsBuilder: (context, details) {
                  return Padding(
                    padding: const EdgeInsets.only(top: 16),
                    child: Row(
                      children: [
                        if (_currentStep < _steps.length - 1)
                          FilledButton(
                            onPressed: () => setState(() => _currentStep++),
                            style: FilledButton.styleFrom(
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(10),
                              ),
                            ),
                            child: const Text('Avanti'),
                          ),
                        if (_currentStep == _steps.length - 1)
                          FilledButton(
                            onPressed: _loading ? null : _register,
                            style: FilledButton.styleFrom(
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(10),
                              ),
                            ),
                            child: _loading
                                ? const SizedBox(
                                    width: 20,
                                    height: 20,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      color: Colors.white,
                                    ),
                                  )
                                : const Text('Registrati'),
                          ),
                        if (_currentStep > 0) ...[
                          const SizedBox(width: 12),
                          TextButton(
                            onPressed: () => setState(() => _currentStep--),
                            child: const Text('Indietro'),
                          ),
                        ],
                      ],
                    ),
                  );
                },
                steps: _steps,
              ),
            ),
            if (_errorMessage != null)
              Container(
                margin: const EdgeInsets.all(16),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: theme.colorScheme.errorContainer,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    Icon(Icons.error_outline,
                        color: theme.colorScheme.error, size: 18),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        _errorMessage!,
                        style: TextStyle(color: theme.colorScheme.error),
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

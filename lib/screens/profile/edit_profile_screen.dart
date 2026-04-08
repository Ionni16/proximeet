import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../../services/auth_service.dart';
import '../../models/user_model.dart';

class EditProfileScreen extends StatefulWidget {
  final UserModel user;
  const EditProfileScreen({super.key, required this.user});

  @override
  State<EditProfileScreen> createState() => _EditProfileScreenState();
}

class _EditProfileScreenState extends State<EditProfileScreen> {
  final _formKey = GlobalKey<FormState>();
  final _authService = AuthService();
  bool _loading = false;

  late final TextEditingController _firstNameController;
  late final TextEditingController _lastNameController;
  late final TextEditingController _companyController;
  late final TextEditingController _roleController;
  late final TextEditingController _phoneController;
  late final TextEditingController _linkedinController;
  late final TextEditingController _githubController;
  late final TextEditingController _twitterController;
  late final TextEditingController _bioController;

  @override
  void initState() {
    super.initState();
    final u = widget.user;
    _firstNameController = TextEditingController(text: u.firstName);
    _lastNameController = TextEditingController(text: u.lastName);
    _companyController = TextEditingController(text: u.company);
    _roleController = TextEditingController(text: u.role);
    _phoneController = TextEditingController(text: u.phone ?? '');
    _linkedinController = TextEditingController(text: u.linkedin ?? '');
    _githubController = TextEditingController(text: u.github ?? '');
    _twitterController = TextEditingController(text: u.twitter ?? '');
    _bioController = TextEditingController(text: u.bio ?? '');
  }

  @override
  void dispose() {
    _firstNameController.dispose();
    _lastNameController.dispose();
    _companyController.dispose();
    _roleController.dispose();
    _phoneController.dispose();
    _linkedinController.dispose();
    _githubController.dispose();
    _twitterController.dispose();
    _bioController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _loading = true);

    try {
      final uid = FirebaseAuth.instance.currentUser?.uid;
      if (uid == null) return;

      await _authService.updateProfile(uid, {
        'firstName': _firstNameController.text.trim(),
        'lastName': _lastNameController.text.trim(),
        'company': _companyController.text.trim(),
        'role': _roleController.text.trim(),
        'phone': _phoneController.text.trim(),
        'linkedin': _linkedinController.text.trim(),
        'github': _githubController.text.trim(),
        'twitter': _twitterController.text.trim(),
        'bio': _bioController.text.trim(),
      });

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Profilo aggiornato!')),
        );
        Navigator.pop(context);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Errore: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Widget _field({
    required TextEditingController controller,
    required String label,
    required IconData icon,
    String? hint,
    TextInputType keyboard = TextInputType.text,
    int maxLines = 1,
    String? Function(String?)? validator,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: TextFormField(
        controller: controller,
        keyboardType: keyboard,
        maxLines: maxLines,
        decoration: InputDecoration(
          labelText: label,
          hintText: hint,
          prefixIcon: Icon(icon),
          border: const OutlineInputBorder(
            borderRadius: BorderRadius.all(Radius.circular(12)),
          ),
        ),
        validator: validator,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Modifica profilo'),
        centerTitle: true,
        actions: [
          TextButton(
            onPressed: _loading ? null : _save,
            child: _loading
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('Salva',
                    style: TextStyle(fontWeight: FontWeight.bold)),
          ),
        ],
      ),
      body: Form(
        key: _formKey,
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _SectionLabel('Dati personali'),
              Row(
                children: [
                  Expanded(
                    child: _field(
                      controller: _firstNameController,
                      label: 'Nome',
                      icon: Icons.person_outlined,
                      validator: (v) => v!.isEmpty ? 'Obbligatorio' : null,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _field(
                      controller: _lastNameController,
                      label: 'Cognome',
                      icon: Icons.person_outlined,
                      validator: (v) => v!.isEmpty ? 'Obbligatorio' : null,
                    ),
                  ),
                ],
              ),
              _field(
                controller: _companyController,
                label: 'Azienda',
                icon: Icons.business_outlined,
                validator: (v) => v!.isEmpty ? 'Obbligatorio' : null,
              ),
              _field(
                controller: _roleController,
                label: 'Ruolo',
                icon: Icons.work_outlined,
                hint: 'es. Software Engineer',
                validator: (v) => v!.isEmpty ? 'Obbligatorio' : null,
              ),
              _SectionLabel('Contatti'),
              _field(
                controller: _phoneController,
                label: 'Telefono',
                icon: Icons.phone_outlined,
                keyboard: TextInputType.phone,
              ),
              _SectionLabel('Social'),
              _field(
                controller: _linkedinController,
                label: 'LinkedIn',
                icon: Icons.link_outlined,
                hint: 'linkedin.com/in/tuoprofilo',
              ),
              _field(
                controller: _githubController,
                label: 'GitHub',
                icon: Icons.code_outlined,
                hint: 'github.com/tuoprofilo',
              ),
              _field(
                controller: _twitterController,
                label: 'Twitter / X',
                icon: Icons.alternate_email,
                hint: '@tuoprofilo',
              ),
              _SectionLabel('Bio'),
              _field(
                controller: _bioController,
                label: 'Bio',
                icon: Icons.notes_outlined,
                hint: 'Presentati in poche righe...',
                maxLines: 4,
              ),
              const SizedBox(height: 20),
              SizedBox(
                width: double.infinity,
                height: 52,
                child: FilledButton(
                  onPressed: _loading ? null : _save,
                  style: FilledButton.styleFrom(
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12)),
                  ),
                  child: _loading
                      ? const CircularProgressIndicator(color: Colors.white)
                      : const Text('Salva modifiche',
                          style: TextStyle(fontSize: 16)),
                ),
              ),
              const SizedBox(height: 32),
            ],
          ),
        ),
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  final String text;
  const _SectionLabel(this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12, top: 4),
      child: Text(
        text.toUpperCase(),
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.bold,
          letterSpacing: 1.2,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

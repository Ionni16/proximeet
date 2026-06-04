// lib/screens/auth/linkedin_complete_profile_screen.dart
//
// Usata per nuovi utenti LinkedIn E Apple.
// Chiavi mappa attese:
//   firstName, lastName, email, photoURL, loginProvider ('linkedin'|'apple')

import 'dart:io';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../../services/auth_service.dart';
import '../../services/storage_service.dart';
import '../events/event_list_screen.dart';

class LinkedInCompleteProfileScreen extends StatefulWidget {
  final Map<String, dynamic> linkedInProfile;

  const LinkedInCompleteProfileScreen({
    super.key,
    required this.linkedInProfile,
  });

  @override
  State<LinkedInCompleteProfileScreen> createState() =>
      _LinkedInCompleteProfileScreenState();
}

class _LinkedInCompleteProfileScreenState
    extends State<LinkedInCompleteProfileScreen> {
  final _formKey = GlobalKey<FormState>();

  late final TextEditingController _firstNameCtrl;
  late final TextEditingController _lastNameCtrl;
  late final TextEditingController _emailCtrl;
  late final TextEditingController _companyCtrl;
  late final TextEditingController _roleCtrl;
  late final TextEditingController _bioCtrl;
  late final TextEditingController _phoneCtrl;

  late final String _photoUrl;
  late final String _loginProvider; // 'linkedin' | 'apple'
  late final bool _emailEditable;   // true se Apple senza email

  File? _localPhoto;
  bool _photoError = false;

  bool _loading = false;
  String? _errorMessage;

  bool get _hasPhoto => _localPhoto != null || _photoUrl.isNotEmpty;

  @override
  void initState() {
    super.initState();
    final p = widget.linkedInProfile;

    _loginProvider = (p['loginProvider'] as String? ?? 'linkedin');

    _firstNameCtrl = TextEditingController(
      text: (p['firstName'] as String? ?? '').trim(),
    );
    _lastNameCtrl = TextEditingController(
      text: (p['lastName'] as String? ?? '').trim(),
    );

    final email = (p['email'] as String? ?? '').trim();
    _emailCtrl = TextEditingController(text: email);
    // Se è Apple e non ha email (ha nascosto), il campo è editabile
    _emailEditable = _loginProvider == 'apple' && email.isEmpty;

    _photoUrl = (p['photoURL'] as String? ?? '').trim();

    _companyCtrl = TextEditingController(
      text: (p['company'] as String? ?? '').trim(),
    );
    _roleCtrl = TextEditingController(
      text: (p['role'] as String? ?? '').trim(),
    );
    _bioCtrl = TextEditingController(
      text: (p['bio'] as String? ?? '').trim(),
    );
    _phoneCtrl = TextEditingController(
      text: (p['phone'] as String? ?? '').trim(),
    );
  }

  @override
  void dispose() {
    _firstNameCtrl.dispose();
    _lastNameCtrl.dispose();
    _emailCtrl.dispose();
    _companyCtrl.dispose();
    _roleCtrl.dispose();
    _bioCtrl.dispose();
    _phoneCtrl.dispose();
    super.dispose();
  }

  Future<void> _pickPhoto() async {
    final file = await StorageService.instance.pickImage();
    if (file == null) return;
    setState(() {
      _localPhoto = file;
      _photoError = false;
    });
  }

  Future<void> _saveProfile() async {
    // La foto resta consigliata, ma non blocca l'utente Apple/App Review.
    // I dati minimi obbligatori sono nome, cognome, email, azienda e ruolo.
    if (!_formKey.currentState!.validate()) return;

    setState(() {
      _loading = true;
      _errorMessage = null;
      _photoError = false;
    });

    try {
      final uid = FirebaseAuth.instance.currentUser?.uid;
      if (uid == null) throw Exception('Utente non autenticato');

      String avatarURL = _photoUrl;

      if (_localPhoto != null) {
        final uploadedUrl =
            await StorageService.instance.uploadAvatar(uid, _localPhoto!);
        if (uploadedUrl != null && uploadedUrl.isNotEmpty) {
          avatarURL = uploadedUrl;
        }
      }

      await AuthService.instance.createLinkedInUserProfile(
        uid:        uid,
        firstName:  _firstNameCtrl.text.trim(),
        lastName:   _lastNameCtrl.text.trim(),
        email:      _emailCtrl.text.trim(),
        company:    _companyCtrl.text.trim(),
        role:       _roleCtrl.text.trim(),
        avatarURL:  avatarURL,
        bio:        _bioCtrl.text.trim(),
        phone:      _phoneCtrl.text.trim(),
        linkedinUrl: null,
      );

      if (mounted) {
        Navigator.of(context).pushAndRemoveUntil(
          MaterialPageRoute(builder: (_) => const EventListScreen()),
          (route) => false,
        );
      }
    } catch (e) {
      setState(() => _errorMessage = 'Errore durante il salvataggio del profilo');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  bool get _isApple => _loginProvider == 'apple';

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF050D1E),
      body: Stack(
        children: [
          const _BackgroundGlow(),
          SafeArea(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Form(
                key: _formKey,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const SizedBox(height: 40),

                    // ── Header ──────────────────────────────────────────────────
                    Center(
                      child: Column(
                        children: [
                          _AvatarPicker(
                            photoUrl: _photoUrl,
                            localPhoto: _localPhoto,
                            hasError: _photoError,
                            onTap: _pickPhoto,
                          ),
                          const SizedBox(height: 16),
                          const Text(
                            'Benvenuto in ProxiMeet!',
                            style: TextStyle(
                              fontSize: 22,
                              fontWeight: FontWeight.w800,
                              letterSpacing: -0.5,
                              color: Color(0xFFE8F0FE),
                            ),
                          ),
                          const SizedBox(height: 6),
                          const Text(
                            'Completa il tuo profilo per continuare',
                            style: TextStyle(
                              fontSize: 13,
                              color: Color(0xFF8BA3C7),
                            ),
                          ),
                        ],
                      ),
                    ),

                    const SizedBox(height: 32),

                    // ── Badge provider ───────────────────────────────────────────
                    if (_emailCtrl.text.isNotEmpty && !_emailEditable)
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 14, vertical: 10),
                        decoration: BoxDecoration(
                          color: (_isApple
                                  ? Colors.white
                                  : const Color(0xFF0A66C2))
                              .withOpacity(0.08),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: (_isApple
                                    ? Colors.white
                                    : const Color(0xFF0A66C2))
                                .withOpacity(0.25),
                          ),
                        ),
                        child: Row(
                          children: [
                            _isApple
                                ? const Icon(Icons.apple,
                                    color: Color(0xFF8BA3C7), size: 20)
                                : _LinkedInBadge(),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                _emailCtrl.text,
                                style: const TextStyle(
                                  color: Color(0xFF8BA3C7),
                                  fontSize: 13,
                                ),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            const Icon(Icons.lock_outline,
                                size: 14, color: Color(0xFF4A6080)),
                          ],
                        ),
                      ),

                    // ── Avviso Apple senza email ─────────────────────────────────
                    if (_emailEditable)
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 14, vertical: 10),
                        decoration: BoxDecoration(
                          color: const Color(0xFFB45309).withOpacity(0.08),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: const Color(0xFFB45309).withOpacity(0.3),
                          ),
                        ),
                        child: const Row(
                          children: [
                            Icon(Icons.info_outline,
                                color: Color(0xFFFBBF24), size: 16),
                            SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                'Hai scelto di nascondere l\'email Apple. Inserisci un\'email di contatto.',
                                style: TextStyle(
                                  color: Color(0xFFFBBF24),
                                  fontSize: 12,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),

                    const SizedBox(height: 20),

                    // ── Card principale ──────────────────────────────────────────
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
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // ── Dati personali ──────────────────────────────────
                          _SectionLabel(
                            icon: Icons.person_outline,
                            label: 'Dati personali',
                            sublabel: _isApple
                                ? 'Da Apple — modificabili'
                                : 'Pre-compilati da LinkedIn — modificabili',
                          ),
                          const SizedBox(height: 14),

                          Row(
                            children: [
                              Expanded(
                                child: _buildField(
                                  controller: _firstNameCtrl,
                                  label: 'Nome',
                                  icon: Icons.badge_outlined,
                                  validator: (v) =>
                                      v!.trim().isEmpty ? 'Obbligatorio' : null,
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: _buildField(
                                  controller: _lastNameCtrl,
                                  label: 'Cognome',
                                  icon: Icons.badge_outlined,
                                  validator: (v) =>
                                      v!.trim().isEmpty ? 'Obbligatorio' : null,
                                ),
                              ),
                            ],
                          ),

                          // ── Email editabile (Apple senza email) ─────────────
                          if (_emailEditable) ...[
                            const SizedBox(height: 14),
                            _buildField(
                              controller: _emailCtrl,
                              label: 'Email *',
                              icon: Icons.alternate_email,
                              keyboardType: TextInputType.emailAddress,
                              validator: (v) {
                                if (v == null || v.trim().isEmpty) {
                                  return 'Email obbligatoria';
                                }
                                if (!v.contains('@')) return 'Email non valida';
                                return null;
                              },
                            ),
                          ],

                          const SizedBox(height: 24),

                          // ── Profilo professionale ───────────────────────────
                          _SectionLabel(
                            icon: Icons.work_outline,
                            label: 'Profilo professionale',
                            sublabel: 'Visibile agli altri partecipanti',
                          ),
                          const SizedBox(height: 14),

                          _buildField(
                            controller: _companyCtrl,
                            label: 'Azienda *',
                            icon: Icons.business_outlined,
                            validator: (v) =>
                                v!.trim().isEmpty ? 'Campo obbligatorio' : null,
                          ),
                          const SizedBox(height: 14),
                          _buildField(
                            controller: _roleCtrl,
                            label: 'Ruolo / Posizione *',
                            icon: Icons.work_history_outlined,
                            hint: 'es. Software Engineer',
                            validator: (v) =>
                                v!.trim().isEmpty ? 'Campo obbligatorio' : null,
                          ),

                          const SizedBox(height: 24),

                          // ── Info aggiuntive ─────────────────────────────────
                          _SectionLabel(
                            icon: Icons.info_outline,
                            label: 'Info aggiuntive',
                            sublabel: 'Opzionali',
                          ),
                          const SizedBox(height: 14),

                          _buildField(
                            controller: _phoneCtrl,
                            label: 'Telefono',
                            icon: Icons.phone_outlined,
                            keyboardType: TextInputType.phone,
                          ),
                          const SizedBox(height: 14),
                          _buildField(
                            controller: _bioCtrl,
                            label: 'Bio',
                            icon: Icons.notes_outlined,
                            hint: 'Presentati in poche righe...',
                            maxLines: 3,
                          ),
                        ],
                      ),
                    ),

                    // ── Errore ───────────────────────────────────────────────────
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

                    const SizedBox(height: 24),

                    _GradientButton(
                      onPressed: _loading ? null : _saveProfile,
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
                              'Entra in ProxiMeet',
                              style: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w600,
                                color: Colors.white,
                              ),
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

  Widget _buildField({
    required TextEditingController controller,
    required String label,
    required IconData icon,
    TextInputType keyboardType = TextInputType.text,
    String? Function(String?)? validator,
    int maxLines = 1,
    String? hint,
  }) {
    return TextFormField(
      controller: controller,
      keyboardType: maxLines > 1 ? TextInputType.multiline : keyboardType,
      maxLines: maxLines,
      autovalidateMode: AutovalidateMode.onUserInteraction,
      textInputAction:
          maxLines > 1 ? TextInputAction.newline : TextInputAction.next,
      style: const TextStyle(color: Color(0xFFE8F0FE), fontSize: 15),
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        prefixIcon: Icon(icon, size: 20),
      ),
      validator: validator,
    );
  }
}

// ── Widget: Avatar Picker ─────────────────────────────────────────────────────

class _AvatarPicker extends StatelessWidget {
  final String photoUrl;
  final File? localPhoto;
  final bool hasError;
  final VoidCallback onTap;

  const _AvatarPicker({
    required this.photoUrl,
    required this.localPhoto,
    required this.hasError,
    required this.onTap,
  });

  bool get _hasPhoto => localPhoto != null || photoUrl.isNotEmpty;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        GestureDetector(
          onTap: onTap,
          child: Stack(
            alignment: Alignment.bottomRight,
            children: [
              Container(
                width: 96,
                height: 96,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: const Color(0xFF101E35),
                  border: Border.all(
                    color: hasError
                        ? const Color(0xFFEF5350)
                        : _hasPhoto
                            ? const Color(0xFF0A66C2)
                            : const Color(0xFF1A2D47),
                    width: 2.5,
                  ),
                  boxShadow: _hasPhoto || hasError
                      ? [
                          BoxShadow(
                            color: (hasError
                                    ? const Color(0xFFEF5350)
                                    : const Color(0xFF0A66C2))
                                .withOpacity(0.3),
                            blurRadius: 16,
                          ),
                        ]
                      : null,
                ),
                child: ClipOval(child: _buildAvatarContent()),
              ),
              Container(
                width: 30,
                height: 30,
                decoration: BoxDecoration(
                  color: const Color(0xFF0A66C2),
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: const Color(0xFF050D1E),
                    width: 2,
                  ),
                ),
                child: const Icon(Icons.camera_alt,
                    size: 14, color: Colors.white),
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        Text(
          localPhoto != null
              ? 'Tocca per cambiare foto'
              : photoUrl.isNotEmpty
                  ? 'Foto profilo — tocca per cambiare'
                  : 'Aggiungi foto profilo (obbligatoria)',
          style: TextStyle(
            fontSize: 12,
            color: hasError
                ? const Color(0xFFEF5350)
                : photoUrl.isNotEmpty || localPhoto != null
                    ? const Color(0xFF0A66C2)
                    : const Color(0xFF4A6080),
          ),
        ),
      ],
    );
  }

  Widget _buildAvatarContent() {
    if (localPhoto != null) {
      return Image.file(localPhoto!, width: 96, height: 96, fit: BoxFit.cover);
    }
    if (photoUrl.isNotEmpty) {
      return CachedNetworkImage(
        imageUrl: photoUrl,
        width: 96,
        height: 96,
        fit: BoxFit.cover,
        placeholder: (_, __) => const _DefaultAvatarContent(),
        errorWidget: (_, __, ___) => const _DefaultAvatarContent(),
      );
    }
    return const _DefaultAvatarContent();
  }
}

class _DefaultAvatarContent extends StatelessWidget {
  const _DefaultAvatarContent();

  @override
  Widget build(BuildContext context) {
    return Container(
      color: const Color(0xFF101E35),
      child: const Icon(Icons.person_outline,
          color: Color(0xFF4A6080), size: 40),
    );
  }
}

// ── Widget: Section Label ─────────────────────────────────────────────────────

class _SectionLabel extends StatelessWidget {
  final IconData icon;
  final String label;
  final String sublabel;

  const _SectionLabel({
    required this.icon,
    required this.label,
    required this.sublabel,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: 16, color: const Color(0xFF4D8EF7)),
        const SizedBox(width: 6),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label,
                style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: Color(0xFFE8F0FE))),
            Text(sublabel,
                style: const TextStyle(
                    fontSize: 11, color: Color(0xFF4A6080))),
          ],
        ),
      ],
    );
  }
}

// ── Widget: LinkedIn Badge ────────────────────────────────────────────────────

class _LinkedInBadge extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      width: 20,
      height: 20,
      decoration: BoxDecoration(
        color: const Color(0xFF0A66C2),
        borderRadius: BorderRadius.circular(4),
      ),
      child: const Center(
        child: Text('in',
            style: TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w900,
                fontSize: 10,
                letterSpacing: -0.5)),
      ),
    );
  }
}

// ── Widget: Background Glow ───────────────────────────────────────────────────

class _BackgroundGlow extends StatelessWidget {
  const _BackgroundGlow();

  @override
  Widget build(BuildContext context) {
    return SizedBox.expand(
      child: Stack(
        children: [
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
                      const Color(0xFF0A66C2).withOpacity(0.12),
                      Colors.transparent,
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

// ── Widget: Gradient Button ───────────────────────────────────────────────────

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

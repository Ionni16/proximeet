import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../models/user_model.dart';
import '../../services/auth_service.dart';
import '../../services/event_session_service.dart';
import '../../services/storage_service.dart';
import '../../widgets/user_avatar.dart';
import '../auth/login_screen.dart';
import '../profile/edit_profile_screen.dart';
import 'qr_scanner_screen.dart';

/// Tab del profilo: dati utente, QR, bottoni per modifica e uscita evento.
class ProfileTab extends StatelessWidget {
  final UserModel currentUser;
  const ProfileTab({super.key, required this.currentUser});

  @override
  Widget build(BuildContext context) {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return const Center(child: CircularProgressIndicator());

    return StreamBuilder<DocumentSnapshot>(
      stream:
          FirebaseFirestore.instance.collection('users').doc(uid).snapshots(),
      builder: (context, snapshot) {
        if (!snapshot.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        final data = snapshot.data!.data() as Map<String, dynamic>?;
        if (data == null) {
          return const Center(child: Text('Profilo non trovato'));
        }
        return _ProfileContent(user: UserModel.fromMap(data));
      },
    );
  }
}

class _ProfileContent extends StatefulWidget {
  final UserModel user;
  const _ProfileContent({required this.user});

  @override
  State<_ProfileContent> createState() => _ProfileContentState();
}

class _ProfileContentState extends State<_ProfileContent> {
  bool _uploadingPhoto = false;
  bool _deletingAccount = false;
  bool _loggingOut = false;

  Future<void> _changePhoto() async {
    try {
      final file = await StorageService.instance.pickImage();
      if (file == null || !mounted) return;

      setState(() => _uploadingPhoto = true);
      final uid = FirebaseAuth.instance.currentUser?.uid;
      if (uid == null) throw StateError('Utente non autenticato');

      final url = await StorageService.instance.uploadAvatar(uid, file);
      if (url == null || url.isEmpty) {
        throw StateError('Firebase Storage non ha restituito la foto');
      }

      await AuthService.instance.updateAvatar(uid, url);
      await EventSessionService.instance.updateMyProfileInEvent({
        'avatarURL': url,
      });

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Foto aggiornata correttamente')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Impossibile aggiornare la foto: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _uploadingPhoto = false);
    }
  }


  Future<void> _confirmAndLogout() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Disconnettersi?'),
        content: const Text('Uscirai dal tuo account su questo dispositivo.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Annulla'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Logout'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _loggingOut = true);
    try {
      await AuthService.instance.logout();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Disconnessione completata. ($e)')),
        );
      }
    }

    // Navigazione esplicita: da dentro un evento lo StreamBuilder auth non è
    // più nell'albero, quindi riportiamo al login svuotando lo stack.
    if (!mounted) return;
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const LoginScreen()),
      (route) => false,
    );
  }

  /// Mostra il dialog di conferma e, se confermato, elimina l'account.
  Future<void> _confirmAndDeleteAccount() async {
    final theme = Theme.of(context);

    final confirmed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        icon: Icon(Icons.warning_amber_rounded,
            color: theme.colorScheme.error, size: 32),
        title: const Text('Eliminare l\'account?'),
        content: const Text(
          'Questa azione è permanente e irreversibile.\n\n'
          'Verranno eliminati definitivamente:\n'
          '• Il tuo profilo e i tuoi dati\n'
          '• Tutti i contatti del tuo wallet\n'
          '• Le tue connessioni con gli altri partecipanti\n\n'
          'Non sarà possibile recuperare l\'account.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Annulla'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: theme.colorScheme.error,
              foregroundColor: theme.colorScheme.onError,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Elimina account'),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;

    setState(() => _deletingAccount = true);

    try {
      // 1. Esci da un eventuale evento attivo: ferma BLE e ripulisce la presenza.
      await EventSessionService.instance.leaveEvent();

      // 2. Elimina account + tutti i dati (Cloud Function lato server) e signOut.
      await AuthService.instance.deleteAccount();

      // 3. Da dentro un evento lo StreamBuilder su authStateChanges non è più
      //    nell'albero, quindi riportiamo esplicitamente al login.
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Account eliminato')),
        );
        Navigator.of(context).pushAndRemoveUntil(
          MaterialPageRoute(builder: (_) => const LoginScreen()),
          (route) => false,
        );
      }
    } on FirebaseFunctionsException catch (e) {
      if (mounted) {
        setState(() => _deletingAccount = false);
        final detail = (e.message ?? '').trim();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              detail.isEmpty
                  ? 'Impossibile eliminare l\'account (${e.code}). Riprova.'
                  : 'Impossibile eliminare l\'account: $detail (${e.code})',
            ),
            backgroundColor: Theme.of(context).colorScheme.error,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() => _deletingAccount = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Impossibile eliminare l\'account: $e'),
            backgroundColor: Theme.of(context).colorScheme.error,
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final user = widget.user;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        children: [
          const SizedBox(height: 16),

          // Avatar con badge per cambiare foto
          GestureDetector(
            onTap: _changePhoto,
            child: UserAvatar(
              imageUrl: _uploadingPhoto ? null : user.avatarURL,
              name: user.firstName,
              size: 100,
              borderColor: theme.colorScheme.primary,
              borderWidth: 2.5,
              badge: Container(
                width: 30,
                height: 30,
                decoration: BoxDecoration(
                  color: theme.colorScheme.primary,
                  shape: BoxShape.circle,
                  border:
                      Border.all(color: theme.colorScheme.surface, width: 2),
                ),
                child: Icon(Icons.camera_alt,
                    size: 14, color: theme.colorScheme.onPrimary),
              ),
            ),
          ),

          const SizedBox(height: 14),
          Text(
            user.fullName,
            style: theme.textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            '${user.role} · ${user.company}',
            style: theme.textTheme.bodyLarge?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),

          const SizedBox(height: 14),

          // Bottoni QR e modifica profilo
          Wrap(
            spacing: 8,
            runSpacing: 8,
            alignment: WrapAlignment.center,
            children: [
              OutlinedButton.icon(
                icon: const Icon(Icons.qr_code, size: 18),
                label: const Text('Mostra QR'),
                onPressed: () => _showQrCode(context, user),
                style: OutlinedButton.styleFrom(
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(20),
                  ),
                ),
              ),
              OutlinedButton.icon(
                icon: const Icon(Icons.qr_code_scanner, size: 18),
                label: const Text('Scansiona'),
                onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => const QrScannerScreen(),
                  ),
                ),
                style: OutlinedButton.styleFrom(
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(20),
                  ),
                ),
              ),
              OutlinedButton.icon(
                icon: const Icon(Icons.edit_outlined, size: 18),
                label: const Text('Modifica'),
                onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => EditProfileScreen(user: user),
                  ),
                ),
                style: OutlinedButton.styleFrom(
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(20),
                  ),
                ),
              ),
            ],
          ),

          const SizedBox(height: 24),

          // Sezioni con i dettagli del profilo
          _SectionHeader('Contatti'),
          _InfoCard(
            icon: Icons.email_outlined,
            label: 'Email',
            value: user.email,
          ),
          if (user.phone != null && user.phone!.isNotEmpty)
            _InfoCard(
              icon: Icons.phone_outlined,
              label: 'Telefono',
              value: user.phone!,
            ),

          if (_hasSocials(user)) ...[
            _SectionHeader('Social'),
            if (user.linkedin != null && user.linkedin!.isNotEmpty)
              _InfoCard(
                icon: Icons.link_outlined,
                label: 'LinkedIn',
                value: user.linkedin!,
              ),
            if (user.github != null && user.github!.isNotEmpty)
              _InfoCard(
                icon: Icons.code_outlined,
                label: 'GitHub',
                value: user.github!,
              ),
            if (user.twitter != null && user.twitter!.isNotEmpty)
              _InfoCard(
                icon: Icons.alternate_email,
                label: 'Twitter / X',
                value: user.twitter!,
              ),
          ],

          if (user.bio != null && user.bio!.isNotEmpty) ...[
            _SectionHeader('Bio'),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: theme.colorScheme.surface,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: theme.colorScheme.outlineVariant),
              ),
              child: Text(
                user.bio!,
                style: const TextStyle(fontSize: 14, height: 1.5),
              ),
            ),
          ],

          const SizedBox(height: 24),

          // Bottone per uscire dall'evento
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              icon: const Icon(Icons.exit_to_app),
              label: const Text('Esci dall\'evento'),
              onPressed: _deletingAccount
                  ? null
                  : () async {
                      await EventSessionService.instance.leaveEvent();
                      if (context.mounted) {
                        Navigator.of(context).popUntil((route) => route.isFirst);
                      }
                    },
              style: OutlinedButton.styleFrom(
                foregroundColor: theme.colorScheme.error,
                side: BorderSide(color: theme.colorScheme.error),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
          ),

          const SizedBox(height: 32),

          // ── Danger zone: eliminazione account (App Store Guideline 5.1.1v) ──
          const Divider(),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerLeft,
            child: Text(
              'GESTIONE ACCOUNT',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.bold,
                letterSpacing: 1.2,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              icon: _loggingOut
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.logout, size: 20),
              label: Text(_loggingOut ? 'Disconnessione…' : 'Logout'),
              onPressed: (_loggingOut || _deletingAccount)
                  ? null
                  : _confirmAndLogout,
              style: OutlinedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 14),
              ),
            ),
          ),
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: TextButton.icon(
              icon: _deletingAccount
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.delete_forever_outlined, size: 20),
              label: Text(
                _deletingAccount
                    ? 'Eliminazione in corso…'
                    : 'Elimina account',
              ),
              onPressed: _deletingAccount ? null : _confirmAndDeleteAccount,
              style: TextButton.styleFrom(
                foregroundColor: theme.colorScheme.error,
                padding: const EdgeInsets.symmetric(vertical: 14),
              ),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'L\'eliminazione è permanente e rimuove tutti i tuoi dati.',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 12,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 20),
        ],
      ),
    );
  }

  bool _hasSocials(UserModel user) {
    return (user.linkedin != null && user.linkedin!.isNotEmpty) ||
        (user.github != null && user.github!.isNotEmpty) ||
        (user.twitter != null && user.twitter!.isNotEmpty);
  }

  void _showQrCode(BuildContext context, UserModel user) {
    final theme = Theme.of(context);
    final eventId = EventSessionService.instance.currentEventId ?? '';

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => SingleChildScrollView(
        padding: EdgeInsets.only(
          left: 32,
          right: 32,
          top: 32,
          bottom: MediaQuery.of(ctx).viewInsets.bottom + 32,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: theme.colorScheme.outlineVariant,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 24),
            Text(
              'Il tuo QR Swaply',
              style: theme.textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Mostralo a qualcuno per scambiare il biglietto',
              style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            Container(
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(16),
              ),
              padding: const EdgeInsets.all(16),
              child: QrImageView(
                data: 'proximeet://user/${user.uid}?event=$eventId',
                version: QrVersions.auto,
                size: 200,
              ),
            ),
            const SizedBox(height: 16),
            Text(user.fullName,
                style: const TextStyle(fontWeight: FontWeight.bold)),
            Text(
              '${user.role} · ${user.company}',
              style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: 32),
          ],
        ),
      ),
    );
  }
}

// ── Componenti riutilizzabili ───────────────────────────────

class _SectionHeader extends StatelessWidget {
  final String title;
  const _SectionHeader(this.title);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8, top: 8),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Text(
          title.toUpperCase(),
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.bold,
            letterSpacing: 1.2,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}

class _InfoCard extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;

  const _InfoCard({
    required this.icon,
    required this.label,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Row(
        children: [
          Icon(icon, color: theme.colorScheme.primary, size: 20),
          const SizedBox(width: 12),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: TextStyle(
                  fontSize: 11,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              Text(value,
                  style: const TextStyle(fontWeight: FontWeight.w500)),
            ],
          ),
        ],
      ),
    );
  }
}

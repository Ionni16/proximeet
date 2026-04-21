import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../models/user_model.dart';
import '../../services/auth_service.dart';
import '../../services/event_session_service.dart';
import '../../services/storage_service.dart';
import '../../widgets/user_avatar.dart';
import '../profile/edit_profile_screen.dart';
import 'qr_scanner_screen.dart';

/// Tab Profilo: avatar, info, QR mostra/scansiona, modifica, esci.
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

  Future<void> _changePhoto() async {
    final file = await StorageService.instance.pickImage();
    if (file == null) return;
    setState(() => _uploadingPhoto = true);
    try {
      final uid = FirebaseAuth.instance.currentUser?.uid;
      if (uid == null) return;
      final url = await StorageService.instance.uploadAvatar(uid, file);
      if (url != null) {
        // 1. Aggiorna profilo principale in users/
        await AuthService.instance.updateAvatar(uid, url);

        // 2. Aggiorna anche il bleMapping nell'evento corrente
        // così gli altri partecipanti vedono subito la nuova foto
        await EventSessionService.instance.updateMyProfileInEvent({
          'avatarURL': url,
        });

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Foto aggiornata!')),
          );
        }
      }
    } finally {
      if (mounted) setState(() => _uploadingPhoto = false);
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

          // Avatar
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

          // ── QR Mostra + QR Scansiona + Modifica ──
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

          // Info sections
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

          // Esci dall'evento
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              icon: const Icon(Icons.exit_to_app),
              label: const Text('Esci dall\'evento'),
              onPressed: () async {
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
              'Il tuo QR ProxiMeet',
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

// ── Componenti condivisi ────────────────────────────────────

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

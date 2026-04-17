import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../models/nearby_user.dart';
import '../services/firestore_service.dart';
import 'user_avatar.dart';

/// Bottom sheet dettagliato per un utente rilevato via BLE.
///
/// Mostra: avatar, nome, ruolo, azienda, bio, distanza BLE,
/// contatti (email, telefono, LinkedIn) e bottone "Scambia biglietto".
class NearbyUserCard {
  NearbyUserCard._();

  static void show(BuildContext context, NearbyUser nearby) {
    final theme = Theme.of(context);

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => DraggableScrollableSheet(
        initialChildSize: 0.55,
        minChildSize: 0.35,
        maxChildSize: 0.85,
        expand: false,
        builder: (_, controller) => SingleChildScrollView(
          controller: controller,
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Handle
              Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: theme.colorScheme.outlineVariant,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(height: 20),

              // Avatar grande
              UserAvatar(
                imageUrl: nearby.avatarURL,
                name: nearby.displayName,
                size: 80,
                borderColor: theme.colorScheme.primary,
                borderWidth: 2.5,
              ),
              const SizedBox(height: 14),

              // Nome
              Text(
                nearby.displayName,
                style: theme.textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 4),

              // Ruolo · Azienda
              Text(
                '${nearby.role} · ${nearby.company}',
                style: TextStyle(
                  color: theme.colorScheme.onSurfaceVariant,
                  fontSize: 14,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 12),

              // Chip distanza + RSSI + tempo
              Wrap(
                spacing: 8,
                runSpacing: 8,
                alignment: WrapAlignment.center,
                children: [
                  _Chip(
                    icon: Icons.sensors,
                    label: nearby.distanceLabel,
                    color: _distanceColor(nearby.rssi, theme),
                    theme: theme,
                  ),
                  _Chip(
                    icon: Icons.signal_cellular_alt,
                    label: '${nearby.rssi} dBm',
                    color: theme.colorScheme.surfaceContainerHighest,
                    theme: theme,
                  ),
                  _Chip(
                    icon: Icons.access_time,
                    label: nearby.lastSeenLabel,
                    color: theme.colorScheme.surfaceContainerHighest,
                    theme: theme,
                  ),
                ],
              ),

              // Bio
              if (nearby.bio.isNotEmpty) ...[
                const SizedBox(height: 16),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    nearby.bio,
                    style: TextStyle(
                      fontSize: 13,
                      height: 1.5,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],

              // Contatti preview
              if (nearby.hasSocials) ...[
                const SizedBox(height: 16),
                if (nearby.email.isNotEmpty)
                  _ContactRow(
                    icon: Icons.email_outlined,
                    value: nearby.email,
                    theme: theme,
                  ),
                if (nearby.phone.isNotEmpty)
                  _ContactRow(
                    icon: Icons.phone_outlined,
                    value: nearby.phone,
                    theme: theme,
                  ),
                if (nearby.linkedin.isNotEmpty)
                  _ContactRow(
                    icon: Icons.link_outlined,
                    value: nearby.linkedin,
                    theme: theme,
                  ),
              ],

              const SizedBox(height: 24),

              // Bottone scambia biglietto
              SizedBox(
                width: double.infinity,
                height: 52,
                child: _SendRequestButton(
                  targetUid: nearby.uid,
                  targetName: nearby.firstName,
                ),
              ),
              const SizedBox(height: 16),
            ],
          ),
        ),
      ),
    );
  }

  static Color _distanceColor(int rssi, ThemeData theme) {
    if (rssi >= -50) return theme.colorScheme.primaryContainer;
    if (rssi >= -65) return theme.colorScheme.secondaryContainer;
    if (rssi >= -80) return theme.colorScheme.tertiaryContainer;
    return theme.colorScheme.surfaceContainerHighest;
  }
}

// ── Componenti interni ──────────────────────────────────────

class _Chip extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  final ThemeData theme;

  const _Chip({
    required this.icon,
    required this.label,
    required this.color,
    required this.theme,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(width: 5),
          Text(
            label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

class _ContactRow extends StatelessWidget {
  final IconData icon;
  final String value;
  final ThemeData theme;

  const _ContactRow({
    required this.icon,
    required this.value,
    required this.theme,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onLongPress: () {
          Clipboard.setData(ClipboardData(text: value));
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Copiato negli appunti'),
              duration: Duration(seconds: 1),
            ),
          );
        },
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Row(
            children: [
              Icon(icon, color: theme.colorScheme.primary, size: 18),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  value,
                  style: const TextStyle(fontSize: 13),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Icon(
                Icons.copy,
                size: 14,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Bottone "Scambia biglietto" con stato e gestione errori.
class _SendRequestButton extends StatefulWidget {
  final String targetUid;
  final String targetName;

  const _SendRequestButton({
    required this.targetUid,
    required this.targetName,
  });

  @override
  State<_SendRequestButton> createState() => _SendRequestButtonState();
}

class _SendRequestButtonState extends State<_SendRequestButton> {
  bool _loading = false;

  Future<void> _send() async {
    setState(() => _loading = true);
    try {
      await FirestoreService.instance.sendConnectionRequest(widget.targetUid);
      if (mounted) {
        Navigator.pop(context);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Richiesta inviata a ${widget.targetName}!'),
            backgroundColor: Theme.of(context).colorScheme.primary,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(e.toString().replaceAll('Exception: ', '')),
            backgroundColor: Theme.of(context).colorScheme.error,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return FilledButton.icon(
      icon: _loading
          ? const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: Colors.white,
              ),
            )
          : const Icon(Icons.contactless),
      label: Text(_loading ? 'Invio...' : 'Scambia biglietto'),
      onPressed: _loading ? null : _send,
      style: FilledButton.styleFrom(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    );
  }
}

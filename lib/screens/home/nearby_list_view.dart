import 'package:flutter/material.dart';

import '../../models/nearby_user.dart';
import '../../widgets/user_avatar.dart';

/// Vista lista delle persone rilevate via BLE.
///
/// Ogni card mostra: avatar, nome, ruolo·azienda, distanza,
/// RSSI, bio preview, e ultimo rilevamento.
class NearbyListView extends StatelessWidget {
  final List<NearbyUser> nearbyUsers;
  final ValueChanged<NearbyUser> onUserTap;

  const NearbyListView({
    super.key,
    required this.nearbyUsers,
    required this.onUserTap,
  });

  @override
  Widget build(BuildContext context) {
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      itemCount: nearbyUsers.length,
      separatorBuilder: (_, __) => const SizedBox(height: 10),
      itemBuilder: (context, i) => _NearbyListCard(
        nearby: nearbyUsers[i],
        onTap: () => onUserTap(nearbyUsers[i]),
      ),
    );
  }
}

class _NearbyListCard extends StatelessWidget {
  final NearbyUser nearby;
  final VoidCallback onTap;

  const _NearbyListCard({required this.nearby, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: theme.colorScheme.surface,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: theme.colorScheme.outlineVariant),
        ),
        child: Row(
          children: [
            // Avatar con indicatore distanza
            Stack(
              children: [
                UserAvatar(
                  imageUrl: nearby.avatarURL,
                  name: nearby.displayName,
                  size: 52,
                  borderColor: _distanceColor(nearby.rssi, theme),
                  borderWidth: 2,
                ),
                Positioned(
                  bottom: 0,
                  right: 0,
                  child: Container(
                    width: 18,
                    height: 18,
                    decoration: BoxDecoration(
                      color: _distanceColor(nearby.rssi, theme),
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: theme.colorScheme.surface,
                        width: 2,
                      ),
                    ),
                    child: Icon(
                      _distanceIcon(nearby.rssi),
                      size: 10,
                      color: theme.colorScheme.onPrimaryContainer,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(width: 14),

            // Info
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Nome
                  Text(
                    nearby.displayName,
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 15,
                    ),
                  ),
                  const SizedBox(height: 2),

                  // Ruolo · Azienda
                  Text(
                    '${nearby.role} · ${nearby.company}',
                    style: TextStyle(
                      fontSize: 13,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),

                  // Bio preview
                  if (nearby.bio.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(
                      nearby.bio,
                      style: TextStyle(
                        fontSize: 12,
                        color: theme.colorScheme.onSurfaceVariant,
                        fontStyle: FontStyle.italic,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],

                  const SizedBox(height: 6),

                  // Chips: distanza + tempo
                  Row(
                    children: [
                      _MiniChip(
                        label: nearby.distanceLabel,
                        color: _distanceColor(nearby.rssi, theme),
                        theme: theme,
                      ),
                      const SizedBox(width: 6),
                      _MiniChip(
                        label: '${nearby.rssi} dBm',
                        color: theme.colorScheme.surfaceContainerHighest,
                        theme: theme,
                      ),
                      const SizedBox(width: 6),
                      Text(
                        nearby.lastSeenLabel,
                        style: TextStyle(
                          fontSize: 11,
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),

            Icon(
              Icons.chevron_right,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ],
        ),
      ),
    );
  }

  Color _distanceColor(int rssi, ThemeData theme) {
    if (rssi >= -50) return theme.colorScheme.primaryContainer;
    if (rssi >= -65) return theme.colorScheme.secondaryContainer;
    if (rssi >= -80) return theme.colorScheme.tertiaryContainer;
    return theme.colorScheme.surfaceContainerHighest;
  }

  IconData _distanceIcon(int rssi) {
    if (rssi >= -50) return Icons.signal_cellular_4_bar;
    if (rssi >= -65) return Icons.signal_cellular_alt;
    if (rssi >= -80) return Icons.signal_cellular_alt_2_bar;
    return Icons.signal_cellular_alt_1_bar;
  }
}

class _MiniChip extends StatelessWidget {
  final String label;
  final Color color;
  final ThemeData theme;

  const _MiniChip({
    required this.label,
    required this.color,
    required this.theme,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w600,
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

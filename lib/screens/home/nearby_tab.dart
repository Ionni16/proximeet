import 'dart:async';
import 'package:flutter/material.dart';

import '../../models/user_model.dart';
import '../../models/nearby_user.dart';
import '../../services/nearby_detection_service.dart';
import '../../widgets/nearby_user_card.dart';
import 'radar_view.dart';
import 'nearby_list_view.dart';

/// Tab "Nearby" con toggle Radar / Lista.
///
/// Ascolta [NearbyDetectionService] come unica sorgente di verità
/// e passa la lista a entrambe le view.
class NearbyTab extends StatefulWidget {
  final UserModel currentUser;

  const NearbyTab({super.key, required this.currentUser});

  @override
  State<NearbyTab> createState() => _NearbyTabState();
}

enum _ViewMode { radar, list }

class _NearbyTabState extends State<NearbyTab> {
  _ViewMode _viewMode = _ViewMode.radar;
  List<NearbyUser> _nearbyUsers = [];
  StreamSubscription? _nearbySub;

  @override
  void initState() {
    super.initState();
    _nearbySub =
        NearbyDetectionService.instance.nearbyStream.listen((users) {
      if (mounted) setState(() => _nearbyUsers = users);
    });
  }

  @override
  void dispose() {
    _nearbySub?.cancel();
    super.dispose();
  }

  void _onUserTap(NearbyUser nearby) {
    NearbyUserCard.show(context, nearby);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Column(
      children: [
        // ── Toggle Radar / Lista ──
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Row(
            children: [
              Expanded(
                child: SegmentedButton<_ViewMode>(
                  segments: const [
                    ButtonSegment(
                      value: _ViewMode.radar,
                      label: Text('Radar'),
                      icon: Icon(Icons.radar, size: 18),
                    ),
                    ButtonSegment(
                      value: _ViewMode.list,
                      label: Text('Lista'),
                      icon: Icon(Icons.list, size: 18),
                    ),
                  ],
                  selected: {_viewMode},
                  onSelectionChanged: (set) {
                    setState(() => _viewMode = set.first);
                  },
                  style: ButtonStyle(
                    visualDensity: VisualDensity.compact,
                    shape: WidgetStatePropertyAll(
                      RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              // Contatore persone
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  color: theme.colorScheme.primaryContainer,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.people, size: 16,
                        color: theme.colorScheme.primary),
                    const SizedBox(width: 4),
                    Text(
                      '${_nearbyUsers.length}',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        color: theme.colorScheme.primary,
                        fontSize: 14,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),

        
        // ── Contenuto ──
        Expanded(
          child: _viewMode == _ViewMode.radar
              ? RadarView(
                  currentUser: widget.currentUser,
                  nearbyUsers: _nearbyUsers,
                  onUserTap: _onUserTap,
                )
              : (_nearbyUsers.isEmpty
                  ? _EmptyState(theme: theme)
                  : NearbyListView(
                      nearbyUsers: _nearbyUsers,
                      onUserTap: _onUserTap,
                    )),
        ),
      ],
    );
  }
}

class _EmptyState extends StatelessWidget {
  final ThemeData theme;

  const _EmptyState({required this.theme});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          TweenAnimationBuilder<double>(
            tween: Tween(begin: 0.8, end: 1.2),
            duration: const Duration(seconds: 2),
            curve: Curves.easeInOut,
            builder: (context, scale, child) => Transform.scale(
              scale: scale,
              child: child,
            ),
            onEnd: () {},
            child: Icon(
              Icons.sensors,
              size: 56,
              color: theme.colorScheme.primary.withOpacity(0.5),
            ),
          ),
          const SizedBox(height: 16),
          Text(
            'Scansione in corso...',
            style: TextStyle(
              fontWeight: FontWeight.w600,
              color: theme.colorScheme.onSurfaceVariant,
              fontSize: 16,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'Le persone vicine appariranno qui',
            style: TextStyle(
              fontSize: 13,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

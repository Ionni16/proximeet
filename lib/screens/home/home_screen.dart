import 'dart:ui';
import 'package:flutter/material.dart';

import '../../models/user_model.dart';
import '../../models/connection_model.dart';
import '../../services/event_session_service.dart';
import '../../services/firestore_service.dart';
import 'nearby_tab.dart';
import 'wallet_tab.dart';
import 'profile_tab.dart';
import 'requests_screen.dart';

class HomeScreen extends StatefulWidget {
  final String eventId;
  final String eventName;
  final UserModel currentUser;

  const HomeScreen({
    super.key,
    required this.eventId,
    required this.eventName,
    required this.currentUser,
  });

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int _selectedIndex = 0;
  bool _isLeaving = false;

  Future<void> _leaveEvent() async {
    if (_isLeaving) return;

    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: const Icon(Icons.exit_to_app, size: 36, color: Color(0xFF4D8EF7)),
        title: const Text('Esci dall\'evento?'),
        content: const Text(
          'Verrai disconnesso dal radar BLE e non potrai '
          'rilevare nuove persone vicine.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Annulla'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Esci'),
          ),
        ],
      ),
    );

    if (confirm != true || !mounted) return;

    setState(() => _isLeaving = true);

    try {
      await EventSessionService.instance.leaveEvent();
      if (mounted) Navigator.pop(context);
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Errore durante l\'uscita dall\'evento')),
      );
    } finally {
      if (mounted) setState(() => _isLeaving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvoked: (didPop) async {
        if (didPop) return;
        await _leaveEvent();
      },
      child: Scaffold(
        backgroundColor: const Color(0xFF050D1E),
        extendBody: false,
        appBar: _buildAppBar(),
        body: IndexedStack(
          index: _selectedIndex,
          children: [
            NearbyTab(currentUser: widget.currentUser),
            const WalletTab(),
            ProfileTab(currentUser: widget.currentUser),
          ],
        ),
        bottomNavigationBar: _buildBottomNav(),
      ),
    );
  }

  PreferredSizeWidget _buildAppBar() {
    return PreferredSize(
      preferredSize: const Size.fromHeight(64),
      child: ClipRect(
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
          child: Container(
            height: 64 + MediaQuery.of(context).padding.top,
            padding: EdgeInsets.only(top: MediaQuery.of(context).padding.top),
            decoration: BoxDecoration(
              color: const Color(0xFF050D1E).withOpacity(0.8),
              border: const Border(
                bottom: BorderSide(color: Color(0xFF1A2D47), width: 1),
              ),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                // Back button
                IconButton(
                  icon: const Icon(Icons.arrow_back_ios_new,
                      size: 18, color: Color(0xFF8BA3C7)),
                  tooltip: 'Esci dall\'evento',
                  onPressed: _isLeaving ? null : _leaveEvent,
                ),

                // Logo + info evento
                const SizedBox(
                  width: 28,
                  height: 28,
                  child: Icon(Icons.wifi_tethering,
                      size: 21, color: Color(0xFF4D8EF7)),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        widget.eventName,
                        style: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                          color: Color(0xFFE8F0FE),
                          letterSpacing: -0.2,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                      Row(
                        children: [
                          Container(
                            width: 6,
                            height: 6,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: _isLeaving
                                  ? const Color(0xFFEF5350)
                                  : const Color(0xFF4CAF50),
                              boxShadow: _isLeaving
                                  ? null
                                  : [
                                      BoxShadow(
                                        color: const Color(0xFF4CAF50)
                                            .withOpacity(0.5),
                                        blurRadius: 6,
                                      ),
                                    ],
                            ),
                          ),
                          const SizedBox(width: 5),
                          Text(
                            _isLeaving ? 'Uscita in corso...' : 'Radar attivo',
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w500,
                              color: _isLeaving
                                  ? const Color(0xFFEF5350)
                                  : const Color(0xFF4CAF50),
                              letterSpacing: 0.2,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),

                // Notifiche
                StreamBuilder<List<ConnectionRequest>>(
                  stream: FirestoreService.instance.listenToIncomingRequests(),
                  builder: (context, snapshot) {
                    final count = snapshot.data?.length ?? 0;
                    return IconButton(
                      icon: Badge(
                        isLabelVisible: count > 0,
                        label: Text('$count',
                            style: const TextStyle(fontSize: 10)),
                        backgroundColor: const Color(0xFFEF5350),
                        child: const Icon(Icons.notifications_outlined,
                            color: Color(0xFF8BA3C7)),
                      ),
                      tooltip: 'Richieste',
                      onPressed: _isLeaving
                          ? null
                          : () => Navigator.push(
                                context,
                                MaterialPageRoute(
                                    builder: (_) => const RequestsScreen()),
                              ),
                    );
                  },
                ),
                const SizedBox(width: 4),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildBottomNav() {
    return ClipRect(
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
        child: Container(
          decoration: BoxDecoration(
            color: const Color(0xFF050D1E).withOpacity(0.85),
            border: const Border(
              top: BorderSide(color: Color(0xFF1A2D47), width: 1),
            ),
          ),
          child: SafeArea(
            top: false,
            child: SizedBox(
              height: 64,
              child: Row(
                children: [
                  _NavItem(
                    icon: Icons.radar_outlined,
                    activeIcon: Icons.radar,
                    label: 'Nearby',
                    selected: _selectedIndex == 0,
                    onTap: _isLeaving ? null : () => setState(() => _selectedIndex = 0),
                  ),
                  _NavItem(
                    icon: Icons.badge_outlined,
                    activeIcon: Icons.badge,
                    label: 'Wallet',
                    selected: _selectedIndex == 1,
                    onTap: _isLeaving ? null : () => setState(() => _selectedIndex = 1),
                  ),
                  _NavItem(
                    icon: Icons.person_outline,
                    activeIcon: Icons.person,
                    label: 'Profilo',
                    selected: _selectedIndex == 2,
                    onTap: _isLeaving ? null : () => setState(() => _selectedIndex = 2),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _NavItem extends StatelessWidget {
  final IconData icon;
  final IconData activeIcon;
  final String label;
  final bool selected;
  final VoidCallback? onTap;

  const _NavItem({
    required this.icon,
    required this.activeIcon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    const activeColor = Color(0xFF4D8EF7);
    const inactiveColor = Color(0xFF4A6080);

    return Expanded(
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              // Pill indicator
              AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                width: selected ? 48 : 0,
                height: 3,
                margin: const EdgeInsets.only(bottom: 3),
                decoration: BoxDecoration(
                  color: selected ? activeColor : Colors.transparent,
                  borderRadius: BorderRadius.circular(2),
                  boxShadow: selected
                      ? [
                          BoxShadow(
                            color: activeColor.withOpacity(0.5),
                            blurRadius: 8,
                          ),
                        ]
                      : null,
                ),
              ),
              Icon(
                selected ? activeIcon : icon,
                size: 21,
                color: selected ? activeColor : inactiveColor,
              ),
              const SizedBox(height: 2),
              Text(
                label,
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                  color: selected ? activeColor : inactiveColor,
                  letterSpacing: 0.3,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

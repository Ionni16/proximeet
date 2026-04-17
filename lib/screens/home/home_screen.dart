import 'package:flutter/material.dart';

import '../../models/user_model.dart';
import '../../models/connection_model.dart';
import '../../services/event_session_service.dart';
import '../../services/firestore_service.dart';
import 'nearby_tab.dart';
import 'wallet_tab.dart';
import 'profile_tab.dart';
import 'requests_screen.dart';

/// Schermata principale durante un evento.
///
/// Responsabilità: solo la shell di navigazione (AppBar + BottomNav).
/// Ogni tab è in un file dedicato.
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

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  int _selectedIndex = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.detached) {
      EventSessionService.instance.leaveEvent();
    }
  }

  Future<void> _leaveEvent() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: const Icon(Icons.exit_to_app, size: 36),
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

    if (confirm != true) return;
    await EventSessionService.instance.leaveEvent();
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          tooltip: 'Esci dall\'evento',
          onPressed: _leaveEvent,
        ),
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'ProxiMeet',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
            ),
            Text(
              widget.eventName,
              style: TextStyle(
                fontSize: 12,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
        actions: [
          // Badge notifiche richieste
          StreamBuilder<List<ConnectionRequest>>(
            stream: FirestoreService.instance.listenToIncomingRequests(),
            builder: (context, snapshot) {
              final count = snapshot.data?.length ?? 0;
              return IconButton(
                icon: Badge(
                  isLabelVisible: count > 0,
                  label: Text('$count'),
                  child: const Icon(Icons.notifications_outlined),
                ),
                tooltip: 'Richieste',
                onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const RequestsScreen()),
                ),
              );
            },
          ),
        ],
      ),
      body: IndexedStack(
        index: _selectedIndex,
        children: [
          NearbyTab(currentUser: widget.currentUser),
          const WalletTab(),
          ProfileTab(currentUser: widget.currentUser),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _selectedIndex,
        onDestinationSelected: (i) => setState(() => _selectedIndex = i),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.radar_outlined),
            selectedIcon: Icon(Icons.radar),
            label: 'Nearby',
          ),
          NavigationDestination(
            icon: Icon(Icons.contacts_outlined),
            selectedIcon: Icon(Icons.contacts),
            label: 'Wallet',
          ),
          NavigationDestination(
            icon: Icon(Icons.person_outlined),
            selectedIcon: Icon(Icons.person),
            label: 'Profilo',
          ),
        ],
      ),
    );
  }
}

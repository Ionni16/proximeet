import 'package:flutter/material.dart';
import '../../models/event_model.dart';
import '../../models/user_model.dart';
import '../../services/firestore_service.dart';
import '../../services/auth_service.dart';
import '../../services/ble_permissions_service.dart';
import '../../services/event_session_service.dart';
import '../home/home_screen.dart';
import 'package:firebase_auth/firebase_auth.dart';

class EventListScreen extends StatefulWidget {
  const EventListScreen({super.key});

  @override
  State<EventListScreen> createState() => _EventListScreenState();
}

class _EventListScreenState extends State<EventListScreen> {
  final _authService = AuthService();
  UserModel? _currentUser;
  bool _joining = false;

  @override
  void initState() {
    super.initState();
    _loadUser();
  }

  Future<void> _loadUser() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;
    final user = await _authService.getUserProfile(uid);
    if (mounted) setState(() => _currentUser = user);
    await _authService.saveFcmToken();
  }

  Future<void> _joinEvent(EventModel event) async {
    if (_currentUser == null || _joining) return;
    setState(() => _joining = true);

    try {
      // 1. Controlla Bluetooth
      final btOn = await BlePermissionsService.shared.isBluetoothOn();
      if (!btOn && mounted) {
        final confirm = await showDialog<bool>(
          context: context,
          barrierDismissible: false,
          builder: (ctx) => AlertDialog(
            icon: const Icon(Icons.bluetooth_disabled, size: 40),
            title: const Text('Bluetooth spento'),
            content: const Text(
              'ProxiMeet ha bisogno del Bluetooth per rilevare '
              'le persone vicine. Vuoi attivarlo?',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Non ora'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Attiva'),
              ),
            ],
          ),
        );
        if (confirm == true) {
          await BlePermissionsService.shared.turnOnBluetooth();
          await Future.delayed(const Duration(seconds: 2));
        } else {
          setState(() => _joining = false);
          return;
        }
      }

      // 2. Permessi
      final granted =
          await BlePermissionsService.shared.requestAllPermissions();
      if (!granted && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Permessi Bluetooth negati — impossibile rilevare utenti vicini',
            ),
            backgroundColor: Colors.red,
          ),
        );
        setState(() => _joining = false);
        return;
      }

      // 3. Join evento
      final ok = await EventSessionService.shared.joinEvent(
        eventId: event.id,
        user: _currentUser!,
      );

      if (ok && mounted) {
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => HomeScreen(
              eventId: event.id,
              eventName: event.name,
              currentUser: _currentUser!,
            ),
          ),
        );
      } else if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Errore durante l\'ingresso all\'evento'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Errore: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _joining = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            Icon(Icons.wifi_tethering,
                color: theme.colorScheme.primary, size: 24),
            const SizedBox(width: 8),
            const Text('ProxiMeet',
                style: TextStyle(fontWeight: FontWeight.bold)),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.logout),
            tooltip: 'Esci',
            onPressed: () => _authService.logout(),
          ),
        ],
      ),
      body: _currentUser == null
          ? const Center(child: CircularProgressIndicator())
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Header
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Ciao, ${_currentUser!.firstName}!',
                        style: theme.textTheme.headlineSmall?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Seleziona un evento per iniziare',
                        style: TextStyle(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),

                // Lista eventi
                Expanded(
                  child: StreamBuilder<List<EventModel>>(
                    stream: FirestoreService.shared.listenToActiveEvents(),
                    builder: (context, snapshot) {
                      if (snapshot.connectionState == ConnectionState.waiting) {
                        return const Center(
                            child: CircularProgressIndicator());
                      }

                      final events = snapshot.data ?? [];

                      if (events.isEmpty) {
                        return Center(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(
                                Icons.event_busy_outlined,
                                size: 64,
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                              const SizedBox(height: 16),
                              Text(
                                'Nessun evento attivo',
                                style: theme.textTheme.titleMedium,
                              ),
                              const SizedBox(height: 8),
                              Text(
                                'Gli eventi disponibili appariranno qui',
                                style: TextStyle(
                                  color: theme.colorScheme.onSurfaceVariant,
                                ),
                              ),
                            ],
                          ),
                        );
                      }

                      return ListView.separated(
                        padding: const EdgeInsets.all(16),
                        itemCount: events.length,
                        separatorBuilder: (_, __) =>
                            const SizedBox(height: 12),
                        itemBuilder: (context, i) {
                          return _EventCard(
                            event: events[i],
                            onJoin: () => _joinEvent(events[i]),
                            isJoining: _joining,
                          );
                        },
                      );
                    },
                  ),
                ),
              ],
            ),
    );
  }
}

class _EventCard extends StatelessWidget {
  final EventModel event;
  final VoidCallback onJoin;
  final bool isJoining;

  const _EventCard({
    required this.event,
    required this.onJoin,
    required this.isJoining,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: theme.colorScheme.primaryContainer,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(
                  Icons.event,
                  color: theme.colorScheme.primary,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      event.name,
                      style: const TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 16,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Row(
                      children: [
                        Icon(Icons.location_on_outlined,
                            size: 14,
                            color: theme.colorScheme.onSurfaceVariant),
                        const SizedBox(width: 4),
                        Text(
                          event.location,
                          style: TextStyle(
                            fontSize: 13,
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (event.description.isNotEmpty) ...[
            const SizedBox(height: 12),
            Text(
              event.description,
              style: TextStyle(
                fontSize: 13,
                color: theme.colorScheme.onSurfaceVariant,
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ],
          const SizedBox(height: 16),

          // Conteggio presenti + bottone
          Row(
            children: [
              // Partecipanti attivi
              StreamBuilder<int>(
                stream:
                    FirestoreService.shared.listenToActiveCount(event.id),
                builder: (context, snap) {
                  final count = snap.data ?? 0;
                  return Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.primaryContainer,
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.people_outline,
                            size: 14, color: theme.colorScheme.primary),
                        const SizedBox(width: 4),
                        Text(
                          '$count presenti',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: theme.colorScheme.primary,
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),

              const Spacer(),

              // Bottone entra
              FilledButton.icon(
                icon: isJoining
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Icon(Icons.login, size: 18),
                label: Text(isJoining ? 'Ingresso...' : 'Entra'),
                onPressed: isJoining ? null : onJoin,
                style: FilledButton.styleFrom(
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

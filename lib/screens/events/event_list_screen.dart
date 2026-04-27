import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';

import '../../core/app_debug_error.dart';
import '../../models/event_model.dart';
import '../../models/user_model.dart';
import '../../services/firestore_service.dart';
import '../../services/auth_service.dart';
import '../../services/ble_permissions_service.dart';
import '../../services/debug_error_service.dart';
import '../../services/event_session_service.dart';
import '../../widgets/debug_error_sheet.dart';
import '../home/home_screen.dart';

class EventListScreen extends StatefulWidget {
  const EventListScreen({super.key});

  @override
  State<EventListScreen> createState() => _EventListScreenState();
}

class _EventListScreenState extends State<EventListScreen> {
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
    final user = await AuthService.instance.getUserProfile(uid);
    if (mounted) setState(() => _currentUser = user);
    await AuthService.instance.saveFcmToken();
  }

  Future<void> _joinEvent(EventModel event) async {
    if (_currentUser == null || _joining) return;

    DebugErrorService.instance.clear();
    setState(() => _joining = true);

    try {
      final btOn = await BlePermissionsService.instance.isBluetoothOn();

      if (!btOn && mounted) {
        final confirm = await showDialog<bool>(
          context: context,
          barrierDismissible: false,
          builder: (ctx) => AlertDialog(
            icon: const Icon(Icons.bluetooth_disabled, size: 40),
            title: const Text('Bluetooth spento'),
            content: const Text(
              'ProxiMeet usa Bluetooth/iBeacon per rilevare le persone vicine. '
              'Puoi entrare comunque, ma il rilevamento potrebbe non funzionare.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Entra comunque'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Attiva'),
              ),
            ],
          ),
        );

        if (confirm == true) {
          await BlePermissionsService.instance.turnOnBluetooth();
          await Future.delayed(const Duration(seconds: 2));
        }
      }

      final granted = await BlePermissionsService.instance.requestAllPermissions();

      if (!granted && mounted) {
        final warning = DebugErrorService.instance.add(AppDebugError(
          title: 'Permessi non completi',
          area: 'PERMISSIONS',
          code: 'PERMISSIONS_NOT_FULLY_GRANTED',
          message:
              'Bluetooth/posizione non sono completi. L’ingresso evento continua, ma il rilevamento nearby potrebbe non funzionare.',
          suggestion:
              'Apri Impostazioni app e abilita Bluetooth e Localizzazione. Su Android abilita anche Nearby devices.',
        ));

        _showWarningSnack(
          'Permessi non completi. Puoi entrare comunque.',
          error: warning,
        );
      }

      final ok = await EventSessionService.instance.joinEvent(
        eventId: event.id,
        user: _currentUser!,
      );

      if (ok && mounted) {
        final nonBlockingError = DebugErrorService.instance.latest;
        if (nonBlockingError != null) {
          _showWarningSnack(
            'Evento aperto. Rilevamento nearby da verificare.',
            error: nonBlockingError,
          );
        }

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
        final error = EventSessionService.instance.lastJoinDebugError ??
            DebugErrorService.instance.latest ??
            AppDebugError(
              title: 'Ingresso evento non riuscito',
              area: 'SESSION_JOIN',
              code: 'JOIN_RETURNED_FALSE',
              message:
                  'EventSessionService.joinEvent ha restituito false senza dettagli aggiuntivi.',
              suggestion:
                  'Controlla console, autenticazione e scrittura Firestore presence/bleMapping.',
            );

        await showDebugErrorSheet(context, error);
      }
    } catch (e, st) {
      final error = DebugErrorService.instance.fromException(
        area: 'EVENT_LIST_JOIN_BUTTON',
        fallbackTitle: 'Errore ingresso evento',
        fallbackMessage: 'Errore non gestito durante il tap su Entra.',
        fallbackSuggestion:
            'Copia i dettagli e controlla lo stack trace. Probabile problema UI, permessi o servizio sessione.',
        error: e,
        stackTrace: st,
        data: <String, Object?>{
          'eventId': event.id,
          'eventName': event.name,
          'currentUserUid': _currentUser?.uid,
        },
      );

      if (mounted) {
        await showDebugErrorSheet(context, error);
      }
    } finally {
      if (mounted) setState(() => _joining = false);
    }
  }

  void _showWarningSnack(String message, {required AppDebugError error}) {
    if (!mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: Colors.orange,
        action: SnackBarAction(
          label: 'Dettagli',
          onPressed: () => showDebugErrorSheet(context, error),
        ),
      ),
    );
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
            onPressed: () => AuthService.instance.logout(),
          ),
        ],
      ),
      body: _currentUser == null
          ? const Center(child: CircularProgressIndicator())
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
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
                Expanded(
                  child: StreamBuilder<List<EventModel>>(
                    stream:
                        FirestoreService.instance.listenToActiveEvents(),
                    builder: (context, snapshot) {
                      if (snapshot.connectionState ==
                          ConnectionState.waiting) {
                        return const Center(
                            child: CircularProgressIndicator());
                      }

                      final events = snapshot.data ?? [];

                      if (events.isEmpty) {
                        return Center(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(Icons.event_busy_outlined,
                                  size: 64,
                                  color:
                                      theme.colorScheme.onSurfaceVariant),
                              const SizedBox(height: 16),
                              Text('Nessun evento attivo',
                                  style: theme.textTheme.titleMedium),
                              const SizedBox(height: 8),
                              Text(
                                'Gli eventi disponibili appariranno qui',
                                style: TextStyle(
                                  color:
                                      theme.colorScheme.onSurfaceVariant,
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
                        itemBuilder: (context, i) => _EventCard(
                          event: events[i],
                          onJoin: () => _joinEvent(events[i]),
                          isJoining: _joining,
                        ),
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
                child: Icon(Icons.event,
                    color: theme.colorScheme.primary),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(event.name,
                        style: const TextStyle(
                            fontWeight: FontWeight.bold, fontSize: 16)),
                    const SizedBox(height: 2),
                    Row(
                      children: [
                        Icon(Icons.location_on_outlined,
                            size: 14,
                            color:
                                theme.colorScheme.onSurfaceVariant),
                        const SizedBox(width: 4),
                        Expanded(
                          child: Text(event.location,
                              style: TextStyle(
                                  fontSize: 13,
                                  color: theme.colorScheme
                                      .onSurfaceVariant),
                              overflow: TextOverflow.ellipsis),
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
            Text(event.description,
                style: TextStyle(
                    fontSize: 13,
                    color: theme.colorScheme.onSurfaceVariant),
                maxLines: 2,
                overflow: TextOverflow.ellipsis),
          ],
          const SizedBox(height: 16),
          Row(
            children: [
              StreamBuilder<int>(
                stream: FirestoreService.instance
                    .listenToActiveCount(event.id),
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
                            size: 14,
                            color: theme.colorScheme.primary),
                        const SizedBox(width: 4),
                        Text('$count presenti',
                            style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                                color: theme.colorScheme.primary)),
                      ],
                    ),
                  );
                },
              ),
              const Spacer(),
              FilledButton.icon(
                icon: isJoining
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white))
                    : const Icon(Icons.login, size: 18),
                label: Text(isJoining ? 'Ingresso...' : 'Entra'),
                onPressed: isJoining ? null : onJoin,
                style: FilledButton.styleFrom(
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10)),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

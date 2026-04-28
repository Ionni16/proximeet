import 'dart:ui';
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
            icon: const Icon(Icons.bluetooth_disabled,
                size: 40, color: Color(0xFF4D8EF7)),
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

      final granted =
          await BlePermissionsService.instance.requestAllPermissions();

      if (!granted && mounted) {
        final warning = DebugErrorService.instance.add(AppDebugError(
          title: 'Permessi non completi',
          area: 'PERMISSIONS',
          code: 'PERMISSIONS_NOT_FULLY_GRANTED',
          message:
              'Bluetooth/posizione non sono completi. L\'ingresso evento continua, ma il rilevamento nearby potrebbe non funzionare.',
          suggestion:
              'Apri Impostazioni app e abilita Bluetooth e Localizzazione.',
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
              message: 'EventSessionService.joinEvent ha restituito false.',
              suggestion: 'Controlla console, autenticazione e Firestore.',
            );
        await showDebugErrorSheet(context, error);
      }
    } catch (e, st) {
      final error = DebugErrorService.instance.fromException(
        area: 'EVENT_LIST_JOIN_BUTTON',
        fallbackTitle: 'Errore ingresso evento',
        fallbackMessage: 'Errore non gestito durante il tap su Entra.',
        fallbackSuggestion: 'Controlla stack trace.',
        error: e,
        stackTrace: st,
        data: <String, Object?>{
          'eventId': event.id,
          'eventName': event.name,
          'currentUserUid': _currentUser?.uid,
        },
      );
      if (mounted) await showDebugErrorSheet(context, error);
    } finally {
      if (mounted) setState(() => _joining = false);
    }
  }

  void _showWarningSnack(String message, {required AppDebugError error}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: const Color(0xFFE65100),
        action: SnackBarAction(
          label: 'Dettagli',
          textColor: Colors.white,
          onPressed: () => showDebugErrorSheet(context, error),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF050D1E),
      body: Stack(
        children: [
          // Background glow subtile
          Positioned(
            top: -100,
            left: -60,
            child: Container(
              width: 300,
              height: 300,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: RadialGradient(
                  colors: [
                    const Color(0xFF1A56DB).withOpacity(0.12),
                    Colors.transparent,
                  ],
                ),
              ),
            ),
          ),

          SafeArea(
            child: _currentUser == null
                ? const Center(
                    child: CircularProgressIndicator(
                      color: Color(0xFF4D8EF7),
                      strokeWidth: 2,
                    ),
                  )
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // ── Header ──
                      Padding(
                        padding: const EdgeInsets.fromLTRB(24, 20, 24, 0),
                        child: Row(
                          children: [
                            // Logo
                            Container(
                              width: 38,
                              height: 38,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: const Color(0xFF0D1B30),
                                border: Border.all(
                                  color: const Color(0xFF1A2D47),
                                ),
                                boxShadow: [
                                  BoxShadow(
                                    color: const Color(0xFF1A56DB)
                                        .withOpacity(0.2),
                                    blurRadius: 12,
                                  ),
                                ],
                              ),
                              child: const Icon(
                                Icons.wifi_tethering,
                                size: 20,
                                color: Color(0xFF4D8EF7),
                              ),
                            ),
                            const SizedBox(width: 12),
                            const Text(
                              'ProxiMeet',
                              style: TextStyle(
                                fontSize: 20,
                                fontWeight: FontWeight.w800,
                                letterSpacing: -0.5,
                                color: Color(0xFFE8F0FE),
                              ),
                            ),
                            const Spacer(),
                            // Logout
                            IconButton(
                              icon: const Icon(Icons.logout_outlined,
                                  color: Color(0xFF4A6080), size: 20),
                              tooltip: 'Esci',
                              onPressed: () => AuthService.instance.logout(),
                            ),
                          ],
                        ),
                      ),

                      const SizedBox(height: 28),

                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 24),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Ciao, ${_currentUser!.firstName} 👋',
                              style: const TextStyle(
                                fontSize: 28,
                                fontWeight: FontWeight.w700,
                                letterSpacing: -0.5,
                                color: Color(0xFFE8F0FE),
                              ),
                            ),
                            const SizedBox(height: 6),
                            const Text(
                              'Seleziona un evento per iniziare il networking',
                              style: TextStyle(
                                fontSize: 14,
                                color: Color(0xFF8BA3C7),
                                height: 1.4,
                              ),
                            ),
                          ],
                        ),
                      ),

                      const SizedBox(height: 24),

                      // Label sezione
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 24),
                        child: Row(
                          children: [
                            const Text(
                              'EVENTI ATTIVI',
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w700,
                                letterSpacing: 1.5,
                                color: Color(0xFF4D8EF7),
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Container(
                                height: 1,
                                color: const Color(0xFF1A2D47),
                              ),
                            ),
                          ],
                        ),
                      ),

                      const SizedBox(height: 14),

                      // Lista eventi
                      Expanded(
                        child: StreamBuilder<List<EventModel>>(
                          stream:
                              FirestoreService.instance.listenToActiveEvents(),
                          builder: (context, snapshot) {
                            if (snapshot.connectionState ==
                                ConnectionState.waiting) {
                              return const Center(
                                child: CircularProgressIndicator(
                                  color: Color(0xFF4D8EF7),
                                  strokeWidth: 2,
                                ),
                              );
                            }

                            final events = snapshot.data ?? [];

                            if (events.isEmpty) {
                              return Center(
                                child: Column(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    Container(
                                      width: 80,
                                      height: 80,
                                      decoration: BoxDecoration(
                                        shape: BoxShape.circle,
                                        color: const Color(0xFF0D1B30),
                                        border: Border.all(
                                          color: const Color(0xFF1A2D47),
                                        ),
                                      ),
                                      child: const Icon(
                                        Icons.event_busy_outlined,
                                        size: 36,
                                        color: Color(0xFF4A6080),
                                      ),
                                    ),
                                    const SizedBox(height: 20),
                                    const Text(
                                      'Nessun evento attivo',
                                      style: TextStyle(
                                        fontSize: 16,
                                        fontWeight: FontWeight.w600,
                                        color: Color(0xFFE8F0FE),
                                      ),
                                    ),
                                    const SizedBox(height: 6),
                                    const Text(
                                      'Gli eventi disponibili appariranno qui',
                                      style: TextStyle(
                                        fontSize: 13,
                                        color: Color(0xFF8BA3C7),
                                      ),
                                    ),
                                  ],
                                ),
                              );
                            }

                            return ListView.separated(
                              padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
                              itemCount: events.length,
                              separatorBuilder: (_, __) =>
                                  const SizedBox(height: 14),
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
          ),
        ],
      ),
    );
  }
}

// ── Event Card premium ───────────────────────────────────────

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
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF0D1B30),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: const Color(0xFF1A2D47),
          width: 1,
        ),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF1A56DB).withOpacity(0.06),
            blurRadius: 24,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header gradient strip
            Container(
              height: 4,
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  colors: [Color(0xFF1A56DB), Color(0xFF4D8EF7)],
                ),
              ),
            ),

            Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Icona evento
                      Container(
                        width: 48,
                        height: 48,
                        decoration: BoxDecoration(
                          color: const Color(0xFF101E35),
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(color: const Color(0xFF1A2D47)),
                        ),
                        child: const Icon(
                          Icons.event_outlined,
                          color: Color(0xFF4D8EF7),
                          size: 24,
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
                                fontSize: 16,
                                fontWeight: FontWeight.w700,
                                color: Color(0xFFE8F0FE),
                                letterSpacing: -0.2,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Row(
                              children: [
                                const Icon(Icons.location_on_outlined,
                                    size: 13, color: Color(0xFF8BA3C7)),
                                const SizedBox(width: 3),
                                Expanded(
                                  child: Text(
                                    event.location,
                                    style: const TextStyle(
                                      fontSize: 12,
                                      color: Color(0xFF8BA3C7),
                                    ),
                                    overflow: TextOverflow.ellipsis,
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
                    const SizedBox(height: 14),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: const Color(0xFF080F1F),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: const Color(0xFF1A2D47)),
                      ),
                      child: Text(
                        event.description,
                        style: const TextStyle(
                          fontSize: 13,
                          color: Color(0xFF8BA3C7),
                          height: 1.5,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],

                  const SizedBox(height: 16),

                  // Footer: partecipanti + CTA
                  Row(
                    children: [
                      StreamBuilder<int>(
                        stream: FirestoreService.instance
                            .listenToActiveCount(event.id),
                        builder: (context, snap) {
                          final count = snap.data ?? 0;
                          return Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 10, vertical: 5),
                            decoration: BoxDecoration(
                              color: const Color(0xFF101E35),
                              borderRadius: BorderRadius.circular(20),
                              border: Border.all(
                                  color: const Color(0xFF1A2D47)),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Container(
                                  width: 6,
                                  height: 6,
                                  decoration: const BoxDecoration(
                                    shape: BoxShape.circle,
                                    color: Color(0xFF4CAF50),
                                    boxShadow: [
                                      BoxShadow(
                                        color: Color(0x804CAF50),
                                        blurRadius: 6,
                                      ),
                                    ],
                                  ),
                                ),
                                const SizedBox(width: 6),
                                Text(
                                  '$count online',
                                  style: const TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600,
                                    color: Color(0xFF8BA3C7),
                                  ),
                                ),
                              ],
                            ),
                          );
                        },
                      ),
                      const Spacer(),

                      // Gradient join button
                      _JoinButton(
                        onPressed: isJoining ? null : onJoin,
                        isJoining: isJoining,
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _JoinButton extends StatelessWidget {
  final VoidCallback? onPressed;
  final bool isJoining;

  const _JoinButton({required this.onPressed, required this.isJoining});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onPressed,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
        decoration: BoxDecoration(
          gradient: isJoining
              ? null
              : const LinearGradient(
                  colors: [Color(0xFF1A56DB), Color(0xFF4D8EF7)],
                ),
          color: isJoining ? const Color(0xFF1A2D47) : null,
          borderRadius: BorderRadius.circular(12),
          boxShadow: isJoining
              ? null
              : [
                  BoxShadow(
                    color: const Color(0xFF1A56DB).withOpacity(0.4),
                    blurRadius: 16,
                    offset: const Offset(0, 4),
                  ),
                ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (isJoining)
              const SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: Color(0xFF4D8EF7),
                ),
              )
            else
              const Icon(Icons.arrow_forward, color: Colors.white, size: 16),
            const SizedBox(width: 6),
            Text(
              isJoining ? 'Ingresso...' : 'Entra',
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: isJoining ? const Color(0xFF8BA3C7) : Colors.white,
                letterSpacing: 0.2,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

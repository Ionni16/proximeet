import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../../services/auth_service.dart';
import '../../services/ble_service.dart';
import '../../models/user_model.dart';
import 'dart:math' show cos, sin;
import 'package:cloud_firestore/cloud_firestore.dart';
import 'dart:async';
import '../../services/firestore_service.dart';
import '../../models/connection_model.dart';
import 'requests_screen.dart';
import 'package:qr_flutter/qr_flutter.dart';
import '../../services/storage_service.dart';
import '../profile/edit_profile_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _authService = AuthService();
  UserModel? _currentUser;
  int _selectedIndex = 0;
  bool _trackingEnabled = true;

  @override
  void initState() {
    super.initState();
    _loadUser();
  }

  Future<void> _loadUser() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;
    final user = await _authService.getUserProfile(uid);
    setState(() => _currentUser = user);
    

    // Salva token FCM per le notifiche push
    await _authService.saveFcmToken();
    // Scrivi presenza su Firestore
    if (user != null) {
      await FirestoreService.shared.updatePresence(uid, user.bleId);
    }

    if (user != null && _trackingEnabled) {
      // 1. Controlla se Bluetooth è acceso
      final btOn = await BleService.shared.isBluetoothOn();
      if (!btOn) {
        if (mounted) {
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
            await BleService.shared.turnOnBluetooth();
            await Future.delayed(const Duration(seconds: 2));
          } else {
            return;
          }
        }
      }

      // 2. Richiedi permessi
      final granted = await BleService.shared.requestPermissions();
      if (!granted) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                'Permessi Bluetooth negati — '
                'ProxiMeet non può rilevare utenti vicini',
              ),
              backgroundColor: Colors.red,
            ),
          );
        }
        return;
      }

      // 3. Avvia BLE
      await BleService.shared.startScanning(user.bleId);
      await BleService.shared.startAdvertising(user.bleId);
    }
  }

  @override
  void dispose() {
    BleService.shared.stopAll();
    super.dispose();
  }

  void _toggleTracking() async {
    setState(() => _trackingEnabled = !_trackingEnabled);
    if (_trackingEnabled && _currentUser != null) {
      await BleService.shared.startScanning(_currentUser!.bleId);
      await BleService.shared.startAdvertising(_currentUser!.bleId);
    } else {
      await BleService.shared.stopAll();
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
        // Richieste in arrivo — AGGIUNGI QUESTO
        StreamBuilder<List<ConnectionRequest>>(
          stream: FirestoreService.shared.listenToIncomingRequests(),
          builder: (context, snapshot) {
            final count = snapshot.data?.length ?? 0;
            return IconButton(
              icon: Badge(
                isLabelVisible: count > 0,
                label: Text('$count'),
                child: const Icon(Icons.notifications_outlined),
              ),
              tooltip: 'Richieste',
              onPressed: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => const RequestsScreen(),
                  ),
                );
              },
            );
          },
        ),
        // Tracking — già esistente
        IconButton(
          icon: Icon(
            _trackingEnabled ? Icons.sensors : Icons.sensors_off,
            color: _trackingEnabled
                ? theme.colorScheme.primary
                : theme.colorScheme.onSurfaceVariant,
          ),
          tooltip: _trackingEnabled ? 'Tracking ON' : 'Tracking OFF',
          onPressed: _toggleTracking,
        ),
        // Logout — già esistente
        IconButton(
          icon: const Icon(Icons.logout),
          tooltip: 'Esci',
          onPressed: () async {
            await BleService.shared.stopAll();
            await _authService.logout();
          },
        ),
      ],
      ),
      body: IndexedStack(
        index: _selectedIndex,
        children: [
          _RadarTab(currentUser: _currentUser),
          _WalletTab(),
          const _ProfileTab(),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _selectedIndex,
        onDestinationSelected: (i) => setState(() => _selectedIndex = i),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.radar_outlined),
            selectedIcon: Icon(Icons.radar),
            label: 'Radar',
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

// ── TAB RADAR ──────────────────────────────────────────────
class _RadarTab extends StatefulWidget {
  final UserModel? currentUser;
  const _RadarTab({this.currentUser});

  @override
  State<_RadarTab> createState() => _RadarTabState();
}

class _RadarTabState extends State<_RadarTab>
    with SingleTickerProviderStateMixin {
  late AnimationController _radarController;
  late Animation<double> _radarAnimation;
  final List<_NearbyUser> _nearbyUsers = [];
  StreamSubscription? _detectionSubscription;

  @override
  void initState() {
    super.initState();

    // Animazione rotazione radar
    _radarController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 3),
    )..repeat();

    _radarAnimation = Tween<double>(
      begin: 0,
      end: 2 * 3.14159,
    ).animate(_radarController);

    // Ascolta rilevazioni BLE
    BleService.shared.onUserDetected = (bleId, rssi) {
      _onUserDetected(bleId, rssi);
    };

    // Ascolta Firestore per utenti che ci hanno rilevato
    if (widget.currentUser != null) {
      _startListeningDetections();
    }
  }

  void _startListeningDetections() {
    final myUid = FirebaseAuth.instance.currentUser?.uid ?? '';

    _detectionSubscription = FirestoreService.shared
        .listenToNearbyUsers(myUid)
        .listen((users) {
      setState(() {
        for (final user in users) {
          final existing = _nearbyUsers.indexWhere(
            (u) => u.bleId == user.bleId,
          );
          if (existing >= 0) {
            _nearbyUsers[existing] = _NearbyUser(
              bleId: user.bleId,
              rssi: -65,
              lastSeen: DateTime.now(),
              user: user,
            );
          } else {
            _nearbyUsers.add(_NearbyUser(
              bleId: user.bleId,
              rssi: -65,
              lastSeen: DateTime.now(),
              user: user,
            ));
          }
        }
        // Rimuovi chi non è più nella lista
        _nearbyUsers.removeWhere(
          (nearby) => !users.any((u) => u.bleId == nearby.bleId),
        );
      });
    });
  }

  void _onUserDetected(String bleId, int rssi, {UserModel? userModel}) {
    setState(() {
      final existing = _nearbyUsers.indexWhere((u) => u.bleId == bleId);
      if (existing >= 0) {
        _nearbyUsers[existing] = _NearbyUser(
          bleId: bleId,
          rssi: rssi,
          lastSeen: DateTime.now(),
          user: userModel ?? _nearbyUsers[existing].user,
        );
      } else {
        _nearbyUsers.add(_NearbyUser(
          bleId: bleId,
          rssi: rssi,
          lastSeen: DateTime.now(),
          user: userModel,
        ));
      }

      // Rimuovi utenti non visti da più di 5 minuti
      _nearbyUsers.removeWhere(
        (u) => DateTime.now().difference(u.lastSeen).inMinutes > 5,
      );
    });
  }

  @override
  void dispose() {
    BleService.shared.stopAll();
    // Rimuovi presenza
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid != null) {
      FirestoreService.shared.removePresence(uid);
    }
    super.dispose();
  }

  // Converte RSSI in distanza approssimativa
  String _rssiToDistance(int rssi) {
    if (rssi >= -50) return 'Vicinissimo';
    if (rssi >= -65) return 'Vicino';
    if (rssi >= -80) return 'Medio';
    return 'Lontano';
  }

  // Posizione utente sul radar in base a RSSI
  double _rssiToRadius(int rssi, double maxRadius) {
    if (rssi >= -50) return maxRadius * 0.25;
    if (rssi >= -65) return maxRadius * 0.5;
    if (rssi >= -80) return maxRadius * 0.75;
    return maxRadius * 0.9;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Column(
      children: [
        // Radar
        Expanded(
          child: Center(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final size = constraints.maxWidth < constraints.maxHeight
                    ? constraints.maxWidth * 0.85
                    : constraints.maxHeight * 0.85;
                final maxRadius = size / 2;

                return SizedBox(
                  width: size,
                  height: size,
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      // Cerchi radar statici
                      for (final fraction in [1.0, 0.75, 0.5, 0.25])
                        Container(
                          width: size * fraction,
                          height: size * fraction,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: theme.colorScheme.primary
                                  .withOpacity(0.15),
                              width: 1,
                            ),
                          ),
                        ),

                      // Linee a croce
                      Container(
                        width: size,
                        height: 1,
                        color:
                            theme.colorScheme.primary.withOpacity(0.1),
                      ),
                      Container(
                        width: 1,
                        height: size,
                        color:
                            theme.colorScheme.primary.withOpacity(0.1),
                      ),

                      // Sweep animato
                      AnimatedBuilder(
                        animation: _radarAnimation,
                        builder: (context, child) {
                          return CustomPaint(
                            size: Size(size, size),
                            painter: _RadarSweepPainter(
                              angle: _radarAnimation.value,
                              color: theme.colorScheme.primary,
                            ),
                          );
                        },
                      ),

                      // Utenti rilevati
                      ..._nearbyUsers.asMap().entries.map((entry) {
                        final i = entry.key;
                        final nearby = entry.value;
                        final angle = (i * 2.4) % (2 * 3.14159);
                        final radius = _rssiToRadius(
                            nearby.rssi, maxRadius * 0.85);
                        final x = radius * cos(angle);
                        final y = radius * sin(angle);

                        return Positioned(
                          left: maxRadius + x - 24,
                          top: maxRadius + y - 24,
                          child: GestureDetector(
                            onTap: () =>
                                _showUserCard(context, nearby),
                            child: _UserDot(
                              user: nearby.user,
                              rssi: nearby.rssi,
                            ),
                          ),
                        );
                      }),

                      // Avatar utente al centro
                      Container(
                        width: 64,
                        height: 64,
                        decoration: BoxDecoration(
                          color: theme.colorScheme.primaryContainer,
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: theme.colorScheme.primary,
                            width: 2.5,
                          ),
                        ),
                        child: Center(
                          child: Text(
                            widget.currentUser?.firstName[0]
                                    .toUpperCase() ??
                                '?',
                            style: TextStyle(
                              fontSize: 26,
                              fontWeight: FontWeight.bold,
                              color: theme.colorScheme.primary,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        ),

        // Lista utenti rilevati
        if (_nearbyUsers.isNotEmpty)
          Container(
            height: 120,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: _nearbyUsers.length,
              separatorBuilder: (_, __) => const SizedBox(width: 12),
              itemBuilder: (context, i) {
                final nearby = _nearbyUsers[i];
                return GestureDetector(
                  onTap: () => _showUserCard(context, nearby),
                  child: Container(
                    width: 90,
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        _UserDot(user: nearby.user, rssi: nearby.rssi),
                        const SizedBox(height: 6),
                        Text(
                          nearby.user?.firstName ?? nearby.bleId.substring(0, 6),
                          style: const TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                        Text(
                          _rssiToDistance(nearby.rssi),
                          style: TextStyle(
                            fontSize: 10,
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          )
        else
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              'Nessuno nelle vicinanze',
              style: TextStyle(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),

        const SizedBox(height: 16),
      ],
    );
  }

  void _showUserCard(BuildContext context, _NearbyUser nearby) {
    if (nearby.user == null) return;
    final user = nearby.user!;
    final theme = Theme.of(context);

    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => Padding(
        padding: const EdgeInsets.all(24),
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

            // Avatar
            Container(
              width: 72,
              height: 72,
              decoration: BoxDecoration(
                color: theme.colorScheme.primaryContainer,
                shape: BoxShape.circle,
              ),
              child: Center(
                child: Text(
                  user.firstName[0].toUpperCase(),
                  style: TextStyle(
                    fontSize: 30,
                    fontWeight: FontWeight.bold,
                    color: theme.colorScheme.primary,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 12),

            Text(
              user.fullName,
              style: theme.textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            Text(
              '${user.role} · ${user.company}',
              style: TextStyle(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 8),
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              decoration: BoxDecoration(
                color: theme.colorScheme.primaryContainer,
                borderRadius: BorderRadius.circular(20),
              ),
              child: Text(
                _rssiToDistance(nearby.rssi),
                style: TextStyle(
                  color: theme.colorScheme.primary,
                  fontWeight: FontWeight.w600,
                  fontSize: 12,
                ),
              ),
            ),

            const SizedBox(height: 24),

            
            // Bottone scambio biglietto
            SizedBox(
              width: double.infinity,
              height: 52,
              child: FilledButton.icon(
                icon: const Icon(Icons.contactless),
                label: const Text('Scambia biglietto'),
                onPressed: () async {
                  Navigator.pop(ctx);
                  await FirestoreService.shared
                      .sendConnectionRequest(user.uid);
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(
                          'Richiesta inviata a ${user.firstName}!',
                        ),
                        backgroundColor: theme.colorScheme.primary,
                      ),
                    );
                  }
                },
                style: FilledButton.styleFrom(
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 12),
          ],
        ),
      ),
    );
  }
}

// Punto utente sul radar
class _UserDot extends StatelessWidget {
  final UserModel? user;
  final int rssi;
  const _UserDot({this.user, required this.rssi});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: 48,
      height: 48,
      decoration: BoxDecoration(
        color: theme.colorScheme.secondaryContainer,
        shape: BoxShape.circle,
        border: Border.all(
          color: theme.colorScheme.secondary,
          width: 2,
        ),
      ),
      child: Center(
        child: Text(
          user?.firstName[0].toUpperCase() ?? '?',
          style: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.bold,
            color: theme.colorScheme.secondary,
          ),
        ),
      ),
    );
  }
}

// Painter per il sweep animato del radar
class _RadarSweepPainter extends CustomPainter {
  final double angle;
  final Color color;
  _RadarSweepPainter({required this.angle, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width / 2;

    final paint = Paint()
      ..shader = SweepGradient(
        startAngle: angle - 1.2,
        endAngle: angle,
        colors: [
          color.withOpacity(0),
          color.withOpacity(0.3),
        ],
        transform: GradientRotation(angle - 1.2),
      ).createShader(Rect.fromCircle(center: center, radius: radius))
      ..style = PaintingStyle.fill;

    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius),
      angle - 1.2,
      1.2,
      true,
      paint,
    );

    // Linea del sweep
    final linePaint = Paint()
      ..color = color.withOpacity(0.6)
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke;

    canvas.drawLine(
      center,
      Offset(
        center.dx + radius * cos(angle),
        center.dy + radius * sin(angle),
      ),
      linePaint,
    );
  }

  @override
  bool shouldRepaint(_RadarSweepPainter old) => old.angle != angle;
}

// Modello utente vicino
class _NearbyUser {
  final String bleId;
  final int rssi;
  final DateTime lastSeen;
  final UserModel? user;

  _NearbyUser({
    required this.bleId,
    required this.rssi,
    required this.lastSeen,
    this.user,
  });
}

// ── TAB WALLET ─────────────────────────────────────────────
class _WalletTab extends StatelessWidget {
  const _WalletTab();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return StreamBuilder<List<WalletContact>>(
      stream: FirestoreService.shared.listenToWallet(),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }

        final contacts = snapshot.data ?? [];

        if (contacts.isEmpty) {
          return Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  Icons.contacts_outlined,
                  size: 64,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                const SizedBox(height: 16),
                Text(
                  'Nessun contatto ancora',
                  style: theme.textTheme.titleMedium,
                ),
                const SizedBox(height: 8),
                Text(
                  'I biglietti scambiati appariranno qui',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          );
        }

        return ListView.separated(
          padding: const EdgeInsets.all(16),
          itemCount: contacts.length,
          separatorBuilder: (_, __) => const SizedBox(height: 12),
          itemBuilder: (context, i) {
            final contact = contacts[i];
            return _ContactCard(contact: contact);
          },
        );
      },
    );
  }
}

class _ContactCard extends StatelessWidget {
  final WalletContact contact;
  const _ContactCard({required this.contact});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return GestureDetector(
      onTap: () => _showContactDetail(context, contact),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: theme.colorScheme.surface,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: theme.colorScheme.outlineVariant),
        ),
        child: Row(
          children: [
            // Avatar
            Container(
              width: 52,
              height: 52,
              decoration: BoxDecoration(
                color: theme.colorScheme.primaryContainer,
                shape: BoxShape.circle,
              ),
              child: Center(
                child: Text(
                  contact.firstName[0].toUpperCase(),
                  style: TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.bold,
                    color: theme.colorScheme.primary,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 14),

            // Info
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    contact.fullName,
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 15,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${contact.role} · ${contact.company}',
                    style: TextStyle(
                      fontSize: 13,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  if (contact.connectedAt != null) ...[
                    const SizedBox(height: 4),
                    Text(
                      'Connesso il ${_formatDate(contact.connectedAt!)}',
                      style: TextStyle(
                        fontSize: 11,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
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

  String _formatDate(DateTime date) {
    return '${date.day}/${date.month}/${date.year}';
  }

  void _showContactDetail(BuildContext context, WalletContact contact) {
    final theme = Theme.of(context);

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => DraggableScrollableSheet(
        initialChildSize: 0.6,
        minChildSize: 0.4,
        maxChildSize: 0.9,
        expand: false,
        builder: (_, controller) => SingleChildScrollView(
          controller: controller,
          padding: const EdgeInsets.all(24),
          child: Column(
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
              const SizedBox(height: 24),

              // Avatar grande
              Container(
                width: 88,
                height: 88,
                decoration: BoxDecoration(
                  color: theme.colorScheme.primaryContainer,
                  shape: BoxShape.circle,
                ),
                child: Center(
                  child: Text(
                    contact.firstName[0].toUpperCase(),
                    style: TextStyle(
                      fontSize: 36,
                      fontWeight: FontWeight.bold,
                      color: theme.colorScheme.primary,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 12),

              Text(
                contact.fullName,
                style: theme.textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
              Text(
                '${contact.role} · ${contact.company}',
                style: TextStyle(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 24),

              // Dettagli contatto
              if (contact.email.isNotEmpty)
                _DetailRow(
                  icon: Icons.email_outlined,
                  label: 'Email',
                  value: contact.email,
                ),
              if (contact.phone.isNotEmpty)
                _DetailRow(
                  icon: Icons.phone_outlined,
                  label: 'Telefono',
                  value: contact.phone,
                ),
              if (contact.linkedin.isNotEmpty)
                _DetailRow(
                  icon: Icons.link_outlined,
                  label: 'LinkedIn',
                  value: contact.linkedin,
                ),

              const SizedBox(height: 24),

              // Bottone salva in rubrica
              SizedBox(
                width: double.infinity,
                height: 52,
                child: FilledButton.icon(
                  icon: const Icon(Icons.person_add_outlined),
                  label: const Text('Salva in rubrica'),
                  onPressed: () {
                    Navigator.pop(ctx);
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('Funzione rubrica — prossimamente!'),
                      ),
                    );
                  },
                  style: FilledButton.styleFrom(
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DetailRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  const _DetailRow({
    required this.icon,
    required this.label,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
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
              Text(
                value,
                style: const TextStyle(fontWeight: FontWeight.w500),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// ── TAB PROFILO ────────────────────────────────────────────
class _ProfileTab extends StatelessWidget {
  const _ProfileTab({super.key}) : super();

  @override
  Widget build(BuildContext context) {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return const Center(child: CircularProgressIndicator());

    // StreamBuilder diretto su Firestore — aggiornamento in tempo reale
    return StreamBuilder<DocumentSnapshot>(
      stream: FirebaseFirestore.instance
          .collection('users')
          .doc(uid)
          .snapshots(),
      builder: (context, snapshot) {
        if (!snapshot.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        final data = snapshot.data!.data() as Map<String, dynamic>?;
        if (data == null) return const Center(child: Text('Profilo non trovato'));
        final user = UserModel.fromMap(data);
        return _ProfileContent(user: user);
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
    final file = await StorageService.shared.pickImage();
    if (file == null) return;
    setState(() => _uploadingPhoto = true);
    try {
      final uid = FirebaseAuth.instance.currentUser?.uid;
      if (uid == null) return;
      final url = await StorageService.shared.uploadAvatar(uid, file);
      if (url != null) {
        await AuthService().updateAvatar(uid, url);
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
          const SizedBox(height: 20),

          // Avatar con bottone modifica
          Stack(
            children: [
              GestureDetector(
                onTap: _changePhoto,
                child: Container(
                  width: 100,
                  height: 100,
                  decoration: BoxDecoration(
                    color: theme.colorScheme.primaryContainer,
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: theme.colorScheme.primary,
                      width: 2.5,
                    ),
                  ),
                  child: ClipOval(
                    child: _uploadingPhoto
                        ? const Center(child: CircularProgressIndicator())
                        : user.avatarURL.isNotEmpty
                            ? Image.network(
                                user.avatarURL,
                                fit: BoxFit.cover,
                                errorBuilder: (_, __, ___) => _initial(user, theme),
                              )
                            : _initial(user, theme),
                  ),
                ),
              ),
              Positioned(
                bottom: 0,
                right: 0,
                child: Container(
                  width: 30,
                  height: 30,
                  decoration: BoxDecoration(
                    color: theme.colorScheme.primary,
                    shape: BoxShape.circle,
                    border: Border.all(
                        color: theme.colorScheme.surface, width: 2),
                  ),
                  child: Icon(Icons.camera_alt,
                      size: 14, color: theme.colorScheme.onPrimary),
                ),
              ),
            ],
          ),

          const SizedBox(height: 16),

          Text(
            user.fullName,
            style: theme.textTheme.headlineSmall
                ?.copyWith(fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 4),
          Text(
            '${user.role} · ${user.company}',
            style: theme.textTheme.bodyLarge?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),

          const SizedBox(height: 12),

          // Bottoni azione
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              OutlinedButton.icon(
                icon: const Icon(Icons.qr_code, size: 18),
                label: const Text('Mostra QR'),
                onPressed: () => _showQrCode(context, user),
                style: OutlinedButton.styleFrom(
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(20)),
                ),
              ),
              const SizedBox(width: 12),
              OutlinedButton.icon(
                icon: const Icon(Icons.edit_outlined, size: 18),
                label: const Text('Modifica'),
                onPressed: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => EditProfileScreen(user: user),
                    ),
                  );
                },
                style: OutlinedButton.styleFrom(
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(20)),
                ),
              ),
            ],
          ),

          const SizedBox(height: 24),

          _SectionHeader(title: 'Contatti'),
          _InfoCard(
              icon: Icons.email_outlined, label: 'Email', value: user.email),
          if (user.phone != null && user.phone!.isNotEmpty)
            _InfoCard(
                icon: Icons.phone_outlined,
                label: 'Telefono',
                value: user.phone!),

          if (user.linkedin != null && user.linkedin!.isNotEmpty) ...[
            _SectionHeader(title: 'Social'),
            _InfoCard(
                icon: Icons.link_outlined,
                label: 'LinkedIn',
                value: user.linkedin!),
          ],
          if (user.github != null && user.github!.isNotEmpty)
            _InfoCard(
                icon: Icons.code_outlined,
                label: 'GitHub',
                value: user.github!),
          if (user.twitter != null && user.twitter!.isNotEmpty)
            _InfoCard(
                icon: Icons.alternate_email,
                label: 'Twitter / X',
                value: user.twitter!),

          if (user.bio != null && user.bio!.isNotEmpty) ...[
            _SectionHeader(title: 'Bio'),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: theme.colorScheme.surface,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: theme.colorScheme.outlineVariant),
              ),
              child: Text(user.bio!,
                  style: const TextStyle(fontSize: 14, height: 1.5)),
            ),
          ],

          const SizedBox(height: 8),
          _SectionHeader(title: 'Informazioni app'),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              children: [
                Icon(Icons.bluetooth,
                    color: theme.colorScheme.primary, size: 18),
                const SizedBox(width: 8),
                Text('BLE ID: ',
                    style: TextStyle(
                        color: theme.colorScheme.onSurfaceVariant,
                        fontSize: 12)),
                Expanded(
                  child: Text(
                    user.bleId,
                    style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 12,
                        fontWeight: FontWeight.bold),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(height: 32),

          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              icon: const Icon(Icons.logout),
              label: const Text('Esci'),
              onPressed: () async {
                await BleService.shared.stopAll();
                await AuthService().logout();
              },
              style: OutlinedButton.styleFrom(
                foregroundColor: theme.colorScheme.error,
                side: BorderSide(color: theme.colorScheme.error),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12)),
              ),
            ),
          ),
          const SizedBox(height: 20),
        ],
      ),
    );
  }

  Widget _initial(UserModel user, ThemeData theme) {
    return Center(
      child: Text(
        user.firstName[0].toUpperCase(),
        style: TextStyle(
          fontSize: 42,
          fontWeight: FontWeight.bold,
          color: theme.colorScheme.primary,
        ),
      ),
    );
  }

  // QR risolto — isScrollControlled + SingleChildScrollView
  void _showQrCode(BuildContext context, UserModel user) {
    final theme = Theme.of(context);
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
              style: theme.textTheme.titleLarge
                  ?.copyWith(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Text(
              'Mostralo a qualcuno per scambiare il biglietto',
              style:
                  TextStyle(color: theme.colorScheme.onSurfaceVariant),
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
                data: 'proximeet://user/${user.uid}',
                version: QrVersions.auto,
                size: 200,
              ),
            ),
            const SizedBox(height: 16),
            Text(user.fullName,
                style: const TextStyle(fontWeight: FontWeight.bold)),
            Text(
              '${user.role} · ${user.company}',
              style:
                  TextStyle(color: theme.colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: 32),
          ],
        ),
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final String title;
  const _SectionHeader({required this.title});

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
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
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
              Text(
                value,
                style: const TextStyle(fontWeight: FontWeight.w500),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
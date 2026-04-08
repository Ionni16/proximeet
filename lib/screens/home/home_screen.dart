import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'dart:math' show cos, sin;
import 'dart:async';
import 'package:qr_flutter/qr_flutter.dart';

import '../../models/user_model.dart';
import '../../models/nearby_user.dart';
import '../../models/connection_model.dart';
import '../../services/auth_service.dart';
import '../../services/event_session_service.dart';
import '../../services/nearby_detection_service.dart';
import '../../services/firestore_service.dart';
import '../../services/storage_service.dart';
import '../profile/edit_profile_screen.dart';
import 'requests_screen.dart';

/// Schermata principale durante un evento.
/// Riceve [eventId], [eventName] e [currentUser] dal navigator.
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

  /// Lifecycle: se l'app va in background/detached, tenta cleanup.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.detached) {
      EventSessionService.shared.leaveEvent();
    }
  }

  Future<void> _leaveEvent() async {
    await EventSessionService.shared.leaveEvent();
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
            const Text('ProxiMeet',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
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
          // Richieste in arrivo
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

          // Esci dall'evento
          IconButton(
            icon: const Icon(Icons.exit_to_app),
            tooltip: 'Esci dall\'evento',
            onPressed: _leaveEvent,
          ),
        ],
      ),
      body: IndexedStack(
        index: _selectedIndex,
        children: [
          _RadarTab(currentUser: widget.currentUser),
          const _WalletTab(),
          _ProfileTab(currentUser: widget.currentUser),
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
  final UserModel currentUser;
  const _RadarTab({required this.currentUser});

  @override
  State<_RadarTab> createState() => _RadarTabState();
}

class _RadarTabState extends State<_RadarTab>
    with SingleTickerProviderStateMixin {
  late AnimationController _radarController;
  late Animation<double> _radarAnimation;
  List<NearbyUser> _nearbyUsers = [];
  StreamSubscription? _nearbySub;

  @override
  void initState() {
    super.initState();

    _radarController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 3),
    )..repeat();

    _radarAnimation = Tween<double>(
      begin: 0,
      end: 2 * 3.14159,
    ).animate(_radarController);

    // Ascolta NearbyDetectionService — la UNICA sorgente di verità
    _nearbySub =
        NearbyDetectionService.shared.nearbyStream.listen((users) {
      if (mounted) setState(() => _nearbyUsers = users);
    });
  }

  @override
  void dispose() {
    _radarController.dispose();
    _nearbySub?.cancel();
    super.dispose();
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
                      // Cerchi radar
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

                      // Croce
                      Container(
                          width: size,
                          height: 1,
                          color:
                              theme.colorScheme.primary.withOpacity(0.1)),
                      Container(
                          width: 1,
                          height: size,
                          color:
                              theme.colorScheme.primary.withOpacity(0.1)),

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

                      // Utenti nearby — posizionati in base a RSSI
                      ..._nearbyUsers.asMap().entries.map((entry) {
                        final i = entry.key;
                        final nearby = entry.value;
                        final angle = (i * 2.4) % (2 * 3.14159);
                        final radius =
                            nearby.radarRadius * maxRadius * 0.85;
                        final x = radius * cos(angle);
                        final y = radius * sin(angle);

                        return Positioned(
                          left: maxRadius + x - 24,
                          top: maxRadius + y - 24,
                          child: GestureDetector(
                            onTap: () => _showUserCard(context, nearby),
                            child: _UserDot(nearby: nearby),
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
                            widget.currentUser.firstName[0].toUpperCase(),
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

        // Lista orizzontale utenti rilevati
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
                        _UserDot(nearby: nearby),
                        const SizedBox(height: 6),
                        Text(
                          nearby.firstName,
                          style: const TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                        Text(
                          nearby.distanceLabel,
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
            child: Column(
              children: [
                Icon(Icons.sensors,
                    size: 32,
                    color: theme.colorScheme.onSurfaceVariant),
                const SizedBox(height: 8),
                Text(
                  'Scansione in corso...',
                  style: TextStyle(
                    color: theme.colorScheme.onSurfaceVariant,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'Le persone vicine appariranno qui',
                  style: TextStyle(
                    fontSize: 12,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),

        const SizedBox(height: 16),
      ],
    );
  }

  void _showUserCard(BuildContext context, NearbyUser nearby) {
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
              child: nearby.avatarURL.isNotEmpty
                  ? ClipOval(
                      child: Image.network(nearby.avatarURL,
                          fit: BoxFit.cover,
                          errorBuilder: (_, __, ___) =>
                              _initial(nearby, theme)))
                  : _initial(nearby, theme),
            ),
            const SizedBox(height: 12),

            Text(
              nearby.displayName,
              style: theme.textTheme.titleLarge
                  ?.copyWith(fontWeight: FontWeight.bold),
            ),
            Text(
              '${nearby.role} · ${nearby.company}',
              style:
                  TextStyle(color: theme.colorScheme.onSurfaceVariant),
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
                nearby.distanceLabel,
                style: TextStyle(
                  color: theme.colorScheme.primary,
                  fontWeight: FontWeight.w600,
                  fontSize: 12,
                ),
              ),
            ),
            const SizedBox(height: 24),

            // Scambia biglietto
            SizedBox(
              width: double.infinity,
              height: 52,
              child: _SendRequestButton(
                targetUid: nearby.uid,
                targetName: nearby.firstName,
              ),
            ),
            const SizedBox(height: 12),
          ],
        ),
      ),
    );
  }

  Widget _initial(NearbyUser nearby, ThemeData theme) {
    return Center(
      child: Text(
        nearby.firstName[0].toUpperCase(),
        style: TextStyle(
          fontSize: 30,
          fontWeight: FontWeight.bold,
          color: theme.colorScheme.primary,
        ),
      ),
    );
  }
}

/// Bottone "Scambia biglietto" con stato e gestione errori.
class _SendRequestButton extends StatefulWidget {
  final String targetUid;
  final String targetName;
  const _SendRequestButton(
      {required this.targetUid, required this.targetName});

  @override
  State<_SendRequestButton> createState() => _SendRequestButtonState();
}

class _SendRequestButtonState extends State<_SendRequestButton> {
  bool _loading = false;

  Future<void> _send() async {
    setState(() => _loading = true);
    try {
      await FirestoreService.shared
          .sendConnectionRequest(widget.targetUid);
      if (mounted) {
        Navigator.pop(context);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content:
                Text('Richiesta inviata a ${widget.targetName}!'),
            backgroundColor: Theme.of(context).colorScheme.primary,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(e.toString().replaceAll('Exception: ', '')),
            backgroundColor: Colors.red,
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
                  strokeWidth: 2, color: Colors.white))
          : const Icon(Icons.contactless),
      label: Text(_loading ? 'Invio...' : 'Scambia biglietto'),
      onPressed: _loading ? null : _send,
      style: FilledButton.styleFrom(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
        ),
      ),
    );
  }
}

// ── Radar Dot ──────────────────────────────────────────────
class _UserDot extends StatelessWidget {
  final NearbyUser nearby;
  const _UserDot({required this.nearby});

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
      child: nearby.avatarURL.isNotEmpty
          ? ClipOval(
              child: Image.network(
              nearby.avatarURL,
              fit: BoxFit.cover,
              errorBuilder: (_, __, ___) => _letter(theme),
            ))
          : _letter(theme),
    );
  }

  Widget _letter(ThemeData theme) {
    return Center(
      child: Text(
        nearby.firstName[0].toUpperCase(),
        style: TextStyle(
          fontSize: 18,
          fontWeight: FontWeight.bold,
          color: theme.colorScheme.secondary,
        ),
      ),
    );
  }
}

// ── Radar sweep painter ────────────────────────────────────
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
        colors: [color.withOpacity(0), color.withOpacity(0.3)],
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

    final linePaint = Paint()
      ..color = color.withOpacity(0.6)
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke;

    canvas.drawLine(
      center,
      Offset(center.dx + radius * cos(angle),
          center.dy + radius * sin(angle)),
      linePaint,
    );
  }

  @override
  bool shouldRepaint(_RadarSweepPainter old) => old.angle != angle;
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
                Icon(Icons.contacts_outlined,
                    size: 64, color: theme.colorScheme.onSurfaceVariant),
                const SizedBox(height: 16),
                Text('Nessun contatto ancora',
                    style: theme.textTheme.titleMedium),
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
          itemBuilder: (context, i) => _ContactCard(contact: contacts[i]),
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
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(contact.fullName,
                      style: const TextStyle(
                          fontWeight: FontWeight.bold, fontSize: 15)),
                  const SizedBox(height: 2),
                  Text(
                    '${contact.role} · ${contact.company}',
                    style: TextStyle(
                      fontSize: 13,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  if (contact.eventName.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(
                      contact.eventName,
                      style: TextStyle(
                        fontSize: 11,
                        color: theme.colorScheme.primary,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            Icon(Icons.chevron_right,
                color: theme.colorScheme.onSurfaceVariant),
          ],
        ),
      ),
    );
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
              Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: theme.colorScheme.outlineVariant,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(height: 24),
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
              Text(contact.fullName,
                  style: theme.textTheme.headlineSmall
                      ?.copyWith(fontWeight: FontWeight.bold)),
              Text('${contact.role} · ${contact.company}',
                  style: TextStyle(
                      color: theme.colorScheme.onSurfaceVariant)),
              const SizedBox(height: 24),
              if (contact.email.isNotEmpty)
                _DetailRow(
                    icon: Icons.email_outlined,
                    label: 'Email',
                    value: contact.email),
              if (contact.phone.isNotEmpty)
                _DetailRow(
                    icon: Icons.phone_outlined,
                    label: 'Telefono',
                    value: contact.phone),
              if (contact.linkedin.isNotEmpty)
                _DetailRow(
                    icon: Icons.link_outlined,
                    label: 'LinkedIn',
                    value: contact.linkedin),
              const SizedBox(height: 24),
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
  const _DetailRow(
      {required this.icon, required this.label, required this.value});

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
              Text(label,
                  style: TextStyle(
                      fontSize: 11,
                      color: theme.colorScheme.onSurfaceVariant)),
              Text(value,
                  style: const TextStyle(fontWeight: FontWeight.w500)),
            ],
          ),
        ],
      ),
    );
  }
}

// ── TAB PROFILO ────────────────────────────────────────────
class _ProfileTab extends StatelessWidget {
  final UserModel currentUser;
  const _ProfileTab({required this.currentUser});

  @override
  Widget build(BuildContext context) {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return const Center(child: CircularProgressIndicator());

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
        if (data == null) {
          return const Center(child: Text('Profilo non trovato'));
        }
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

          // Avatar
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
                        ? const Center(
                            child: CircularProgressIndicator())
                        : user.avatarURL.isNotEmpty
                            ? Image.network(user.avatarURL,
                                fit: BoxFit.cover,
                                errorBuilder: (_, __, ___) =>
                                    _initial(user, theme))
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
          Text(user.fullName,
              style: theme.textTheme.headlineSmall
                  ?.copyWith(fontWeight: FontWeight.bold)),
          const SizedBox(height: 4),
          Text('${user.role} · ${user.company}',
              style: theme.textTheme.bodyLarge?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant)),

          const SizedBox(height: 12),

          // QR + Modifica
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              OutlinedButton.icon(
                icon: const Icon(Icons.qr_code, size: 18),
                label: const Text('Mostra QR'),
                onPressed: () => _showQrCode(context, user),
                style: OutlinedButton.styleFrom(
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(20))),
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
                        borderRadius: BorderRadius.circular(20))),
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
                border: Border.all(
                    color: theme.colorScheme.outlineVariant),
              ),
              child: Text(user.bio!,
                  style: const TextStyle(fontSize: 14, height: 1.5)),
            ),
          ],

          // Session info
          const SizedBox(height: 8),
          _SectionHeader(title: 'Sessione evento'),
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
                Text('BLE Session: ',
                    style: TextStyle(
                        color: theme.colorScheme.onSurfaceVariant,
                        fontSize: 12)),
                Expanded(
                  child: Text(
                    EventSessionService.shared.sessionBleId ?? 'N/A',
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

          // Esci dall'evento
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              icon: const Icon(Icons.exit_to_app),
              label: const Text('Esci dall\'evento'),
              onPressed: () async {
                await EventSessionService.shared.leaveEvent();
                if (context.mounted) Navigator.pop(context);
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

  void _showQrCode(BuildContext context, UserModel user) {
    final theme = Theme.of(context);
    final eventId = EventSessionService.shared.currentEventId ?? '';

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
            Text('Il tuo QR ProxiMeet',
                style: theme.textTheme.titleLarge
                    ?.copyWith(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            Text(
              'Mostralo a qualcuno per scambiare il biglietto',
              style: TextStyle(
                  color: theme.colorScheme.onSurfaceVariant),
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
                // QR contiene uid + eventId per il fallback
                data: 'proximeet://user/${user.uid}?event=$eventId',
                version: QrVersions.auto,
                size: 200,
              ),
            ),
            const SizedBox(height: 16),
            Text(user.fullName,
                style: const TextStyle(fontWeight: FontWeight.bold)),
            Text('${user.role} · ${user.company}',
                style: TextStyle(
                    color: theme.colorScheme.onSurfaceVariant)),
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
              Text(label,
                  style: TextStyle(
                      fontSize: 11,
                      color: theme.colorScheme.onSurfaceVariant)),
              Text(value,
                  style: const TextStyle(fontWeight: FontWeight.w500)),
            ],
          ),
        ],
      ),
    );
  }
}

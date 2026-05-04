import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../models/nearby_user.dart';
import '../services/firestore_service.dart';
import 'user_avatar.dart';

/// Bottom sheet con il profilo di un utente rilevato via BLE.
class NearbyUserCard {
  NearbyUserCard._();

  static void show(BuildContext context, NearbyUser nearby) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => _NearbyUserSheet(nearby: nearby),
    );
  }
}

class _NearbyUserSheet extends StatelessWidget {
  final NearbyUser nearby;
  const _NearbyUserSheet({required this.nearby});

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      initialChildSize: 0.58,
      minChildSize: 0.35,
      maxChildSize: 0.88,
      expand: false,
      builder: (_, controller) => Container(
        decoration: const BoxDecoration(
          color: Color(0xFF0D1B30),
          borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
          border: Border(
            top: BorderSide(color: Color(0xFF1A2D47), width: 1),
            left: BorderSide(color: Color(0xFF1A2D47), width: 1),
            right: BorderSide(color: Color(0xFF1A2D47), width: 1),
          ),
        ),
        child: SingleChildScrollView(
          controller: controller,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Maniglia per trascinare il bottom sheet
              Padding(
                padding: const EdgeInsets.only(top: 12, bottom: 0),
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: const Color(0xFF2A3F5F),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),

              // Header con avatar e informazioni principali
              Container(
                width: double.infinity,
                padding: const EdgeInsets.fromLTRB(24, 20, 24, 24),
                child: Column(
                  children: [
                    // Avatar con alone luminoso attorno
                    Stack(
                      alignment: Alignment.center,
                      children: [
                        // Cerchio luminoso che fa da cornice all'avatar
                        Container(
                          width: 100,
                          height: 100,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            boxShadow: [
                              BoxShadow(
                                color: const Color(0xFF1A56DB).withOpacity(0.25),
                                blurRadius: 30,
                                spreadRadius: 5,
                              ),
                            ],
                          ),
                        ),
                        Container(
                          padding: const EdgeInsets.all(3),
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            gradient: LinearGradient(
                              colors: [
                                const Color(0xFF1A56DB),
                                const Color(0xFF4D8EF7),
                              ],
                              begin: Alignment.topLeft,
                              end: Alignment.bottomRight,
                            ),
                          ),
                          child: Container(
                            padding: const EdgeInsets.all(2),
                            decoration: const BoxDecoration(
                              shape: BoxShape.circle,
                              color: Color(0xFF0D1B30),
                            ),
                            child: UserAvatar(
                              imageUrl: nearby.avatarURL,
                              name: nearby.displayName,
                              size: 80,
                            ),
                          ),
                        ),
                      ],
                    ),

                    const SizedBox(height: 14),

                    Text(
                      nearby.displayName,
                      style: const TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.w700,
                        letterSpacing: -0.4,
                        color: Color(0xFFE8F0FE),
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${nearby.role} · ${nearby.company}',
                      style: const TextStyle(
                        color: Color(0xFF8BA3C7),
                        fontSize: 14,
                      ),
                      textAlign: TextAlign.center,
                    ),

                    const SizedBox(height: 14),

                    // Distanza, forza segnale e ultimo rilevamento
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      alignment: WrapAlignment.center,
                      children: [
                        _DistanceChip(nearby: nearby),
                        _InfoChip(
                          icon: Icons.signal_cellular_alt,
                          label: '${nearby.rssi} dBm',
                        ),
                        _InfoChip(
                          icon: Icons.access_time,
                          label: nearby.lastSeenLabel,
                        ),
                      ],
                    ),
                  ],
                ),
              ),

              // Linea separatrice
              const Divider(height: 1, color: Color(0xFF1A2D47)),

              // Contenuto principale del bottom sheet
              Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Bio dell'utente
                    if (nearby.bio.isNotEmpty) ...[
                      const _SectionLabel('BIO'),
                      const SizedBox(height: 8),
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          color: const Color(0xFF080F1F),
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(color: const Color(0xFF1A2D47)),
                        ),
                        child: Text(
                          nearby.bio,
                          style: const TextStyle(
                            fontSize: 14,
                            height: 1.6,
                            color: Color(0xFF8BA3C7),
                          ),
                        ),
                      ),
                      const SizedBox(height: 20),
                    ],

                    // Link e contatti dell'utente
                    if (nearby.hasSocials) ...[
                      const _SectionLabel('CONTATTI'),
                      const SizedBox(height: 8),
                      if (nearby.email.isNotEmpty)
                        _ContactRow(
                          icon: Icons.alternate_email,
                          label: 'Email',
                          value: nearby.email,
                        ),
                      if (nearby.phone.isNotEmpty)
                        _ContactRow(
                          icon: Icons.phone_outlined,
                          label: 'Telefono',
                          value: nearby.phone,
                        ),
                      if (nearby.linkedin.isNotEmpty)
                        _ContactRow(
                          icon: Icons.link_outlined,
                          label: 'LinkedIn',
                          value: nearby.linkedin,
                        ),
                      const SizedBox(height: 20),
                    ],

                    // Bottone per scambiare il biglietto
                    _SendRequestButton(
                      targetUid: nearby.uid,
                      targetName: nearby.firstName,
                    ),

                    const SizedBox(height: 8),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ── Chip con la distanza colorata in base al segnale ─────────

class _DistanceChip extends StatelessWidget {
  final NearbyUser nearby;
  const _DistanceChip({required this.nearby});

  @override
  Widget build(BuildContext context) {
    Color chipColor;
    Color textColor;

    if (nearby.rssi >= -55) {
      chipColor = const Color(0xFF0D2D18);
      textColor = const Color(0xFF4CAF50);
    } else if (nearby.rssi >= -68) {
      chipColor = const Color(0xFF1A2D10);
      textColor = const Color(0xFF8BC34A);
    } else if (nearby.rssi >= -80) {
      chipColor = const Color(0xFF1A2800);
      textColor = const Color(0xFFFFC107);
    } else {
      chipColor = const Color(0xFF1A1A2D);
      textColor = const Color(0xFF8BA3C7);
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: chipColor,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: textColor.withOpacity(0.3)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.sensors, size: 13, color: textColor),
          const SizedBox(width: 5),
          Text(
            nearby.distanceLabel,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: textColor,
            ),
          ),
        ],
      ),
    );
  }
}

class _InfoChip extends StatelessWidget {
  final IconData icon;
  final String label;

  const _InfoChip({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: const Color(0xFF101E35),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: const Color(0xFF1A2D47)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: const Color(0xFF8BA3C7)),
          const SizedBox(width: 5),
          Text(
            label,
            style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w500,
              color: Color(0xFF8BA3C7),
            ),
          ),
        ],
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  final String text;
  const _SectionLabel(this.text);

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: const TextStyle(
        fontSize: 11,
        fontWeight: FontWeight.w700,
        letterSpacing: 1.5,
        color: Color(0xFF4D8EF7),
      ),
    );
  }
}

class _ContactRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;

  const _ContactRow({
    required this.icon,
    required this.label,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
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
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: const Color(0xFF080F1F),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: const Color(0xFF1A2D47)),
          ),
          child: Row(
            children: [
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  color: const Color(0xFF1A3560),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(icon, color: const Color(0xFF4D8EF7), size: 17),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      label,
                      style: const TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 0.5,
                        color: Color(0xFF4A6080),
                      ),
                    ),
                    const SizedBox(height: 1),
                    Text(
                      value,
                      style: const TextStyle(
                        fontSize: 13,
                        color: Color(0xFFE8F0FE),
                        fontWeight: FontWeight.w500,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              const Icon(Icons.copy_outlined,
                  size: 14, color: Color(0xFF4A6080)),
            ],
          ),
        ),
      ),
    );
  }
}

/// Bottone per mandare la richiesta di scambio biglietto.
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
            backgroundColor: const Color(0xFF1A3560),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(e.toString().replaceAll('Exception: ', '')),
            backgroundColor: const Color(0xFF4A1010),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: _loading ? null : _send,
      child: Container(
        width: double.infinity,
        height: 54,
        decoration: BoxDecoration(
          gradient: _loading
              ? null
              : const LinearGradient(
                  colors: [Color(0xFF1A56DB), Color(0xFF4D8EF7)],
                ),
          color: _loading ? const Color(0xFF1A2D47) : null,
          borderRadius: BorderRadius.circular(16),
          boxShadow: _loading
              ? null
              : [
                  BoxShadow(
                    color: const Color(0xFF1A56DB).withOpacity(0.4),
                    blurRadius: 20,
                    offset: const Offset(0, 6),
                  ),
                ],
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (_loading)
              const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: Color(0xFF4D8EF7),
                ),
              )
            else
              const Icon(Icons.contactless_outlined,
                  color: Colors.white, size: 20),
            const SizedBox(width: 10),
            Text(
              _loading ? 'Invio in corso...' : 'Scambia biglietto',
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: _loading ? const Color(0xFF8BA3C7) : Colors.white,
                letterSpacing: 0.2,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

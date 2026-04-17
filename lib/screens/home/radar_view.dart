import 'dart:math' show cos, sin, pi, atan2, sqrt;
import 'package:flutter/material.dart';

import '../../models/user_model.dart';
import '../../models/nearby_user.dart';
import '../../widgets/user_avatar.dart';

/// Vista radar stile navigazione/aviazione.
///
/// Sweep rotante con scia luminosa, dot che si accendono
/// al passaggio della linea e sfumano gradualmente.
class RadarView extends StatefulWidget {
  final UserModel currentUser;
  final List<NearbyUser> nearbyUsers;
  final ValueChanged<NearbyUser> onUserTap;

  const RadarView({
    super.key,
    required this.currentUser,
    required this.nearbyUsers,
    required this.onUserTap,
  });

  @override
  State<RadarView> createState() => _RadarViewState();
}

class _RadarViewState extends State<RadarView>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2800),
    )..repeat();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Verde radar classico
    final radarColor = HSLColor.fromAHSL(1, 150, 0.85, 0.45).toColor();
    final radarColorDim = radarColor.withOpacity(0.12);
    final isDark = theme.brightness == Brightness.dark;

    return Column(
      children: [
        // ── Radar ──
        Expanded(
          child: Center(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final maxDim = constraints.maxWidth < constraints.maxHeight
                    ? constraints.maxWidth
                    : constraints.maxHeight;
                final size = maxDim * 0.88;
                final center = size / 2;

                return SizedBox(
                  width: size,
                  height: size,
                  child: AnimatedBuilder(
                    animation: _ctrl,
                    builder: (context, _) {
                      final sweepAngle = _ctrl.value * 2 * pi;

                      return Stack(
                        alignment: Alignment.center,
                        children: [
                          // ── Background + griglia + sweep ──
                          CustomPaint(
                            size: Size(size, size),
                            painter: _RadarPainter(
                              sweepAngle: sweepAngle,
                              radarColor: radarColor,
                              ringColor: radarColorDim,
                              isDark: isDark,
                              userPositions: _computePositions(
                                widget.nearbyUsers,
                                center,
                              ),
                            ),
                          ),

                          // ── Dot utenti ──
                          ...widget.nearbyUsers.asMap().entries.map((entry) {
                            final i = entry.key;
                            final nearby = entry.value;
                            final pos = _dotPosition(i, nearby, center);
                            final dotAngle = atan2(
                              pos.dy - center,
                              pos.dx - center,
                            );

                            // Calcola opacità: piena quando il sweep è appena passato,
                            // sfuma nel tempo fino al prossimo passaggio
                            final angleDiff = _normalizeAngle(
                              sweepAngle - dotAngle,
                            );
                            // angleDiff va da 0 (appena passato) a 2π (sta per passare)
                            final opacity = (1.0 - (angleDiff / (2 * pi)))
                                .clamp(0.15, 1.0);

                            return Positioned(
                              left: pos.dx - 22,
                              top: pos.dy - 22,
                              child: GestureDetector(
                                onTap: () => widget.onUserTap(nearby),
                                child: Opacity(
                                  opacity: opacity,
                                  child: _RadarBlip(
                                    nearby: nearby,
                                    radarColor: radarColor,
                                    intensity: opacity,
                                  ),
                                ),
                              ),
                            );
                          }),

                          // ── Avatar centrale ──
                          Container(
                            width: 56,
                            height: 56,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: isDark
                                  ? Colors.black87
                                  : Colors.white,
                              border: Border.all(
                                color: radarColor,
                                width: 2,
                              ),
                              boxShadow: [
                                BoxShadow(
                                  color: radarColor.withOpacity(0.4),
                                  blurRadius: 12,
                                  spreadRadius: 2,
                                ),
                              ],
                            ),
                            child: Center(
                              child: Text(
                                widget.currentUser.firstName[0].toUpperCase(),
                                style: TextStyle(
                                  fontSize: 22,
                                  fontWeight: FontWeight.bold,
                                  color: radarColor,
                                ),
                              ),
                            ),
                          ),
                        ],
                      );
                    },
                  ),
                );
              },
            ),
          ),
        ),

        // ── Strip orizzontale dei rilevati ──
        if (widget.nearbyUsers.isNotEmpty)
          Container(
            height: 105,
            padding: const EdgeInsets.only(left: 16, bottom: 8),
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: widget.nearbyUsers.length,
              separatorBuilder: (_, __) => const SizedBox(width: 10),
              itemBuilder: (context, i) {
                final nearby = widget.nearbyUsers[i];
                return GestureDetector(
                  onTap: () => widget.onUserTap(nearby),
                  child: Container(
                    width: 84,
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        UserAvatar(
                          imageUrl: nearby.avatarURL,
                          name: nearby.displayName,
                          size: 38,
                        ),
                        const SizedBox(height: 4),
                        Text(
                          nearby.firstName,
                          style: const TextStyle(
                            fontSize: 11,
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
          ),
      ],
    );
  }

  /// Posizione di un dot sul radar basata su RSSI e golden angle.
  Offset _dotPosition(int index, NearbyUser nearby, double center) {
    final angle = index * 2.399963; // golden angle
    final radius = nearby.radarRadius * center * 0.82;
    return Offset(
      center + radius * cos(angle),
      center + radius * sin(angle),
    );
  }

  List<Offset> _computePositions(List<NearbyUser> users, double center) {
    return users.asMap().entries.map((e) {
      return _dotPosition(e.key, e.value, center);
    }).toList();
  }

  double _normalizeAngle(double angle) {
    angle = angle % (2 * pi);
    if (angle < 0) angle += 2 * pi;
    return angle;
  }
}

// ═══════════════════════════════════════════════════════════
// RADAR PAINTER — cerchi, croce, sweep con scia
// ═══════════════════════════════════════════════════════════

class _RadarPainter extends CustomPainter {
  final double sweepAngle;
  final Color radarColor;
  final Color ringColor;
  final bool isDark;
  final List<Offset> userPositions;

  _RadarPainter({
    required this.sweepAngle,
    required this.radarColor,
    required this.ringColor,
    required this.isDark,
    required this.userPositions,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final maxR = size.width / 2;

    // ── Sfondo circolare scuro ──
    canvas.drawCircle(
      center,
      maxR,
      Paint()..color = (isDark ? const Color(0xFF0A1A14) : const Color(0xFF0D2818)).withOpacity(0.95),
    );

    // ── Cerchi concentrici ──
    final ringPaint = Paint()
      ..color = ringColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.5;

    for (final frac in [0.25, 0.50, 0.75, 1.0]) {
      canvas.drawCircle(center, maxR * frac, ringPaint);
    }

    // ── Croce ──
    final crossPaint = Paint()
      ..color = radarColor.withOpacity(0.08)
      ..strokeWidth = 0.5;

    canvas.drawLine(
      Offset(center.dx - maxR, center.dy),
      Offset(center.dx + maxR, center.dy),
      crossPaint,
    );
    canvas.drawLine(
      Offset(center.dx, center.dy - maxR),
      Offset(center.dx, center.dy + maxR),
      crossPaint,
    );

    // ── Diagonali ──
    final diagPaint = Paint()
      ..color = radarColor.withOpacity(0.04)
      ..strokeWidth = 0.5;
    final d = maxR * 0.707; // cos(45°)
    canvas.drawLine(
      Offset(center.dx - d, center.dy - d),
      Offset(center.dx + d, center.dy + d),
      diagPaint,
    );
    canvas.drawLine(
      Offset(center.dx + d, center.dy - d),
      Offset(center.dx - d, center.dy + d),
      diagPaint,
    );

    // ── Sweep arc (scia del radar) ──
    // Disegniamo un arco conico con gradiente da trasparente → verde
    const sweepWidth = 1.1; // radianti (~63°)
    final sweepRect = Rect.fromCircle(center: center, radius: maxR);

    final sweepPaint = Paint()
      ..shader = SweepGradient(
        startAngle: sweepAngle - sweepWidth,
        endAngle: sweepAngle,
        colors: [
          radarColor.withOpacity(0.0),
          radarColor.withOpacity(0.05),
          radarColor.withOpacity(0.15),
          radarColor.withOpacity(0.35),
        ],
        stops: const [0.0, 0.3, 0.7, 1.0],
        transform: GradientRotation(sweepAngle - sweepWidth),
      ).createShader(sweepRect)
      ..style = PaintingStyle.fill;

    canvas.drawArc(
      sweepRect,
      sweepAngle - sweepWidth,
      sweepWidth,
      true,
      sweepPaint,
    );

    // ── Linea di scansione (bordo principale del sweep) ──
    final linePaint = Paint()
      ..color = radarColor.withOpacity(0.8)
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;

    final lineEnd = Offset(
      center.dx + maxR * cos(sweepAngle),
      center.dy + maxR * sin(sweepAngle),
    );
    canvas.drawLine(center, lineEnd, linePaint);

    // ── Glow lungo la linea di scansione ──
    final glowPaint = Paint()
      ..color = radarColor.withOpacity(0.15)
      ..strokeWidth = 6
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4);

    canvas.drawLine(center, lineEnd, glowPaint);

    // ── Blip glow quando il sweep passa su un utente ──
    for (final pos in userPositions) {
      final dotAngle = atan2(pos.dy - center.dy, pos.dx - center.dx);
      var angleDiff = (sweepAngle - dotAngle) % (2 * pi);
      if (angleDiff < 0) angleDiff += 2 * pi;

      // Se il sweep è appena passato (entro 0.5 rad ≈ 30°), disegna un blip glow
      if (angleDiff < 0.5) {
        final intensity = 1.0 - (angleDiff / 0.5);
        final blipPaint = Paint()
          ..color = radarColor.withOpacity(0.6 * intensity)
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, 8 * intensity + 2);

        canvas.drawCircle(pos, 10 + 6 * intensity, blipPaint);
      }
    }

    // ── Centro glow ──
    final centerGlow = Paint()
      ..color = radarColor.withOpacity(0.2)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8);
    canvas.drawCircle(center, 12, centerGlow);

    // ── Etichette distanza ──
    final textPainter = TextPainter(
      textDirection: TextDirection.ltr,
    );
    final labels = ['25m', '50m', '75m', '100m'];
    final fracs = [0.25, 0.50, 0.75, 1.0];

    for (var i = 0; i < labels.length; i++) {
      textPainter.text = TextSpan(
        text: labels[i],
        style: TextStyle(
          color: radarColor.withOpacity(0.3),
          fontSize: 9,
          fontFamily: 'monospace',
        ),
      );
      textPainter.layout();
      textPainter.paint(
        canvas,
        Offset(
          center.dx + 4,
          center.dy - maxR * fracs[i] - 12,
        ),
      );
    }
  }

  @override
  bool shouldRepaint(_RadarPainter old) => old.sweepAngle != sweepAngle;
}

// ═══════════════════════════════════════════════════════════
// RADAR BLIP — dot utente con glow verde
// ═══════════════════════════════════════════════════════════

class _RadarBlip extends StatelessWidget {
  final NearbyUser nearby;
  final Color radarColor;
  final double intensity;

  const _RadarBlip({
    required this.nearby,
    required this.radarColor,
    required this.intensity,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 44,
      height: 44,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: radarColor.withOpacity(0.15 + 0.2 * intensity),
        border: Border.all(
          color: radarColor.withOpacity(0.5 + 0.5 * intensity),
          width: 1.5,
        ),
        boxShadow: intensity > 0.5
            ? [
                BoxShadow(
                  color: radarColor.withOpacity(0.3 * intensity),
                  blurRadius: 8,
                  spreadRadius: 1,
                ),
              ]
            : null,
      ),
      child: Center(
        child: Text(
          nearby.firstName[0].toUpperCase(),
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.bold,
            color: radarColor.withOpacity(0.6 + 0.4 * intensity),
          ),
        ),
      ),
    );
  }
}

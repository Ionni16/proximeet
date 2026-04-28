import 'dart:math' show cos, sin, pi, atan2, sqrt;
import 'package:flutter/material.dart';

import '../../models/user_model.dart';
import '../../models/nearby_user.dart';
import '../../widgets/user_avatar.dart';

/// Vista radar con tema electric blue (in linea con il logo ProxiMeet).
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
      duration: const Duration(milliseconds: 3200),
    )..repeat();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Palette electric blue — coerente col logo
    const radarColor = Color(0xFF4D8EF7);
    const radarColorDim = Color(0x1A4D8EF7);

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
                          // Background + griglia + sweep
                          CustomPaint(
                            size: Size(size, size),
                            painter: _RadarPainter(
                              sweepAngle: sweepAngle,
                              radarColor: radarColor,
                              ringColor: radarColorDim,
                              userPositions: _computePositions(
                                widget.nearbyUsers,
                                center,
                              ),
                            ),
                          ),

                          // Dot utenti
                          ...widget.nearbyUsers.asMap().entries.map((entry) {
                            final i = entry.key;
                            final nearby = entry.value;
                            final pos = _dotPosition(i, nearby, center);
                            final dotAngle = atan2(
                              pos.dy - center,
                              pos.dx - center,
                            );
                            final angleDiff = _normalizeAngle(
                              sweepAngle - dotAngle,
                            );
                            final opacity =
                                (1.0 - (angleDiff / (2 * pi))).clamp(0.15, 1.0);

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

                          // Avatar centrale
                          Container(
                            width: 60,
                            height: 60,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: const Color(0xFF050D1E),
                              border: Border.all(
                                color: radarColor,
                                width: 2,
                              ),
                              boxShadow: [
                                BoxShadow(
                                  color: radarColor.withOpacity(0.5),
                                  blurRadius: 16,
                                  spreadRadius: 2,
                                ),
                                BoxShadow(
                                  color: radarColor.withOpacity(0.15),
                                  blurRadius: 40,
                                  spreadRadius: 10,
                                ),
                              ],
                            ),
                            child: Center(
                              child: Text(
                                (widget.currentUser.firstName.trim().isNotEmpty ? widget.currentUser.firstName.trim()[0] : '?').toUpperCase(),
                                style: const TextStyle(
                                  fontSize: 22,
                                  fontWeight: FontWeight.w700,
                                  color: radarColor,
                                  letterSpacing: 0,
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

        // ── Strip orizzontale rilevati ──
        if (widget.nearbyUsers.isNotEmpty)
          Container(
            height: 96,
            padding: const EdgeInsets.only(left: 12, right: 8, bottom: 4),
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: widget.nearbyUsers.length,
              separatorBuilder: (_, __) => const SizedBox(width: 10),
              itemBuilder: (context, i) {
                final nearby = widget.nearbyUsers[i];
                return GestureDetector(
                  onTap: () => widget.onUserTap(nearby),
                  child: Container(
                    width: 82,
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: const Color(0xFF0D1B30),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(
                        color: const Color(0xFF1A2D47),
                        width: 1,
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: const Color(0xFF1A56DB).withOpacity(0.08),
                          blurRadius: 12,
                        ),
                      ],
                    ),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        UserAvatar(
                          imageUrl: nearby.avatarURL,
                          name: nearby.displayName,
                          size: 34,
                        ),
                        const SizedBox(height: 5),
                        Text(
                          nearby.firstName,
                          style: const TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            color: Color(0xFFE8F0FE),
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                        Text(
                          nearby.distanceLabel,
                          style: const TextStyle(
                            fontSize: 10,
                            color: Color(0xFF4D8EF7),
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

  Offset _dotPosition(int index, NearbyUser nearby, double center) {
    final angle = index * 2.399963;
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
// RADAR PAINTER — electric blue theme
// ═══════════════════════════════════════════════════════════

class _RadarPainter extends CustomPainter {
  final double sweepAngle;
  final Color radarColor;
  final Color ringColor;
  final List<Offset> userPositions;

  _RadarPainter({
    required this.sweepAngle,
    required this.radarColor,
    required this.ringColor,
    required this.userPositions,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final maxR = size.width / 2;

    // ── Sfondo — deep navy, coerente col tema app ──
    final bgPaint = Paint()
      ..shader = RadialGradient(
        colors: [
          const Color(0xFF0A1628),
          const Color(0xFF050D1E),
        ],
        stops: const [0.0, 1.0],
      ).createShader(Rect.fromCircle(center: center, radius: maxR));
    canvas.drawCircle(center, maxR, bgPaint);

    // ── Cerchi concentrici ──
    final ringPaint = Paint()
      ..color = radarColor.withOpacity(0.08)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.8;

    for (final frac in [0.25, 0.50, 0.75, 1.0]) {
      canvas.drawCircle(center, maxR * frac, ringPaint);
    }

    // ── Assi ──
    final axisPaint = Paint()
      ..color = radarColor.withOpacity(0.06)
      ..strokeWidth = 0.6;
    canvas.drawLine(Offset(center.dx - maxR, center.dy),
        Offset(center.dx + maxR, center.dy), axisPaint);
    canvas.drawLine(Offset(center.dx, center.dy - maxR),
        Offset(center.dx, center.dy + maxR), axisPaint);

    // ── Diagonali ──
    final diagPaint = Paint()
      ..color = radarColor.withOpacity(0.03)
      ..strokeWidth = 0.6;
    final d = maxR * 0.707;
    canvas.drawLine(Offset(center.dx - d, center.dy - d),
        Offset(center.dx + d, center.dy + d), diagPaint);
    canvas.drawLine(Offset(center.dx + d, center.dy - d),
        Offset(center.dx - d, center.dy + d), diagPaint);

    // ── Sweep arc con gradiente electric blue ──
    const sweepWidth = 1.1;
    final sweepRect = Rect.fromCircle(center: center, radius: maxR);

    final sweepPaint = Paint()
      ..shader = SweepGradient(
        startAngle: sweepAngle - sweepWidth,
        endAngle: sweepAngle,
        colors: [
          radarColor.withOpacity(0.0),
          radarColor.withOpacity(0.04),
          radarColor.withOpacity(0.12),
          radarColor.withOpacity(0.30),
        ],
        stops: const [0.0, 0.3, 0.7, 1.0],
        transform: GradientRotation(sweepAngle - sweepWidth),
      ).createShader(sweepRect)
      ..style = PaintingStyle.fill;

    canvas.drawArc(sweepRect, sweepAngle - sweepWidth, sweepWidth, true, sweepPaint);

    // ── Linea scanner ──
    final linePaint = Paint()
      ..color = radarColor.withOpacity(0.9)
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;

    final lineEnd = Offset(
      center.dx + maxR * cos(sweepAngle),
      center.dy + maxR * sin(sweepAngle),
    );
    canvas.drawLine(center, lineEnd, linePaint);

    // ── Glow linea scanner ──
    final glowPaint = Paint()
      ..color = radarColor.withOpacity(0.18)
      ..strokeWidth = 8
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 5);
    canvas.drawLine(center, lineEnd, glowPaint);

    // ── Blip glow sui rilevati ──
    for (final pos in userPositions) {
      final dotAngle = atan2(pos.dy - center.dy, pos.dx - center.dx);
      var angleDiff = (sweepAngle - dotAngle) % (2 * pi);
      if (angleDiff < 0) angleDiff += 2 * pi;

      if (angleDiff < 0.5) {
        final intensity = 1.0 - (angleDiff / 0.5);
        final blipPaint = Paint()
          ..color = radarColor.withOpacity(0.65 * intensity)
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, 10 * intensity + 2);
        canvas.drawCircle(pos, 12 + 6 * intensity, blipPaint);
      }
    }

    // ── Centro glow ──
    final centerGlow = Paint()
      ..color = radarColor.withOpacity(0.25)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 10);
    canvas.drawCircle(center, 14, centerGlow);

    // ── Etichette distanza ──
    final textPainter = TextPainter(textDirection: TextDirection.ltr);
    final labels = ['25m', '50m', '75m'];
    final fracs = [0.25, 0.50, 0.75];

    for (var i = 0; i < labels.length; i++) {
      textPainter.text = TextSpan(
        text: labels[i],
        style: TextStyle(
          color: radarColor.withOpacity(0.25),
          fontSize: 9,
          fontFamily: 'monospace',
        ),
      );
      textPainter.layout();
      textPainter.paint(
        canvas,
        Offset(center.dx + 4, center.dy - maxR * fracs[i] - 12),
      );
    }
  }

  @override
  bool shouldRepaint(_RadarPainter old) => old.sweepAngle != sweepAngle;
}

// ═══════════════════════════════════════════════════════════
// RADAR BLIP — dot utente electric blue
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
        color: radarColor.withOpacity(0.12 + 0.18 * intensity),
        border: Border.all(
          color: radarColor.withOpacity(0.4 + 0.6 * intensity),
          width: 1.5,
        ),
        boxShadow: intensity > 0.4
            ? [
                BoxShadow(
                  color: radarColor.withOpacity(0.35 * intensity),
                  blurRadius: 10,
                  spreadRadius: 1,
                ),
              ]
            : null,
      ),
      child: Center(
        child: Text(
          (nearby.firstName.trim().isNotEmpty ? nearby.firstName.trim()[0] : '?').toUpperCase(),
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w700,
            color: radarColor.withOpacity(0.6 + 0.4 * intensity),
          ),
        ),
      ),
    );
  }
}

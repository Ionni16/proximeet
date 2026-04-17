import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../services/firestore_service.dart';

/// Schermata scanner QR per scambiare biglietti tramite codice QR.
///
/// Scansiona URI nel formato: `proximeet://user/{uid}?event={eventId}`
/// e invia automaticamente una richiesta di contatto.
class QrScannerScreen extends StatefulWidget {
  const QrScannerScreen({super.key});

  @override
  State<QrScannerScreen> createState() => _QrScannerScreenState();
}

class _QrScannerScreenState extends State<QrScannerScreen> {
  final MobileScannerController _scannerCtrl = MobileScannerController(
    detectionSpeed: DetectionSpeed.normal,
    facing: CameraFacing.back,
  );

  bool _processing = false;
  bool _torchOn = false;

  @override
  void dispose() {
    _scannerCtrl.dispose();
    super.dispose();
  }

  Future<void> _onDetect(BarcodeCapture capture) async {
    if (_processing) return;

    final barcode = capture.barcodes.firstOrNull;
    if (barcode == null || barcode.rawValue == null) return;

    final raw = barcode.rawValue!;

    // Deve essere un URI ProxiMeet: proximeet://user/{uid}?event={eventId}
    if (!raw.startsWith('proximeet://user/')) {
      _showError('QR non valido — non è un codice ProxiMeet');
      return;
    }

    setState(() => _processing = true);

    try {
      final uri = Uri.parse(raw);
      final targetUid = uri.pathSegments.length >= 2
          ? uri.pathSegments[1]
          : '';

      if (targetUid.isEmpty) {
        _showError('QR non valido — UID mancante');
        return;
      }

      // Invia richiesta contatto
      await FirestoreService.instance.sendConnectionRequest(targetUid);

      if (mounted) {
        Navigator.pop(context);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text('Richiesta inviata tramite QR!'),
            backgroundColor: Theme.of(context).colorScheme.primary,
          ),
        );
      }
    } catch (e) {
      _showError(e.toString().replaceAll('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _processing = false);
    }
  }

  void _showError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: Theme.of(context).colorScheme.error,
      ),
    );
    // Reset dopo un po' per permettere un nuovo scan
    Future.delayed(const Duration(seconds: 2), () {
      if (mounted) setState(() => _processing = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: const Text('Scansiona QR'),
        centerTitle: true,
        actions: [
          // Toggle torcia
          IconButton(
            icon: Icon(
              _torchOn ? Icons.flash_on : Icons.flash_off,
              color: _torchOn ? Colors.amber : Colors.white,
            ),
            onPressed: () {
              _scannerCtrl.toggleTorch();
              setState(() => _torchOn = !_torchOn);
            },
          ),
          // Switch camera
          IconButton(
            icon: const Icon(Icons.flip_camera_ios, color: Colors.white),
            onPressed: () => _scannerCtrl.switchCamera(),
          ),
        ],
      ),
      body: Stack(
        children: [
          // ── Camera ──
          MobileScanner(
            controller: _scannerCtrl,
            onDetect: _onDetect,
          ),

          // ── Overlay con mirino ──
          _ScanOverlay(theme: theme),

          // ── Loading indicator ──
          if (_processing)
            Container(
              color: Colors.black54,
              child: const Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    CircularProgressIndicator(color: Colors.white),
                    SizedBox(height: 16),
                    Text(
                      'Invio richiesta...',
                      style: TextStyle(color: Colors.white, fontSize: 16),
                    ),
                  ],
                ),
              ),
            ),

          // ── Istruzioni in basso ──
          Positioned(
            bottom: 60,
            left: 0,
            right: 0,
            child: Column(
              children: [
                Container(
                  margin: const EdgeInsets.symmetric(horizontal: 40),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 20,
                    vertical: 12,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.black54,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: const Text(
                    'Inquadra il QR ProxiMeet di un\'altra persona '
                    'per scambiare il biglietto',
                    style: TextStyle(
                      color: Colors.white70,
                      fontSize: 13,
                    ),
                    textAlign: TextAlign.center,
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

/// Overlay con mirino quadrato e angoli arrotondati.
class _ScanOverlay extends StatelessWidget {
  final ThemeData theme;

  const _ScanOverlay({required this.theme});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final scanAreaSize = constraints.maxWidth * 0.7;
        final left = (constraints.maxWidth - scanAreaSize) / 2;
        final top = (constraints.maxHeight - scanAreaSize) / 2.5;

        return Stack(
          children: [
            // Oscura tutto tranne il mirino
            ColorFiltered(
              colorFilter: const ColorFilter.mode(
                Colors.black54,
                BlendMode.srcOut,
              ),
              child: Stack(
                children: [
                  Container(
                    decoration: const BoxDecoration(
                      color: Colors.black,
                      backgroundBlendMode: BlendMode.dstOut,
                    ),
                  ),
                  Positioned(
                    left: left,
                    top: top,
                    child: Container(
                      width: scanAreaSize,
                      height: scanAreaSize,
                      decoration: BoxDecoration(
                        color: Colors.red, // qualsiasi colore, verrà ritagliato
                        borderRadius: BorderRadius.circular(20),
                      ),
                    ),
                  ),
                ],
              ),
            ),

            // Bordo del mirino con angoli
            Positioned(
              left: left,
              top: top,
              child: Container(
                width: scanAreaSize,
                height: scanAreaSize,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                    color: Colors.white.withOpacity(0.5),
                    width: 1,
                  ),
                ),
              ),
            ),

            // Angoli luminosi
            ..._buildCorners(left, top, scanAreaSize),
          ],
        );
      },
    );
  }

  List<Widget> _buildCorners(double left, double top, double size) {
    const len = 28.0;
    const thick = 3.0;
    const color = Colors.white;
    const radius = Radius.circular(8);

    return [
      // Top-left
      Positioned(
        left: left - 1,
        top: top - 1,
        child: Container(
          width: len,
          height: thick,
          decoration: const BoxDecoration(
            color: color,
            borderRadius: BorderRadius.only(topLeft: radius),
          ),
        ),
      ),
      Positioned(
        left: left - 1,
        top: top - 1,
        child: Container(
          width: thick,
          height: len,
          decoration: const BoxDecoration(
            color: color,
            borderRadius: BorderRadius.only(topLeft: radius),
          ),
        ),
      ),
      // Top-right
      Positioned(
        left: left + size - len + 1,
        top: top - 1,
        child: Container(
          width: len,
          height: thick,
          decoration: const BoxDecoration(
            color: color,
            borderRadius: BorderRadius.only(topRight: radius),
          ),
        ),
      ),
      Positioned(
        left: left + size - thick + 1,
        top: top - 1,
        child: Container(
          width: thick,
          height: len,
          decoration: const BoxDecoration(
            color: color,
            borderRadius: BorderRadius.only(topRight: radius),
          ),
        ),
      ),
      // Bottom-left
      Positioned(
        left: left - 1,
        top: top + size - thick + 1,
        child: Container(
          width: len,
          height: thick,
          decoration: const BoxDecoration(
            color: color,
            borderRadius: BorderRadius.only(bottomLeft: radius),
          ),
        ),
      ),
      Positioned(
        left: left - 1,
        top: top + size - len + 1,
        child: Container(
          width: thick,
          height: len,
          decoration: const BoxDecoration(
            color: color,
            borderRadius: BorderRadius.only(bottomLeft: radius),
          ),
        ),
      ),
      // Bottom-right
      Positioned(
        left: left + size - len + 1,
        top: top + size - thick + 1,
        child: Container(
          width: len,
          height: thick,
          decoration: const BoxDecoration(
            color: color,
            borderRadius: BorderRadius.only(bottomRight: radius),
          ),
        ),
      ),
      Positioned(
        left: left + size - thick + 1,
        top: top + size - len + 1,
        child: Container(
          width: thick,
          height: len,
          decoration: const BoxDecoration(
            color: color,
            borderRadius: BorderRadius.only(bottomRight: radius),
          ),
        ),
      ),
    ];
  }
}

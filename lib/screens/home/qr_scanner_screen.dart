import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../services/firestore_service.dart';

/// Schermata per scansionare i QR di altri utenti.
/// Legge URI nel formato proximeet://user/{uid}?event={eventId}
/// e manda automaticamente una richiesta di contatto.
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
    // Chiude le snackbar aperte quando si esce dalla schermata
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    _scannerCtrl.dispose();
    super.dispose();
  }

  Future<void> _onDetect(BarcodeCapture capture) async {
    if (_processing) return;

    final barcode = capture.barcodes.firstOrNull;
    if (barcode == null || barcode.rawValue == null) return;

    final raw = barcode.rawValue!;

    // Blocco per evitare che più scan vengano processati in parallelo
    setState(() => _processing = true);

    // Controlla che il QR sia di ProxiMeet
    if (!raw.startsWith('proximeet://user/')) {
      _showError('QR non valido — non è un codice Swaply');
      return;
    }

    try {
      final uri = Uri.parse(raw);
      // Formato atteso: proximeet://user/{uid}?event={eventId}
      // L'host è "user" e il primo segmento del path contiene l'uid
      final targetUid = uri.pathSegments.isNotEmpty
          ? uri.pathSegments[0]
          : '';

      if (targetUid.isEmpty) {
        _showError('QR non valido — UID mancante');
        return;
      }

      final qrEventId = uri.queryParameters['event'] ?? '';

      // Con il QR saltiamo il controllo BLE: l'utente ha mostrato il codice, è vicino.
      await FirestoreService.instance.sendConnectionRequest(
        targetUid,
        fromQr: true,
        qrEventId: qrEventId,
      );

      if (mounted) {
        ScaffoldMessenger.of(context).hideCurrentSnackBar();
        Navigator.pop(context);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text('Richiesta inviata tramite QR!'),
            backgroundColor: Theme.of(context).colorScheme.primary,
            duration: const Duration(seconds: 2),
          ),
        );
      }
    } catch (e) {
      _showError(e.toString().replaceAll('Exception: ', ''));
    }
  }

  void _showError(String message) {
    if (!mounted) return;
    // Chiudiamo la snackbar precedente prima di mostrarne una nuova
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: Theme.of(context).colorScheme.error,
        duration: const Duration(seconds: 2),
      ),
    );
    // Piccola pausa prima di sbloccare la scansione successiva
    Future.delayed(const Duration(milliseconds: 2500), () {
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
          // Accende o spegne la torcia
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
          // Cambia fotocamera
          IconButton(
            icon: const Icon(Icons.flip_camera_ios, color: Colors.white),
            onPressed: () => _scannerCtrl.switchCamera(),
          ),
        ],
      ),
      body: Stack(
        children: [
          // Vista della fotocamera
          MobileScanner(
            controller: _scannerCtrl,
            onDetect: _onDetect,
          ),

          // Mirino sovrapposto alla camera
          _ScanOverlay(theme: theme),

          // Schermata di attesa mentre si invia la richiesta
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

          // Testo di istruzione in fondo allo schermo
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
                    'Inquadra il QR Swaply di un\'altra persona '
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

/// Disegna il mirino sopra la camera con angoli ben visibili.
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
            // Scurisce lo schermo lasciando trasparente solo l'area del mirino
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

            // Bordo sottile attorno al mirino
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

            // Angoli bianchi marcati del mirino
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
      // Angolo in alto a sinistra
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
      // Angolo in alto a destra
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
      // Angolo in basso a sinistra
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
      // Angolo in basso a destra
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

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

/// Schermata di diagnostica BLE — bypassa completamente la logica di ProxiMeet.
///
/// Uso:
///   In main.dart, sostituisci temporaneamente l'home con:
///     home: const BleDiagScreen(),
///   Lancia su iPhone, lascia girare 20 secondi, leggi i numeri a video.
///
/// Cosa risponde:
///   - Adapter state on/off/unauthorized → problema BT/permission
///   - Total callbacks ricevuti → scanner riceve davvero qualcosa?
///   - Device elencati → quale device vede effettivamente l'iPhone
///   - Errori startScan → eccezioni nascoste
class BleDiagScreen extends StatefulWidget {
  const BleDiagScreen({super.key});

  @override
  State<BleDiagScreen> createState() => _BleDiagScreenState();
}

class _BleDiagScreenState extends State<BleDiagScreen> {
  BluetoothAdapterState _adapterState = BluetoothAdapterState.unknown;
  StreamSubscription<BluetoothAdapterState>? _stateSub;
  StreamSubscription<List<ScanResult>>? _scanSub;

  final Map<String, ScanResult> _devices = {};
  int _totalCallbacks = 0;
  String? _lastError;
  bool _isScanning = false;
  DateTime? _scanStartedAt;

  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<void> _start() async {
    _stateSub = FlutterBluePlus.adapterState.listen((s) {
      if (mounted) setState(() => _adapterState = s);
    });

    _scanSub = FlutterBluePlus.scanResults.listen((results) {
      for (final r in results) {
        _totalCallbacks++;
        _devices[r.device.remoteId.str] = r;
      }
      if (mounted) setState(() {});
    });

    // Aspetta un attimo che l'adapterState venga risolto
    await Future.delayed(const Duration(milliseconds: 200));

    try {
      await FlutterBluePlus.startScan(
        withServices: const <Guid>[], // NIENTE filtro: vediamo TUTTO
        continuousUpdates: true,
        oneByOne: true,
      );
      if (mounted) {
        setState(() {
          _isScanning = true;
          _scanStartedAt = DateTime.now();
        });
      }
    } catch (e) {
      if (mounted) setState(() => _lastError = e.toString());
    }
  }

  @override
  void dispose() {
    _stateSub?.cancel();
    _scanSub?.cancel();
    FlutterBluePlus.stopScan();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final sorted = _devices.values.toList()
      ..sort((a, b) => b.rssi.compareTo(a.rssi));

    final isAdapterOk = _adapterState == BluetoothAdapterState.on;
    final headerColor = isAdapterOk
        ? Colors.green.shade100
        : Colors.red.shade100;

    final secondsScanning = _scanStartedAt == null
        ? 0
        : DateTime.now().difference(_scanStartedAt!).inSeconds;

    return Scaffold(
      appBar: AppBar(
        title: const Text('BLE Diagnostic'),
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
      ),
      body: Column(
        children: [
          Container(
            padding: const EdgeInsets.all(16),
            color: headerColor,
            width: double.infinity,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _row('Adapter state', '$_adapterState',
                    bold: true,
                    color: isAdapterOk ? Colors.green.shade900 : Colors.red.shade900),
                _row('Scanning', '$_isScanning'),
                _row('Total callbacks', '$_totalCallbacks'),
                _row('Unique devices', '${_devices.length}'),
                _row('Time scanning', '${secondsScanning}s'),
                if (_lastError != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      'ERROR: $_lastError',
                      style: const TextStyle(color: Colors.red, fontWeight: FontWeight.bold),
                    ),
                  ),
                if (_adapterState == BluetoothAdapterState.unauthorized)
                  const Padding(
                    padding: EdgeInsets.only(top: 8),
                    child: Text(
                      '⚠️ PERMESSO NEGATO. Impostazioni → Privacy → Bluetooth → ProxiMeet → ON',
                      style: TextStyle(color: Colors.red, fontWeight: FontWeight.bold),
                    ),
                  ),
              ],
            ),
          ),
          Expanded(
            child: sorted.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(
                        secondsScanning > 5
                            ? 'Nessun device visto dopo ${secondsScanning}s.\n\n'
                                'Se Adapter state è "on" ma callback restano 0, '
                                'è un problema di permission o di stack BLE iOS '
                                '— prova a reinstallare l\'app.'
                            : 'In attesa di scan results...',
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: Colors.grey),
                      ),
                    ),
                  )
                : ListView.builder(
                    itemCount: sorted.length,
                    itemBuilder: (ctx, i) {
                      final r = sorted[i];
                      final ad = r.advertisementData;
                      final isProxiMeet = ad.advName.startsWith('PM-') ||
                          ad.serviceUuids.any(
                              (u) => u.str.toUpperCase().contains('FAAB')) ||
                          ad.manufacturerData.containsKey(0xFFFF);

                      return ListTile(
                        tileColor: isProxiMeet ? Colors.yellow.shade200 : null,
                        title: Text(
                          ad.advName.isNotEmpty
                              ? ad.advName
                              : '(no name)',
                          style: TextStyle(
                            fontWeight: isProxiMeet
                                ? FontWeight.bold
                                : FontWeight.normal,
                          ),
                        ),
                        subtitle: Text(
                          'rssi=${r.rssi}  mac=${r.device.remoteId.str}\n'
                          'uuids=${ad.serviceUuids.map((e) => e.str).take(2).toList()}\n'
                          'mfr=${ad.manufacturerData.keys.toList()}',
                          style: const TextStyle(fontSize: 11),
                        ),
                        isThreeLine: true,
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Widget _row(String label, String value, {bool bold = false, Color? color}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          SizedBox(
            width: 140,
            child: Text(label, style: const TextStyle(color: Colors.black54)),
          ),
          Expanded(
            child: Text(
              value,
              style: TextStyle(
                fontWeight: bold ? FontWeight.bold : FontWeight.normal,
                color: color,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

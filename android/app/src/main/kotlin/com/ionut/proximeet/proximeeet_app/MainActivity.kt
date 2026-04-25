package com.ionut.proximeet.proximeeet_app

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    private var beaconPlugin: ProxiMeetBeaconPlugin? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        beaconPlugin = ProxiMeetBeaconPlugin(
            activity = this,
            messenger = flutterEngine.dartExecutor.binaryMessenger
        )
    }

    override fun onDestroy() {
        beaconPlugin?.stop()
        beaconPlugin = null
        super.onDestroy()
    }
}
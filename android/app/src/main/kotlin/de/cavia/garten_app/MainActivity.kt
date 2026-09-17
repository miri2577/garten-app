package de.cavia.garten_app

import android.content.Intent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/// Deep Links (garten://camera) vom TV-Launcher an Dart durchreichen.
/// Kaltstart: Dart holt den Link per getInitialLink. Läuft die App schon
/// (singleTop), kommt der Link über onNewIntent -> "link"-Callback.
class MainActivity : FlutterActivity() {
    private var channel: MethodChannel? = null
    private var initialLink: String? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        initialLink = intent?.dataString
        channel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "de.cavia.garten_app/deeplink",
        ).also { ch ->
            ch.setMethodCallHandler { call, result ->
                when (call.method) {
                    "getInitialLink" -> {
                        result.success(initialLink)
                        initialLink = null // nur einmal ausliefern
                    }
                    else -> result.notImplemented()
                }
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        val link = intent.dataString ?: return
        channel?.invokeMethod("link", link)
    }
}

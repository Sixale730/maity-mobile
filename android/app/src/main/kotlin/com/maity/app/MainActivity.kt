package com.maity.app

import android.content.Intent
import android.os.Build
import androidx.annotation.NonNull
import android.Manifest
import android.content.pm.PackageManager
import android.content.pm.PackageInfo
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.security.MessageDigest

class MainActivity: FlutterActivity() {
    private val CHANNEL = "com.maity.app/notifyOnKill"
    private val SIGNING_CHANNEL = "com.maity.app/signing"

    override fun configureFlutterEngine(@NonNull flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler {
            call, result ->
            if(call.method == "setNotificationOnKillService"){
                 val title = call.argument<String>("title")
                val description = call.argument<String>("description")

                val serviceIntent = Intent(this, NotificationOnKillService::class.java)

                serviceIntent.putExtra("title", title)
                serviceIntent.putExtra("description", description)

                startService(serviceIntent)
                result.success(true)
            }else{
                result.notImplemented()
            }
        }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, SIGNING_CHANNEL).setMethodCallHandler {
            call, result ->
            if (call.method == "getSigningCertificateSha1") {
                try {
                    val sha1 = getSigningCertificateSha1()
                    result.success(sha1)
                } catch (e: Exception) {
                    result.error("SIGNING_ERROR", e.message, null)
                }
            } else {
                result.notImplemented()
            }
        }
    }

    private fun getSigningCertificateSha1(): String {
        val packageInfo: PackageInfo = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            packageManager.getPackageInfo(packageName, PackageManager.GET_SIGNING_CERTIFICATES)
        } else {
            @Suppress("DEPRECATION")
            packageManager.getPackageInfo(packageName, PackageManager.GET_SIGNATURES)
        }

        val signatures = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            packageInfo.signingInfo?.apkContentsSigners
        } else {
            @Suppress("DEPRECATION")
            packageInfo.signatures
        }

        if (signatures.isNullOrEmpty()) {
            return "No signing certificates found"
        }

        val cert = signatures[0]
        val md = MessageDigest.getInstance("SHA-1")
        val digest = md.digest(cert.toByteArray())
        return digest.joinToString(":") { "%02X".format(it) }
    }
}
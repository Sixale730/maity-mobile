package com.maity.app

import android.app.Application
// Intercom disabled - causes build issues
// import io.maido.intercom.IntercomFlutterPlugin

class MyApp : Application() {
    override fun onCreate() {
        super.onCreate()
        // Intercom disabled
        // IntercomFlutterPlugin.initSdk(this, appId = BuildConfig.INTERCOM_APP_ID, androidApiKey = BuildConfig.INTERCOM_ANDROID_API_KEY)
    }
}
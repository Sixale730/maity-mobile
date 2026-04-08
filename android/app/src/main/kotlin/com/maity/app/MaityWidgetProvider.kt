package com.maity.app

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.widget.RemoteViews
import es.antonborri.home_widget.HomeWidgetPlugin

class MaityWidgetProvider : AppWidgetProvider() {

    override fun onUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray
    ) {
        for (appWidgetId in appWidgetIds) {
            updateAppWidget(context, appWidgetManager, appWidgetId)
        }
    }

    companion object {
        fun updateAppWidget(
            context: Context,
            appWidgetManager: AppWidgetManager,
            appWidgetId: Int
        ) {
            val views = RemoteViews(context.packageName, R.layout.maity_widget)

            // Read state via home_widget SharedPreferences
            val widgetData = HomeWidgetPlugin.getData(context)
            val isRecording = widgetData.getBoolean("isRecording", false)
            val isPaused = widgetData.getBoolean("isPaused", false)
            val language = widgetData.getString("language", "es") ?: "es"

            // i18n strings
            val isEn = language == "en"
            val titleIdle = if (isEn) "Quick transcription" else "Transcripcion rapida"
            val subtitleIdle = if (isEn) "Tap to start recording" else "Toca para comenzar a grabar"
            val titleRecording = if (isEn) "Recording..." else "Grabando..."
            val titlePaused = if (isEn) "Recording paused" else "Grabacion en pausa"
            val subtitleActive = if (isEn) "Tap to open" else "Toca para abrir"

            if (isRecording || isPaused) {
                views.setInt(R.id.widget_container, "setBackgroundResource", R.drawable.widget_background_recording)
                views.setTextViewText(R.id.widget_title, if (isPaused) titlePaused else titleRecording)
                views.setTextViewText(R.id.widget_subtitle, subtitleActive)
            } else {
                views.setInt(R.id.widget_container, "setBackgroundResource", R.drawable.widget_background)
                views.setTextViewText(R.id.widget_title, titleIdle)
                views.setTextViewText(R.id.widget_subtitle, subtitleIdle)
            }

            // Deep link intent
            val deepLink = if (isRecording || isPaused) "maity://widget/recording" else "maity://widget/record"
            val intent = Intent(Intent.ACTION_VIEW, Uri.parse(deepLink))
            intent.setPackage(context.packageName)
            intent.flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
            val pendingIntent = PendingIntent.getActivity(
                context, appWidgetId, intent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )
            views.setOnClickPendingIntent(R.id.widget_container, pendingIntent)

            appWidgetManager.updateAppWidget(appWidgetId, views)
        }
    }
}

package com.maity.app

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.Context
import android.content.Intent
import android.widget.RemoteViews

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

            // Read recording state from SharedPreferences
            val prefs = context.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
            val isRecording = prefs.getBoolean("flutter.isRecording", false)
            val isPaused = prefs.getBoolean("flutter.isPaused", false)

            if (isRecording || isPaused) {
                // Recording state
                views.setInt(R.id.widget_container, "setBackgroundResource", R.drawable.widget_background_recording)
                views.setTextViewText(
                    R.id.widget_title,
                    if (isPaused) "⏸ Grabación en pausa" else "🔴 Grabando..."
                )
                views.setTextViewText(R.id.widget_subtitle, "Toca para abrir")
            } else {
                // Idle state
                views.setInt(R.id.widget_container, "setBackgroundResource", R.drawable.widget_background)
                views.setTextViewText(R.id.widget_title, "Transcripción rápida")
                views.setTextViewText(R.id.widget_subtitle, "Toca para comenzar a grabar")
            }

            // Create intent to open the app
            val intent = context.packageManager.getLaunchIntentForPackage(context.packageName)
            if (intent != null) {
                intent.putExtra("action", if (isRecording) "open_recording" else "start_recording")
                intent.flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
                val pendingIntent = PendingIntent.getActivity(
                    context, appWidgetId, intent,
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
                )
                views.setOnClickPendingIntent(R.id.widget_container, pendingIntent)
            }

            appWidgetManager.updateAppWidget(appWidgetId, views)
        }
    }
}

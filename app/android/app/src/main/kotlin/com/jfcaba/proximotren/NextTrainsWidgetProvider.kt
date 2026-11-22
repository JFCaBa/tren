package com.jfcaba.proximotren

import android.app.AlarmManager
import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.content.res.ColorStateList
import android.os.Build
import android.graphics.Color
import android.view.View
import android.widget.RemoteViews
import es.antonborri.home_widget.HomeWidgetLaunchIntent
import es.antonborri.home_widget.HomeWidgetProvider
import org.json.JSONObject
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.TimeZone

/** Próximos trenes de la última estación abierta: los deja la app (lib/widget) y el tiempo real lo pone NextTrainsRtWorker. */
class NextTrainsWidgetProvider : HomeWidgetProvider() {
  private val rows = listOf(
    Row(R.id.row0, R.id.line0, R.id.dest0, R.id.plat0, R.id.time0),
    Row(R.id.row1, R.id.line1, R.id.dest1, R.id.plat1, R.id.time1),
    Row(R.id.row2, R.id.line2, R.id.dest2, R.id.plat2, R.id.time2),
    Row(R.id.row3, R.id.line3, R.id.dest3, R.id.plat3, R.id.time3),
  )

  private data class Row(val row: Int, val line: Int, val dest: Int, val plat: Int, val time: Int)

  override fun onEnabled(context: Context) {
    super.onEnabled(context)
    NextTrainsRtWorker.ensureScheduled(context)
    NextTrainsRtWorker.runNow(context)
  }

  override fun onUpdate(context: Context, appWidgetManager: AppWidgetManager, appWidgetIds: IntArray, widgetData: SharedPreferences) {
    NextTrainsRtWorker.ensureScheduled(context) // por si se perdió (actualización de la app, etc.)
    val board = try {
      widgetData.getString("next_trains", null)?.let { JSONObject(it) }
    } catch (e: Exception) {
      null
    }
    val now = System.currentTimeMillis() / 1000
    // Cuándo se descargó el tiempo real que usó la app (no cuándo escribió): sin red no tenía.
    val appRtAt = board?.takeIf { it.has("rtAt") && !it.isNull("rtAt") }?.optLong("rtAt")
    val trains = resolveTrains(snapTrains(board), appRtAt, NextTrainsRtWorker.load(context), now)
      .filter { it.dep + LEFT_AFTER > now }
    for (id in appWidgetIds) {
      val views = RemoteViews(context.packageName, R.layout.next_trains_widget)
      views.setOnClickPendingIntent(R.id.widget_root, HomeWidgetLaunchIntent.getActivity(context, MainActivity::class.java))
      val via = board?.optString("via")?.takeIf { board.has("via") && !board.isNull("via") }
      views.setTextViewText(R.id.station, listOfNotNull(board?.optString("station"), via?.let { "→ $it" }).joinToString("  "))
      views.setViewVisibility(R.id.empty, if (trains.isEmpty()) View.VISIBLE else View.GONE)
      rows.forEachIndexed { i, r ->
        val t = trains.getOrNull(i)
        if (t == null) {
          views.setViewVisibility(r.row, View.GONE)
        } else {
          fill(context, views, r, t)
        }
      }
      appWidgetManager.updateAppWidget(id, views)
    }
    // Despertarlo cuando sale el primer tren, para no dejar en pantalla trenes que ya se fueron
    // (el refresco de 15 min puede no llegar a tiempo). Alarma inexacta, sin permisos especiales.
    // Mismo corte que el filtro de arriba: cuando suena, ese tren ya no está y no se reprograma.
    trains.firstOrNull()?.let { scheduleRefresh(context, maxOf((it.dep + LEFT_AFTER) * 1000, System.currentTimeMillis() + 15_000)) }
  }

  /** Los trenes del snapshot; los de una versión anterior (sin `sched`) se ignoran. */
  private fun snapTrains(board: JSONObject?): List<SnapTrain> {
    val a = board?.optJSONArray("trains") ?: return emptyList()
    return (0 until a.length()).mapNotNull { i ->
      val t = a.optJSONObject(i) ?: return@mapNotNull null
      if (!t.has("sched") || t.isNull("sched")) return@mapNotNull null
      SnapTrain(
        line = t.optString("line"),
        color = t.optLong("color", 0xFF9E9E9E).toInt(),
        dest = t.optString("dest"),
        sched = t.optLong("sched"),
        arrSched = if (t.isNull("arrSched")) null else t.optLong("arrSched"),
        delaySec = if (t.isNull("delaySec")) null else t.optInt("delaySec"),
        canceled = t.optBoolean("canceled"),
        platform = if (t.isNull("platform")) null else t.optString("platform"),
        live = t.optBoolean("live"),
        rt = if (t.isNull("rt")) null else t.optString("rt"),
      )
    }
  }

  private fun fill(context: Context, views: RemoteViews, r: Row, t: ShownTrain) {
    val canceled = t.canceled
    val color = t.color
    views.setViewVisibility(r.row, View.VISIBLE)
    views.setFloat(r.row, "setAlpha", if (canceled) 0.5f else 1f)
    views.setTextViewText(r.line, t.line)
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
      views.setInt(r.line, "setBackgroundResource", R.drawable.widget_line_bg)
      views.setColorStateList(r.line, "setBackgroundTintList", ColorStateList.valueOf(color))
    } else {
      views.setInt(r.line, "setBackgroundColor", color)
    }
    views.setTextColor(r.line, if (luminance(color) > 0.179) Color.BLACK else Color.WHITE)
    // La llegada delante: con un destino largo, lo que se corta es el destino, no la hora.
    views.setTextViewText(r.dest, (t.arrival?.let { "llega ${hhmm(it)} · " } ?: "") + t.dest)
    val platform = t.platform
    if (platform == null || canceled) {
      views.setViewVisibility(r.plat, View.GONE)
    } else {
      views.setViewVisibility(r.plat, View.VISIBLE)
      views.setTextViewText(r.plat, platform)
      views.setInt(r.plat, "setBackgroundResource", if (t.live) R.drawable.widget_platform_live else R.drawable.widget_platform_usual)
      views.setTextColor(r.plat, if (t.live) Color.WHITE else context.getColor(R.color.widget_teal))
    }
    val late = !canceled && (t.delayMin ?: 0) >= 3
    views.setTextViewText(r.time, if (canceled) "Cancelado" else hhmm(t.dep))
    views.setTextColor(r.time, context.getColor(if (late) R.color.widget_amber else R.color.widget_text))
  }

  override fun onDisabled(context: Context) {
    super.onDisabled(context)
    context.getSystemService(AlarmManager::class.java)?.cancel(refreshIntent(context))
    NextTrainsRtWorker.cancel(context)
  }

  private fun scheduleRefresh(context: Context, atMillis: Long) {
    context.getSystemService(AlarmManager::class.java)?.set(AlarmManager.RTC, atMillis, refreshIntent(context))
  }

  private fun refreshIntent(context: Context): PendingIntent =
    PendingIntent.getBroadcast(context, 0, updateIntent(context), PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)

  companion object {
    private fun updateIntent(context: Context) = Intent(context, NextTrainsWidgetProvider::class.java).apply {
      action = AppWidgetManager.ACTION_APPWIDGET_UPDATE
      val ids = AppWidgetManager.getInstance(context).getAppWidgetIds(ComponentName(context, NextTrainsWidgetProvider::class.java))
      putExtra(AppWidgetManager.EXTRA_APPWIDGET_IDS, ids)
    }

    /** Repinta los widgets puestos (tras descargar el tiempo real). */
    fun refresh(context: Context) = context.sendBroadcast(updateIntent(context))

    /** Un tren sigue en el widget hasta 30 s después de su salida estimada. */
    private const val LEFT_AFTER = 30L

    private fun hhmm(epochSec: Long): String =
      SimpleDateFormat("HH:mm", Locale.ROOT).apply { timeZone = TimeZone.getTimeZone("Europe/Madrid") }.format(Date(epochSec * 1000))

    private fun luminance(argb: Int): Double {
      fun lin(c: Int): Double {
        val v = c / 255.0
        return if (v <= 0.03928) v / 12.92 else Math.pow((v + 0.055) / 1.055, 2.4)
      }
      return 0.2126 * lin((argb shr 16) and 0xFF) + 0.7152 * lin((argb shr 8) and 0xFF) + 0.0722 * lin(argb and 0xFF)
    }
  }
}

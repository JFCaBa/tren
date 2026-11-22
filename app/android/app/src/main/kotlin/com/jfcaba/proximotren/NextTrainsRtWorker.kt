package com.jfcaba.proximotren

import android.content.Context
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.ExistingWorkPolicy
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.Worker
import androidx.work.WorkerParameters
import org.json.JSONArray
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL
import java.util.concurrent.TimeUnit

/**
 * Cada 15 min, con el widget puesto: descarga el tiempo real de Renfe, lo guarda y repinta el widget.
 * Sin red repinta igual, para que los retrasos viejos caduquen y los trenes salidos se vayan.
 */
class NextTrainsRtWorker(context: Context, params: WorkerParameters) : Worker(context, params) {
  override fun doWork(): Result {
    try {
      fetch()?.let { save(applicationContext, it) }
    } catch (_: Exception) {
      // Sin red o Renfe caído: se queda el último guardado.
    }
    NextTrainsWidgetProvider.refresh(applicationContext)
    return Result.success()
  }

  private fun fetch(): RtCache? {
    val conn = URL(RT_URL).openConnection() as HttpURLConnection
    try {
      conn.connectTimeout = 10_000
      conn.readTimeout = 10_000
      conn.setRequestProperty("User-Agent", "Anden/1.4")
      if (conn.responseCode != 200) return null
      val body = conn.inputStream.bufferedReader(Charsets.UTF_8).use { it.readText() }
      return parseTripUpdates(JSONObject(body), System.currentTimeMillis() / 1000)
    } finally {
      conn.disconnect()
    }
  }

  companion object {
    private const val RT_URL = "https://gtfsrt.renfe.com/trip_updates.json"
    private const val PERIODIC = "anden_widget_rt"
    private const val NOW = "anden_widget_rt_now"
    private const val PREFS = "HomeWidgetPreferences" // las de home_widget, donde está el snapshot
    private const val KEY = "widget_rt"

    /** Deja programada la descarga periódica (si ya lo está, no hace nada). */
    fun ensureScheduled(context: Context) {
      WorkManager.getInstance(context).enqueueUniquePeriodicWork(
        PERIODIC, ExistingPeriodicWorkPolicy.KEEP, PeriodicWorkRequestBuilder<NextTrainsRtWorker>(15, TimeUnit.MINUTES).build())
    }

    /** Una descarga ya, al añadir el widget (la periódica tarda 15 min en la primera). */
    fun runNow(context: Context) {
      WorkManager.getInstance(context).enqueueUniqueWork(NOW, ExistingWorkPolicy.KEEP, OneTimeWorkRequestBuilder<NextTrainsRtWorker>().build())
    }

    fun cancel(context: Context) {
      WorkManager.getInstance(context).run {
        cancelUniqueWork(PERIODIC)
        cancelUniqueWork(NOW)
      }
    }

    /** `trip_updates.json` de Renfe: retraso por tren (`tripUpdate.delay`) y cancelados, como la app. */
    fun parseTripUpdates(json: JSONObject, fetchedAt: Long): RtCache {
      val feedAt = json.optJSONObject("header")?.opt("timestamp")?.toString()?.toLongOrNull() ?: 0
      val trips = HashMap<String, RtTrip>()
      val entities = json.optJSONArray("entity") ?: JSONArray()
      for (i in 0 until entities.length()) {
        val tu = entities.optJSONObject(i)?.optJSONObject("tripUpdate") ?: continue
        val trip = tu.optJSONObject("trip") ?: continue
        val id = trip.optString("tripId").takeIf { it.isNotEmpty() } ?: continue
        val delay = if (tu.isNull("delay")) null else tu.opt("delay")?.toString()?.toDoubleOrNull()?.toInt()
        trips[id] = RtTrip(delay, trip.optString("scheduleRelationship") == "CANCELED")
      }
      return RtCache(fetchedAt, feedAt, trips)
    }

    private fun save(context: Context, rt: RtCache) {
      val trips = JSONObject()
      for ((id, t) in rt.trips) trips.put(id, JSONArray().put(t.delaySec ?: JSONObject.NULL).put(t.canceled))
      val json = JSONObject().put("fetchedAt", rt.fetchedAt).put("feedAt", rt.feedAt).put("trips", trips)
      context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().putString(KEY, json.toString()).apply()
    }

    fun load(context: Context): RtCache? = try {
      context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getString(KEY, null)?.let { s ->
        val json = JSONObject(s)
        val trips = HashMap<String, RtTrip>()
        val o = json.getJSONObject("trips")
        for (id in o.keys()) {
          val a = o.getJSONArray(id)
          trips[id] = RtTrip(if (a.isNull(0)) null else a.getInt(0), a.getBoolean(1))
        }
        RtCache(json.getLong("fetchedAt"), json.getLong("feedAt"), trips)
      }
    } catch (_: Exception) {
      null
    }
  }
}

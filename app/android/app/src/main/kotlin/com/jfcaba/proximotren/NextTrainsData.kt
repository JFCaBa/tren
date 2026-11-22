package com.jfcaba.proximotren

import kotlin.math.roundToInt

// Datos del widget de próximos trenes: lo que deja la app (lib/widget/next_trains_widget.dart), el
// tiempo real que descarga el propio widget (NextTrainsRtWorker) y la mezcla de ambos. Sin Android,
// para probarlo en la JVM. Misma regla que ios/FollowActivity/NextTrainsData.swift.

/** Un tren tal como lo deja la app: horas programadas y el retraso que la app conocía. */
data class SnapTrain(
  val line: String,
  val color: Int,
  val dest: String,
  val sched: Long,
  val arrSched: Long?,
  val delaySec: Int?,
  val canceled: Boolean,
  val platform: String?,
  val live: Boolean,
  /** Id del trip en el tiempo real de Renfe; nulo si el id se repite en varios días. */
  val rt: String?,
)

data class RtTrip(val delaySec: Int?, val canceled: Boolean)

/** Tiempo real de Renfe que guardó el widget: todo el feed. Épocas en segundos. */
data class RtCache(val fetchedAt: Long, val feedAt: Long, val trips: Map<String, RtTrip>)

/** Un tren listo para pintar. Épocas en segundos. */
data class ShownTrain(
  val line: String,
  val color: Int,
  val dest: String,
  val dep: Long,
  val arrival: Long?,
  val delayMin: Int?,
  val canceled: Boolean,
  val platform: String?,
  val live: Boolean,
)

/** Datos de más de esto no se usan: el tren va a su hora programada. */
const val RT_MAX_AGE_SEC = 30 * 60L

/**
 * Retraso y cancelación de cada tren a la hora [now]: manda la fuente más reciente de menos de
 * 30 min (el tiempo real del widget o el que usó la app, descargado en [appRtAt]); sin ninguna,
 * la hora programada.
 */
fun resolveTrains(trains: List<SnapTrain>, appRtAt: Long?, rt: RtCache?, now: Long): List<ShownTrain> {
  val appAt = appRtAt ?: 0
  val appFresh = now - appAt < RT_MAX_AGE_SEC
  val rtFresh = rt != null && now - rt.fetchedAt < RT_MAX_AGE_SEC && now - rt.feedAt < RT_MAX_AGE_SEC && rt.fetchedAt > appAt
  return trains.map { t ->
    var delay: Int? = null
    var canceled = false
    if (rtFresh) {
      // Como en la app: un tren que no sale en un tiempo real reciente va a su hora.
      t.rt?.let { rt!!.trips[it] }?.let { r ->
        canceled = r.canceled
        delay = if (r.canceled) null else r.delaySec
      }
    } else if (appFresh) {
      canceled = t.canceled
      delay = if (canceled) null else t.delaySec
    }
    val shift = (delay ?: 0).toLong()
    ShownTrain(
      line = t.line, color = t.color, dest = t.dest,
      dep = t.sched + shift,
      arrival = t.arrSched?.let { it + shift },
      delayMin = delay?.let { (it / 60.0).roundToInt() },
      canceled = canceled, platform = t.platform, live = t.live,
    )
  }.sortedBy { it.dep }
}

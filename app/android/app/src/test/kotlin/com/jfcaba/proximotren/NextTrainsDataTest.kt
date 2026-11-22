package com.jfcaba.proximotren

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Misma tabla que la prueba de ios/FollowActivity/NextTrainsData.swift. */
class NextTrainsDataTest {
  private val t = 1_800_000_000L

  private fun tr(id: String?, min: Long, delay: Int? = null, canceled: Boolean = false) =
    SnapTrain("C1", 0, "X", t + min * 60, t + min * 60 + 600, delay, canceled, "1", true, id)

  private val trains = listOf(tr("A", 5, delay = 120), tr("B", 10), tr(null, 12, delay = 60), tr("C", 20, canceled = true))
  private val rt = RtCache(t - 10, t - 20, mapOf("A" to RtTrip(-60, false), "C" to RtTrip(null, false), "B" to RtTrip(900, true)))

  @Test fun appDataWhenFreshAndNoRealTime() {
    val r = resolveTrains(trains, t - 60, null, t)
    assertEquals(2, r[0].delayMin)
    assertEquals(t + 420, r[0].dep)
    assertEquals(t + 300 + 600 + 120, r[0].arrival)
    assertTrue(r.any { it.canceled })
  }

  @Test fun newerWidgetRealTimeWins() {
    val r = resolveTrains(trains, t - 60, rt, t)
    assertEquals(-1, r.first { it.dep == t + 240 }.delayMin)
    assertTrue(r.any { it.canceled && it.dep == t + 600 })
    assertTrue(r.any { !it.canceled && it.delayMin == null && it.dep == t + 1200 })
    assertTrue("no rt id goes on schedule", r.any { it.delayMin == null && it.dep == t + 720 })
  }

  @Test fun appNewerThanRealTimeWins() {
    val old = RtCache(t - 120, t - 120, mapOf("A" to RtTrip(900, false)))
    assertTrue(resolveTrains(trains, t - 60, old, t).any { it.delayMin == 2 })
  }

  @Test fun stalledFeedIgnored() {
    val stalled = RtCache(t - 5, t - 3600, mapOf("A" to RtTrip(900, false)))
    val r = resolveTrains(trains, t - 60, stalled, t)
    assertTrue(r.any { it.delayMin == 2 })
    assertFalse(r.any { it.delayMin == 15 })
  }

  @Test fun appWithoutRealTimeDoesNotHideWidgetRealTime() {
    // La app publicó después, pero sin red (rtAt nulo): manda el tiempo real del widget.
    val r = resolveTrains(trains, null, rt, t)
    assertEquals(-1, r.first { it.dep == t + 240 }.delayMin)
  }

  @Test fun everythingStaleGoesOnSchedule() {
    val r = resolveTrains(trains, t - 60, rt, t + 31 * 60)
    assertTrue(r.all { it.delayMin == null && !it.canceled })
  }

  @Test fun parsesRenfeTripUpdates() {
    val json = JSONObject("""{"header":{"timestamp":"1800000000"},"entity":[
      {"id":"1","tripUpdate":{"trip":{"tripId":"A"},"delay":180}},
      {"id":"2","tripUpdate":{"trip":{"tripId":"B","scheduleRelationship":"CANCELED"}}},
      {"id":"3","tripUpdate":{"trip":{}}},
      {"id":"4"}]}""")
    val r = NextTrainsRtWorker.parseTripUpdates(json, 5)
    assertEquals(1_800_000_000L, r.feedAt)
    assertEquals(RtTrip(180, false), r.trips["A"])
    assertEquals(RtTrip(null, true), r.trips["B"])
    assertEquals(2, r.trips.size)
    assertNull(r.trips["C"])
  }
}

package com.senorarroz.delivery_app

import org.junit.Assert.*
import org.junit.Test

class TrackingEvidenceStateMachineTest {
    @Test fun disabledGpsDoesNotRevokePermissionAndNeedsWholeMinute() {
        val machine = TrackingEvidenceStateMachine(newId = { "gps-1" })
        for (second in 0..50 step 10) assertTrue(machine.observe(false, true, second * 1000L, second * 1000L).isEmpty())
        val event = machine.observe(false, true, 60000, 60000).single()
        assertEquals("gps_disabled", event.type)
        assertEquals(0L, event.at)
        assertNull(event.permission)
        assertTrue(event.details.contains("observed_seconds=60"))
        assertTrue(machine.observe(false, true, 70000, 70000).isEmpty())
        val recovered = machine.observe(true, true, 80000, 80000).single()
        assertEquals("gps_enabled", recovered.type)
        assertTrue(recovered.details.contains("episode=gps-1"))
    }
    @Test fun shortToggleHasNoAdministrativeEpisode() {
        val machine = TrackingEvidenceStateMachine()
        machine.observe(false, true, 0, 0)
        machine.observe(false, true, 10000, 10000)
        assertTrue(machine.observe(true, true, 15000, 15000).isEmpty())
        assertNull(machine.gpsEpisode)
    }
    @Test fun unknownOrSuspendedObservationCannotProveContinuousMinute() {
        val machine = TrackingEvidenceStateMachine()
        machine.observe(false, true, 0, 0)
        machine.observe(false, true, 20000, 20000)
        assertTrue(machine.observe(null, null, 30000, 30000).isEmpty())
        assertTrue(machine.observe(false, true, 60000, 60000).isEmpty())
        assertTrue(machine.observe(false, true, 130000, 130000).isEmpty())
        assertNull(machine.gpsEpisode)
    }
    @Test fun permissionLossIsIndependentAndImmediate() {
        val machine = TrackingEvidenceStateMachine()
        val event = machine.observe(true, false, 0, 0).single()
        assertEquals("location_permission_revoked", event.type)
        assertNull(event.gps)
        assertEquals(false, event.permission)
        assertTrue(machine.observe(false, false, 1000, 1000).isEmpty())
        assertEquals("location_permission_recovered", machine.observe(false, true, 2000, 2000).single().type)
    }
    @Test fun unknownDoesNotResolveAnAlreadyConfirmedEpisode() {
        val machine = TrackingEvidenceStateMachine(gpsEpisode=EvidenceEpisode("kept", 100))
        assertTrue(machine.observe(null, null, 5000, 5000).isEmpty())
        assertEquals("kept", machine.gpsEpisode!!.id)
        assertTrue(machine.observe(false, true, 10000, 10000).isEmpty())
        assertEquals("gps_enabled", machine.observe(true, true, 20000, 20000).single().type)
    }
    @Test fun backwardsWallClockDoesNotCreateMinuteProof() {
        val machine = TrackingEvidenceStateMachine()
        machine.observe(false, true, 0, 0)
        assertTrue(machine.observe(false, true, 5000, 3600000).isEmpty())
    }
    @Test fun oldAndroidOrUserProfileStopIsNeverDeclaredManual() {
        assertEquals("unknown", exitEvidenceCause(33, 10))
        assertEquals("user_requested", exitEvidenceCause(34, 10))
        assertEquals("unknown", exitEvidenceCause(35, 11))
        assertEquals("technical", exitEvidenceCause(35, 16))
        assertEquals("technical", exitEvidenceCause(34, 8))
        assertEquals("technical", exitEvidenceCause(34, 4))
    }
}

package com.senorarroz.delivery_app

import java.util.UUID

/** Pure state machine. A failed state query is unknown, never false.
 * Elapsed time, not wall time, proves the initial continuous disabled minute.
 * Only already-published episodes survive a process restart. */
data class EvidenceEpisode(val id: String, val startedAt: Long)
data class DeviceEvidence(
    val type: String, val at: Long, val details: String,
    val gps: Boolean? = null, val permission: Boolean? = null,
    val internet: Boolean? = null,
)

class TrackingEvidenceStateMachine(
    var gpsEpisode: EvidenceEpisode? = null,
    var permissionEpisode: EvidenceEpisode? = null,
    private val newId: () -> String = { UUID.randomUUID().toString() },
) {
    private var gpsCandidate: Long? = null
    private var candidateWall: Long? = null
    private var lastGpsObservation: Long? = null

    fun observe(locationEnabled: Boolean?, permissionUsable: Boolean?,
        elapsed: Long, wall: Long): List<DeviceEvidence> {
        val result = mutableListOf<DeviceEvidence>()
        if (locationEnabled == null || lastGpsObservation?.let {
                elapsed < it || elapsed - it > 25_000L } == true) {
            gpsCandidate = null
            candidateWall = null
        }
        if (locationEnabled != null) lastGpsObservation = elapsed
        if (locationEnabled == false && gpsEpisode == null) {
            if (gpsCandidate == null) { gpsCandidate = elapsed; candidateWall = wall }
            val seconds = (elapsed - gpsCandidate!!) / 1000
            if (seconds >= 60) {
                val episode = EvidenceEpisode(newId(), candidateWall!!)
                gpsEpisode = episode
                result += DeviceEvidence("gps_disabled", episode.startedAt,
                    "evidence_version=2;source=android_state;episode=${episode.id};location_enabled=false;observed_seconds=$seconds", gps=false)
            }
        } else if (locationEnabled == true) {
            gpsEpisode?.let { episode ->
                result += DeviceEvidence("gps_enabled", wall,
                    "evidence_version=2;source=android_state;episode=${episode.id};location_enabled=true", gps=true)
            }
            gpsEpisode = null; gpsCandidate = null; candidateWall = null
        }
        // Never derive permission from GPS, connectivity or a positioning timeout.
        if (permissionUsable == false && permissionEpisode == null) {
            val episode = EvidenceEpisode(newId(), wall)
            permissionEpisode = episode
            result += DeviceEvidence("location_permission_revoked", wall,
                "evidence_version=2;source=android_state;episode=${episode.id};permission_usable=false", permission=false)
        } else if (permissionUsable == true && permissionEpisode != null) {
            val episode = permissionEpisode!!
            result += DeviceEvidence("location_permission_recovered", wall,
                "evidence_version=2;source=android_state;episode=${episode.id};permission_usable=true", permission=true)
            permissionEpisode = null
        }
        return result
    }
}

/** Android <=33 also used reason 10 for updates/component changes. Reason 11
 * means an Android user/profile stopped, not proof of stopping this app. */
fun exitEvidenceCause(sdk: Int, reason: Int): String = when {
    sdk >= 34 && reason == 10 -> "user_requested"
    reason in setOf(1, 2, 3, 4, 5, 6, 7, 8, 12, 13, 14, 15, 16) -> "technical"
    else -> "unknown"
}

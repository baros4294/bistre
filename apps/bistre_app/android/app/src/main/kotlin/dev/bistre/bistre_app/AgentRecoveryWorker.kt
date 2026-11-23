package dev.bistre.bistre_app

import android.content.Context
import androidx.work.CoroutineWorker
import androidx.work.WorkerParameters

/**
 * Expedited WorkManager worker scheduled when Android OEM battery managers or FGS timeouts
 * interrupt an active durable Bistre run, nudging WAL reconciliation on resume.
 */
class AgentRecoveryWorker(
    appContext: Context,
    params: WorkerParameters,
) : CoroutineWorker(appContext, params) {

    override suspend fun doWork(): Result {
        MainActivity.emitPowerEvent("did_resume")
        return Result.success()
    }
}

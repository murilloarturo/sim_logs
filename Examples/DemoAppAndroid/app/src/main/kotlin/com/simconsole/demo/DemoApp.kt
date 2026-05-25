package com.simconsole.demo

import android.app.Application
import com.simconsole.Metric
import com.simconsole.SimConsole

/**
 * Boots SimConsole as early as possible. `Application.onCreate` runs before
 * any Activity's `onCreate`, so launch milestones from this point are usable
 * for measuring cold-start time.
 *
 * Production apps should guard this with `BuildConfig.DEBUG` so the SDK
 * doesn't ship in release. The demo app is debug-only so we skip the guard.
 */
class DemoApp : Application() {
    override fun onCreate() {
        super.onCreate()
        SimConsole.bootstrap(this, subsystem = BuildConfig.APPLICATION_ID)
        Metric.appStartLaunch()
        Metric.launchMilestone("application_oncreate")
    }
}

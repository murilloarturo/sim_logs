package com.simconsole.demo

import android.os.Bundle
import androidx.appcompat.app.AppCompatActivity
import com.simconsole.Metric
import com.simconsole.SimConsole
import com.simconsole.SimConsoleInterceptor
import com.simconsole.demo.databinding.ActivityMainBinding
import okhttp3.OkHttpClient
import okhttp3.Request
import java.io.IOException
import kotlin.concurrent.thread

class MainActivity : AppCompatActivity() {

    private lateinit var binding: ActivityMainBinding

    private val httpClient by lazy {
        OkHttpClient.Builder()
            .addInterceptor(SimConsoleInterceptor())
            .build()
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        binding = ActivityMainBinding.inflate(layoutInflater)
        setContentView(binding.root)

        // Each visible Activity is a "screen" — call once on appear.
        SimConsole.screen("MainActivity")
        // Closes the launch-timing arc started in DemoApp.onCreate.
        Metric.appFinishLaunching()

        binding.btnAnalytics.setOnClickListener {
            SimConsole.analytics(
                event = "demo_tapped",
                params = mapOf("button" to "analytics", "platform" to "android"),
            )
            status("Fired analytics event 'demo_tapped'.")
        }

        binding.btnScreen.setOnClickListener {
            SimConsole.screen(
                name = "FakeDetailScreen",
                params = mapOf("source" to "demo"),
            )
            status("Recorded screen view 'FakeDetailScreen'.")
        }

        binding.btnLog.setOnClickListener {
            SimConsole.log(
                message = "user touched the warn button",
                level = SimConsole.Level.Warn,
                fields = mapOf("touch_count" to (++touchCount)),
            )
            status("Emitted a warn log.")
        }

        binding.btnNetwork.setOnClickListener {
            status("Sending request to httpbin.org…")
            // Off-main-thread because OkHttp won't run synchronously on the main
            // thread (NetworkOnMainThreadException). A real app would use
            // coroutines; thread {} keeps the demo deps minimal.
            thread(name = "demo-http") {
                try {
                    val response = httpClient.newCall(
                        Request.Builder()
                            .url("https://httpbin.org/get?from=sim-console-demo")
                            .header("X-Demo", "android")
                            .build(),
                    ).execute()
                    response.use {
                        runOnUiThread { status("HTTP ${it.code} from httpbin.org") }
                    }
                } catch (e: IOException) {
                    runOnUiThread { status("Request failed: ${e.message}") }
                }
            }
        }

        binding.btnMetric.setOnClickListener {
            Metric.gauge(
                name = "demo.cache_hit_rate",
                value = 0.87,
                fields = mapOf("source" to "demo_button"),
            )
            Metric.measure(name = "demo.fake_decode") {
                // Pretend to do work.
                var checksum = 0L
                for (i in 0 until 200_000) checksum += i
                checksum
            }
            status("Emitted a gauge + signpost.")
        }

        binding.btnHang.setOnClickListener {
            status("Blocking main thread for 600ms…")
            Thread.sleep(600)
            status("Main thread released. HangDetector should have logged.")
        }
    }

    private var touchCount = 0

    private fun status(message: String) {
        binding.status.text = message
    }
}

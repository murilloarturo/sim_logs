package com.simconsole

import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Before
import org.junit.Test
import java.io.File
import java.nio.file.Files

class MockStoreTest {

    private lateinit var tmpDir: File
    private lateinit var mocksFile: File

    @Before
    fun setUp() {
        tmpDir = Files.createTempDirectory("simconsole-mock-test").toFile()
        mocksFile = File(tmpDir, "sim-console-mocks-test.json")
    }

    @After
    fun tearDown() {
        tmpDir.deleteRecursively()
        // Reset the singleton so a later test class starts clean.
        MockStore.configure("")
    }

    private fun writeFile(json: String) {
        mocksFile.writeText(json)
        MockStore.reloadFromPath(mocksFile.absolutePath)
    }

    @Test
    fun matchesMethodAndUrlExactly() {
        writeFile(
            """
            {"version":1,"mocks":[
              {"id":"1","match":{"method":"GET","url":"https://api/x"},
               "response":{"status":204,"headers":{}},
               "delay_ms":0,"enabled":true,"created_at":"now"}
            ]}
            """.trimIndent(),
        )
        assertNotNull(MockStore.findMock("GET", "https://api/x", body = null))
        assertNull("different URL path shouldn't match",
            MockStore.findMock("GET", "https://api/y", body = null))
        assertNull("different method shouldn't match",
            MockStore.findMock("POST", "https://api/x", body = null))
    }

    @Test
    fun methodMatchingIsCaseInsensitive() {
        writeFile(
            """
            {"version":1,"mocks":[
              {"id":"1","match":{"method":"get","url":"https://x"},
               "response":{"status":200,"headers":{}},
               "delay_ms":0,"enabled":true,"created_at":""}
            ]}
            """.trimIndent(),
        )
        assertNotNull(MockStore.findMock("GET", "https://x", null))
    }

    @Test
    fun bodyContainsNarrowsTheMatch() {
        writeFile(
            """
            {"version":1,"mocks":[
              {"id":"1","match":{"method":"POST","url":"https://api/u","body_contains":"alice"},
               "response":{"status":200,"headers":{}},
               "delay_ms":0,"enabled":true,"created_at":""}
            ]}
            """.trimIndent(),
        )
        assertNotNull(MockStore.findMock("POST", "https://api/u", """{"name":"alice"}"""))
        assertNull(MockStore.findMock("POST", "https://api/u", """{"name":"bob"}"""))
        assertNull("missing body shouldn't match a body_contains rule",
            MockStore.findMock("POST", "https://api/u", null))
    }

    @Test
    fun disabledMocksAreIgnored() {
        writeFile(
            """
            {"version":1,"mocks":[
              {"id":"1","match":{"method":"GET","url":"https://api/z"},
               "response":{"status":200,"headers":{}},
               "delay_ms":0,"enabled":false,"created_at":""}
            ]}
            """.trimIndent(),
        )
        assertNull(MockStore.findMock("GET", "https://api/z", null))
    }

    @Test
    fun mtimeChangeReloadsTheFile() {
        writeFile(
            """{"version":1,"mocks":[
              {"id":"1","match":{"method":"GET","url":"https://api/v1"},
               "response":{"status":200,"headers":{}},
               "delay_ms":0,"enabled":true,"created_at":""}
            ]}""",
        )
        assertNotNull(MockStore.findMock("GET", "https://api/v1", null))

        // Bump the mtime so the stat-poll picks up the rewrite.
        Thread.sleep(1100)
        mocksFile.writeText(
            """{"version":1,"mocks":[
              {"id":"2","match":{"method":"GET","url":"https://api/v2"},
               "response":{"status":200,"headers":{}},
               "delay_ms":0,"enabled":true,"created_at":""}
            ]}""",
        )
        // Re-pin the path so findMock re-stats. (reloadFromPath resets the
        // cached mtime; in production we re-stat on every findMock call.)
        MockStore.reloadFromPath(mocksFile.absolutePath)
        assertNull(MockStore.findMock("GET", "https://api/v1", null))
        assertNotNull(MockStore.findMock("GET", "https://api/v2", null))
    }

    @Test
    fun missingFileMeansNoMocks() {
        // Point at a path that doesn't exist.
        MockStore.reloadFromPath(File(tmpDir, "does-not-exist.json").absolutePath)
        assertEquals(0, MockStore.currentMocks().size)
        assertNull(MockStore.findMock("GET", "https://any", null))
    }

    @Test
    fun malformedFilePreservesLastGoodState() {
        writeFile(
            """{"version":1,"mocks":[
              {"id":"1","match":{"method":"GET","url":"https://api/ok"},
               "response":{"status":200,"headers":{}},
               "delay_ms":0,"enabled":true,"created_at":""}
            ]}""",
        )
        assertNotNull(MockStore.findMock("GET", "https://api/ok", null))

        Thread.sleep(1100)
        mocksFile.writeText("this is not json")
        MockStore.reloadFromPath(mocksFile.absolutePath)
        // Last good state should still serve the GET /ok mock.
        assertNotNull(MockStore.findMock("GET", "https://api/ok", null))
    }
}

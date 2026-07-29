package io.legado.app.oracle

import android.app.Activity
import android.app.Instrumentation
import android.content.Context
import android.content.Intent
import android.os.Bundle
import android.os.SystemClock
import android.util.Base64
import android.util.Log
import androidx.lifecycle.Lifecycle
import androidx.test.core.app.ActivityScenario
import androidx.test.espresso.Espresso.onView
import androidx.test.espresso.action.ViewActions.click
import androidx.test.espresso.matcher.ViewMatchers.withId
import androidx.test.espresso.matcher.ViewMatchers.withText
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.runner.lifecycle.ActivityLifecycleMonitorRegistry
import androidx.test.runner.lifecycle.Stage
import io.legado.app.BuildConfig
import io.legado.app.R
import io.legado.app.constant.AppConst.appInfo
import io.legado.app.constant.BookType
import io.legado.app.constant.PreferKey
import io.legado.app.data.entities.Book
import io.legado.app.data.entities.BookChapter
import io.legado.app.data.entities.BookSource
import io.legado.app.data.entities.Bookmark
import io.legado.app.data.entities.ReadRecord
import io.legado.app.data.entities.SearchBook
import io.legado.app.data.appDb
import io.legado.app.exception.ConcurrentException
import io.legado.app.help.CacheManager
import io.legado.app.help.book.BookHelp
import io.legado.app.help.config.AppConfig
import io.legado.app.help.config.LocalConfig
import io.legado.app.help.http.CookieManager
import io.legado.app.help.http.CookieStore
import io.legado.app.help.http.StrResponse
import io.legado.app.help.http.newCallResponse
import io.legado.app.lib.webdav.Authorization
import io.legado.app.lib.webdav.WebDav
import io.legado.app.lib.webdav.WebDavFile
import io.legado.app.model.CacheBook
import io.legado.app.model.AudioPlay
import io.legado.app.model.ReadBook
import io.legado.app.model.analyzeRule.AnalyzeRule
import io.legado.app.model.analyzeRule.AnalyzeUrl
import io.legado.app.model.analyzeRule.RuleData
import io.legado.app.model.webBook.WebBook
import io.legado.app.ui.book.read.page.entities.TextChapter
import io.legado.app.ui.book.read.page.entities.TextLine
import io.legado.app.ui.book.read.page.entities.TextPage
import io.legado.app.ui.book.read.ReadBookActivity
import io.legado.app.ui.main.MainActivity
import io.legado.app.ui.welcome.WelcomeActivity
import io.legado.app.ui.widget.dialog.TextDialog
import io.legado.app.utils.GSON
import io.legado.app.utils.NetworkUtils
import io.legado.app.utils.defaultSharedPreferences
import io.legado.app.utils.putPrefBoolean
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.async
import kotlinx.coroutines.cancelChildren
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.json.JSONArray
import org.json.JSONObject
import org.jsoup.nodes.Element
import org.junit.Test
import org.junit.runner.RunWith
import org.seimicrawler.xpath.JXNode
import java.io.File
import java.io.IOException
import java.lang.reflect.InvocationTargetException
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicReference
import okhttp3.OkHttpClient
import okhttp3.Headers
import okhttp3.Protocol
import okhttp3.Request
import okhttp3.Response
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.ResponseBody.Companion.toResponseBody
import okio.Buffer

@RunWith(AndroidJUnit4::class)
class LegadoOracleInstrumentedTest {
    private val arguments = InstrumentationRegistry.getArguments()
    private val logicalOrigin = requiredArgument("logicalOrigin").trimEnd('/')
    private val scenarioId = requiredArgument("scenarioId")
    private val isAndroidRuntimeScenario = scenarioId.startsWith("rl-")
    private val isIntegrationLabScenario = scenarioId.startsWith("il-")
    private val input = JSONObject(
        String(
            Base64.decode(
                requiredArgument("inputBase64"),
                Base64.DEFAULT
            ),
            Charsets.UTF_8
        )
    )
    private val sourceJson by lazy {
        val encoded = arguments.getString("sourceBase64")
        require(!encoded.isNullOrEmpty()) {
            "Source scenario requires sourceBase64"
        }
        String(Base64.decode(encoded, Base64.DEFAULT), Charsets.UTF_8)
    }
    private val source: BookSource by lazy {
        GSON.fromJson(sourceJson, BookSource::class.java)
    }
    private val deviceOrigin by lazy {
        when {
            isAndroidRuntimeScenario -> "android-runtime://local"
            isIntegrationLabScenario ->
                requiredArgument("deviceOrigin").trimEnd('/')
            else -> source.bookSourceUrl.trimEnd('/')
        }
    }
    private val cases = JSONArray()
    private val requestPlan = JSONArray()

    @Test
    fun runCharacterization() = runBlocking {
        if (!isAndroidRuntimeScenario && !isIntegrationLabScenario) {
            require(deviceOrigin.startsWith("http://127.0.0.1:")) {
                "Oracle source must use the run-scoped device loopback origin"
            }
            source.enabledCookieJar =
                scenarioId == "sl-source-request-header-cookie-retry-layering-001" ||
                    scenarioId == "sl-source-cookie-persistent-session-merge-runtime-001"
        }
        if (isIntegrationLabScenario) {
            require(deviceOrigin.startsWith("http://127.0.0.1:")) {
                "Integration Oracle must use the run-scoped loopback origin"
            }
        }

        when (scenarioId) {
            "il-integration-backup-webdav-001" ->
                runWebDavIntegrationCases()
            "rl-reader-bookmark-search-runtime-risk-001" ->
                runBookmarkRuntimeCases()
            "rl-reader-history-read-record-runtime-risk-001" ->
                runReadRecordRuntimeCases()
            "rl-reader-progress-layout-save-runtime-001" ->
                runReaderProgressRuntimeCases()
            "rl-reader-cache-prefetch-policy-001" ->
                runReaderPrefetchPolicyCases()
            "rl-reader-progress-toc-remap-001" ->
                runReaderProgressTocRemapCases()
            "rl-app-startup-first-use-and-restore-001" ->
                runAppStartupCases()
            "sl-post-form-001" -> runPostFormCases()
            "sl-source-response-xml-declaration-normalization-001" ->
                runXmlResponseCases()
            "sl-source-request-header-cookie-retry-layering-001" ->
                runRequestOptionCases()
            "sl-source-request-field-encoding-runtime-001" ->
                runFieldEncodingCases()
            "sl-source-request-url-template-compilation-001" ->
                runURLTemplateCompilationCases()
            "sl-source-session-rate-limit-shared-state-001" ->
                runRateLimitStateCases()
            "sl-source-transport-request-dispatch-contract-001" ->
                runTransportDispatchCases()
            "sl-source-transport-response-decoding-runtime-001" ->
                runResponseDecodingCases()
            "sl-source-transport-retry-redirect-runtime-001" ->
                runRetryRedirectCases()
            "sl-source-cookie-persistent-session-merge-runtime-001" ->
                runCookieSessionCases()
            "sl-source-transport-dynamic-web-runtime-001" ->
                runDynamicWebCases()
            "sl-source-session-rule-variable-scope-001" ->
                runRuleVariableScopeCases()
            "sl-source-rule-backend-dispatch-runtime-001" ->
                runRuleBackendDispatchCases()
            "sl-source-rule-combination-and-coercion-runtime-001" ->
                runRuleCombinationCases()
            "sl-source-rule-dom-selector-backends-001" ->
                runDOMSelectorBackendCases()
            "sl-source-rule-jsonpath-regex-backends-001" ->
                runJSONPathRegexBackendCases()
            "sl-content-cache-queue-completion-runtime-001" ->
                runContentCacheQueueCompletionCases()
            else -> {
                runCase("search-hit", "search", searchRequest("星河")) {
                    searchProjection(WebBook.searchBookAwait(source, "星河"))
                }
                runCase("search-empty", "search", searchRequest("不存在")) {
                    searchProjection(WebBook.searchBookAwait(source, "不存在"))
                }
                runCase(
                    "book-detail",
                    "book_info",
                    request("$deviceOrigin/books/star-river/index.html")
                ) {
                    bookProjection(
                        WebBook.getBookInfoAwait(
                            source,
                            Book(
                                bookUrl = "$deviceOrigin/books/star-river/index.html",
                                origin = source.bookSourceUrl,
                                originName = source.bookSourceName
                            )
                        )
                    )
                }
                runCase(
                    "book-detail-missing-cover",
                    "book_info",
                    request("$deviceOrigin/books/no-cover/index.html")
                ) {
                    bookProjection(
                        WebBook.getBookInfoAwait(
                            source,
                            Book(
                                bookUrl = "$deviceOrigin/books/no-cover/index.html",
                                origin = source.bookSourceUrl,
                                originName = source.bookSourceName
                            )
                        )
                    )
                }
                runCase(
                    "toc",
                    "chapters",
                    request("$deviceOrigin/books/star-river/toc.html")
                ) {
                    val book = Book(
                        bookUrl = "$deviceOrigin/books/star-river/index.html",
                        tocUrl = "$deviceOrigin/books/star-river/toc.html",
                        origin = source.bookSourceUrl,
                        originName = source.bookSourceName,
                        name = "星河纪事"
                    )
                    chapterProjection(
                        WebBook.getChapterListAwait(source, book).getOrThrow()
                    )
                }
                runCase(
                    "toc-empty",
                    "chapters",
                    request("$deviceOrigin/books/no-cover/toc.html")
                ) {
                    val book = Book(
                        bookUrl = "$deviceOrigin/books/no-cover/index.html",
                        tocUrl = "$deviceOrigin/books/no-cover/toc.html",
                        origin = source.bookSourceUrl,
                        originName = source.bookSourceName,
                        name = "无封面之书"
                    )
                    chapterProjection(
                        WebBook.getChapterListAwait(source, book).getOrThrow()
                    )
                }
                runCase(
                    "chapter",
                    "content",
                    request("$deviceOrigin/books/star-river/chapter-1.html")
                ) {
                    contentProjection("chapter-1.html", 0)
                }
                runCase(
                    "chapter-second",
                    "content",
                    request("$deviceOrigin/books/star-river/chapter-2.html")
                ) {
                    contentProjection("chapter-2.html", 1)
                }
            }
        }

        val raw = JSONObject()
            .put("schema_version", 1)
            .put("scenario_id", scenarioId)
            .put("device_origin", deviceOrigin)
            .put("logical_origin", logicalOrigin)
            .put("request_plan", requestPlan)
            .put("cases", cases)
        val target = InstrumentationRegistry.getInstrumentation().targetContext
        File(target.filesDir, OUTPUT_FILE).writeText(raw.toString(), Charsets.UTF_8)
    }

    private suspend fun runWebDavIntegrationCases() {
        val values = input.getJSONArray("cases")
        for (index in 0 until values.length()) {
            val value = values.getJSONObject(index)
            val operation = value.getString("operation")
            require(
                operation in setOf(
                    "webdav_check",
                    "webdav_exists",
                    "webdav_make_directory",
                    "webdav_list",
                    "webdav_get_file",
                    "webdav_download",
                    "webdav_upload",
                    "webdav_delete"
                )
            ) {
                "Unsupported WebDAV integration operation: $operation"
            }
            val arguments = value.getJSONObject("arguments")
            val stimulus = JSONObject()
                .put("operation", operation)
                .put("arguments", JSONObject(arguments.toString()))
            runCase(
                value.getString("id"),
                operation,
                stimulus
            ) {
                webDavProjection(operation, arguments)
            }
        }
    }

    private suspend fun webDavProjection(
        operation: String,
        arguments: JSONObject
    ): JSONObject {
        val client = WebDav(
            "$deviceOrigin${arguments.getString("target")}",
            Authorization("oracle-user", "oracle-password")
        )
        return when (operation) {
            "webdav_check" -> JSONObject()
                .put("accepted", client.check())
            "webdav_exists" -> JSONObject()
                .put("exists", client.exists())
            "webdav_make_directory" -> JSONObject()
                .put("created", client.makeAsDir())
            "webdav_list" -> JSONObject().put(
                "files",
                JSONArray().apply {
                    client.listFiles().forEach { put(webDavFileProjection(it)) }
                }
            )
            "webdav_get_file" -> JSONObject().put(
                "file",
                client.getWebDavFile()?.let(::webDavFileProjection)
                    ?: JSONObject.NULL
            )
            "webdav_download" -> {
                val bytes = client.download()
                JSONObject()
                    .put(
                        "body_base64",
                        Base64.encodeToString(bytes, Base64.NO_WRAP)
                    )
                    .put("body_bytes", bytes.size)
            }
            "webdav_upload" -> {
                val bytes = arguments
                    .getString("payload_utf8")
                    .toByteArray(Charsets.UTF_8)
                client.upload(
                    bytes,
                    arguments.getString("media_type")
                )
                JSONObject()
                    .put("completed", true)
                    .put("body_bytes", bytes.size)
            }
            "webdav_delete" -> JSONObject()
                .put("deleted", client.delete())
            else -> error("Unsupported WebDAV operation: $operation")
        }
    }

    private fun webDavFileProjection(value: WebDavFile): JSONObject =
        JSONObject()
            .put("path", logical(value.path))
            .put("display_name", value.displayName)
            .put("url_name", value.urlName)
            .put("size", value.size)
            .put("content_type", value.contentType)
            .put("resource_type", value.resourceType)
            .put("last_modify", value.lastModify)
            .put("is_directory", value.isDir)

    private suspend fun runBookmarkRuntimeCases() {
        val values = input.getJSONArray("cases")
        for (index in 0 until values.length()) {
            val value = values.getJSONObject(index)
            val operation = value.getString("operation")
            require(
                operation == "bookmark_search" ||
                    operation == "bookmark_insert_conflict"
            ) {
                "Unsupported bookmark runtime operation: $operation"
            }
            val arguments = value.getJSONObject("arguments")
            val stimulus = JSONObject()
                .put("operation", operation)
                .put("arguments", JSONObject(arguments.toString()))
            runCase(
                value.getString("id"),
                operation,
                stimulus
            ) {
                bookmarkRuntimeProjection(operation, arguments)
            }
        }
    }

    private suspend fun bookmarkRuntimeProjection(
        operation: String,
        arguments: JSONObject
    ): JSONObject {
        clearBookmarks()
        return try {
            val rows = arguments.getJSONArray("rows")
            for (index in 0 until rows.length()) {
                appDb.bookmarkDao.insert(bookmark(rows.getJSONObject(index)))
            }
            val selected = when (operation) {
                "bookmark_search" -> appDb.bookmarkDao.flowSearch(
                    arguments.getString("book_name"),
                    arguments.getString("book_author"),
                    arguments.getString("key")
                ).first()
                "bookmark_insert_conflict" -> appDb.bookmarkDao.all
                else -> error("Unsupported bookmark runtime operation")
            }
            JSONObject()
                .put("row_count", selected.size)
                .put(
                    "rows",
                    JSONArray().apply {
                        selected.forEach { put(bookmarkProjection(it)) }
                    }
                )
        } finally {
            clearBookmarks()
        }
    }

    private fun clearBookmarks() {
        val existing = appDb.bookmarkDao.all
        if (existing.isNotEmpty()) {
            appDb.bookmarkDao.delete(*existing.toTypedArray())
        }
    }

    private fun bookmark(value: JSONObject): Bookmark = Bookmark(
        time = value.getLong("time"),
        bookName = value.getString("bookName"),
        bookAuthor = value.getString("bookAuthor"),
        chapterIndex = value.getInt("chapterIndex"),
        chapterPos = value.getInt("chapterPos"),
        chapterName = value.getString("chapterName"),
        bookText = value.getString("bookText"),
        content = value.getString("content")
    )

    private fun bookmarkProjection(value: Bookmark): JSONObject =
        JSONObject()
            .put("time", value.time)
            .put("book_name", value.bookName)
            .put("book_author", value.bookAuthor)
            .put("chapter_index", value.chapterIndex)
            .put("chapter_pos", value.chapterPos)
            .put("chapter_name", value.chapterName)
            .put("book_text", value.bookText)
            .put("content", value.content)

    private suspend fun runReadRecordRuntimeCases() {
        val values = input.getJSONArray("cases")
        val supported = setOf(
            "read_record_query",
            "read_record_reset",
            "read_record_session_write",
            "read_record_pause_boundary",
            "read_record_disabled",
            "read_record_insert_conflict"
        )
        for (index in 0 until values.length()) {
            val value = values.getJSONObject(index)
            val operation = value.getString("operation")
            require(operation in supported) {
                "Unsupported read-record runtime operation: $operation"
            }
            val arguments = value.getJSONObject("arguments")
            val stimulus = JSONObject()
                .put("operation", operation)
                .put("arguments", JSONObject(arguments.toString()))
            runCase(
                value.getString("id"),
                operation,
                stimulus
            ) {
                readRecordRuntimeProjection(operation, arguments)
            }
        }
    }

    private fun readRecordRuntimeProjection(
        operation: String,
        arguments: JSONObject
    ): JSONObject {
        clearReadRecords()
        return try {
            when (operation) {
                "read_record_query" ->
                    readRecordQueryProjection(arguments)
                "read_record_reset" ->
                    readRecordResetProjection(arguments)
                "read_record_session_write" ->
                    readRecordSessionWriteProjection(arguments)
                "read_record_pause_boundary" ->
                    readRecordPauseProjection(arguments)
                "read_record_disabled" ->
                    readRecordDisabledProjection(arguments)
                "read_record_insert_conflict" ->
                    readRecordConflictProjection(arguments)
                else -> error("Unsupported read-record runtime operation")
            }
        } finally {
            drainReadBookExecutor()
            ReadBook.book = null
            clearReadRecords()
        }
    }

    private fun readRecordQueryProjection(
        arguments: JSONObject
    ): JSONObject {
        seedReadRecords(arguments)
        val bookName = arguments.getString("book_name")
        val deviceIds = arguments.getJSONArray("device_ids")
        return JSONObject()
            .put(
                "all_device_read_time",
                appDb.readRecordDao.getReadTime(bookName)
                    ?: JSONObject.NULL
            )
            .put("all_books_read_time", appDb.readRecordDao.allTime)
            .put(
                "per_device",
                JSONArray().apply {
                    for (index in 0 until deviceIds.length()) {
                        val deviceId = deviceIds.getString(index)
                        put(
                            JSONObject()
                                .put("device_id", deviceId)
                                .put(
                                    "read_time",
                                    appDb.readRecordDao.getReadTime(
                                        deviceId,
                                        bookName
                                    ) ?: JSONObject.NULL
                                )
                        )
                    }
                }
            )
    }

    private fun readRecordResetProjection(
        arguments: JSONObject
    ): JSONObject {
        seedReadRecords(arguments)
        val bookName = arguments.getString("book_name")
        val aggregate = requireNotNull(
            appDb.readRecordDao.getReadTime(bookName)
        )
        ReadBook.resetData(readRecordBook(bookName, "reset"))
        val session = currentSessionReadRecord()
        return JSONObject()
            .put("aggregate_before_reset", aggregate)
            .put("session_device_id", session.deviceId)
            .put("session_book_name", session.bookName)
            .put("session_read_time", session.readTime)
            .put(
                "session_uses_all_device_total",
                session.readTime == aggregate
            )
    }

    private fun readRecordSessionWriteProjection(
        arguments: JSONObject
    ): JSONObject {
        seedReadRecords(arguments)
        val bookName = arguments.getString("book_name")
        val aggregateBefore = requireNotNull(
            appDb.readRecordDao.getReadTime(bookName)
        )
        val foreignRowsBefore = readRecordRows()
            .filter { it.bookName == bookName && it.deviceId.isNotEmpty() }
        val foreignTotal = foreignRowsBefore.sumOf { it.readTime }
        val previousEnabled = AppConfig.enableReadRecord
        return try {
            AppConfig.enableReadRecord = true
            ReadBook.resetData(readRecordBook(bookName, "session-write"))
            ReadBook.readStartTime = System.currentTimeMillis()
            ReadBook.upReadTime()
            drainReadBookExecutor()
            val empty = requireNotNull(
                readRecordRows().firstOrNull {
                    it.bookName == bookName && it.deviceId.isEmpty()
                }
            )
            val foreignRowsAfter = readRecordRows()
                .filter {
                    it.bookName == bookName && it.deviceId.isNotEmpty()
                }
            val aggregateAfter = requireNotNull(
                appDb.readRecordDao.getReadTime(bookName)
            )
            JSONObject()
                .put("aggregate_before", aggregateBefore)
                .put("foreign_device_total", foreignTotal)
                .put("inserted_device_id", empty.deviceId)
                .put(
                    "inserted_at_least_aggregate_before",
                    empty.readTime >= aggregateBefore
                )
                .put(
                    "session_delta_nonnegative",
                    empty.readTime - aggregateBefore >= 0
                )
                .put(
                    "foreign_rows_preserved",
                    readRecordRowsEqual(
                        foreignRowsBefore,
                        foreignRowsAfter
                    )
                )
                .put(
                    "aggregate_after_minus_empty_row",
                    aggregateAfter - empty.readTime
                )
                .put(
                    "foreign_time_counted_twice",
                    aggregateAfter >= aggregateBefore + foreignTotal
                )
        } finally {
            AppConfig.enableReadRecord = previousEnabled
        }
    }

    private fun readRecordPauseProjection(
        arguments: JSONObject
    ): JSONObject {
        seedReadRecords(arguments)
        val bookName = arguments.getString("book_name")
        ReadBook.resetData(readRecordBook(bookName, "pause"))
        val session = currentSessionReadRecord()
        val fixedStart = arguments.getLong("read_start_time")
        ReadBook.readStartTime = fixedStart
        val before = readRecordRows()
        ReadBook.saveRead()
        drainReadBookExecutor()
        val after = readRecordRows()
        val persistedEmpty = requireNotNull(
            after.firstOrNull {
                it.bookName == bookName && it.deviceId.isEmpty()
            }
        )
        return JSONObject()
            .put(
                "database_rows_unchanged",
                readRecordRowsEqual(before, after)
            )
            .put(
                "read_start_time_unchanged",
                ReadBook.readStartTime == fixedStart
            )
            .put("session_in_memory_read_time", session.readTime)
            .put(
                "persisted_empty_device_read_time",
                persistedEmpty.readTime
            )
            .put(
                "save_read_settled_session_time",
                session.readTime != currentSessionReadRecord().readTime ||
                    !readRecordRowsEqual(before, after)
            )
    }

    private fun readRecordDisabledProjection(
        arguments: JSONObject
    ): JSONObject {
        seedReadRecords(arguments)
        val bookName = arguments.getString("book_name")
        ReadBook.resetData(readRecordBook(bookName, "disabled"))
        val fixedStart = arguments.getLong("read_start_time")
        val previousEnabled = AppConfig.enableReadRecord
        return try {
            AppConfig.enableReadRecord = false
            ReadBook.readStartTime = fixedStart
            ReadBook.upReadTime()
            drainReadBookExecutor()
            JSONObject()
                .put("persisted_row_count", readRecordRows().size)
                .put(
                    "read_start_time_unchanged",
                    ReadBook.readStartTime == fixedStart
                )
                .put(
                    "session_read_time",
                    currentSessionReadRecord().readTime
                )
        } finally {
            AppConfig.enableReadRecord = previousEnabled
        }
    }

    private fun readRecordConflictProjection(
        arguments: JSONObject
    ): JSONObject {
        seedReadRecords(arguments)
        val bookName = arguments.getString("book_name")
        val rows = readRecordRows().filter { it.bookName == bookName }
        return JSONObject()
            .put("row_count", rows.size)
            .put("aggregate_read_time", appDb.readRecordDao.getReadTime(bookName))
            .put(
                "rows",
                JSONArray().apply {
                    rows.forEach { put(readRecordProjection(it)) }
                }
            )
    }

    private fun seedReadRecords(arguments: JSONObject) {
        val rows = arguments.getJSONArray("rows")
        for (index in 0 until rows.length()) {
            appDb.readRecordDao.insert(
                readRecord(rows.getJSONObject(index))
            )
        }
    }

    private fun clearReadRecords() {
        appDb.readRecordDao.clear()
    }

    private fun drainReadBookExecutor() {
        ReadBook.executor.submit {}.get(5, TimeUnit.SECONDS)
    }

    private fun readRecordRows(): List<ReadRecord> =
        appDb.readRecordDao.all.sortedWith(
            compareBy<ReadRecord> { it.bookName }
                .thenBy { it.deviceId }
        )

    private fun readRecordRowsEqual(
        left: List<ReadRecord>,
        right: List<ReadRecord>
    ): Boolean =
        left.map(::readRecordProjection).map(JSONObject::toString) ==
            right.map(::readRecordProjection).map(JSONObject::toString)

    private fun currentSessionReadRecord(): ReadRecord {
        val field = ReadBook::class.java.getDeclaredField("readRecord")
        field.isAccessible = true
        return field.get(ReadBook) as ReadRecord
    }

    private fun readRecordBook(
        bookName: String,
        suffix: String
    ): Book = Book(
        bookUrl = "/android-runtime/read-record/$suffix.txt",
        originName = "RuntimeLab",
        name = bookName,
        author = "RuntimeLab"
    )

    private fun readRecord(value: JSONObject): ReadRecord = ReadRecord(
        deviceId = value.getString("deviceId"),
        bookName = value.getString("bookName"),
        readTime = value.getLong("readTime"),
        lastRead = value.getLong("lastRead")
    )

    private fun readRecordProjection(value: ReadRecord): JSONObject =
        JSONObject()
            .put("device_id", value.deviceId)
            .put("book_name", value.bookName)
            .put("read_time", value.readTime)
            .put("last_read", value.lastRead)

    private suspend fun runReaderProgressRuntimeCases() {
        val values = input.getJSONArray("cases")
        val supported = setOf(
            "layout_set_page_index",
            "layout_char_to_page",
            "save_read_page_changed",
            "reset_progress",
            "audio_save_read"
        )
        for (index in 0 until values.length()) {
            val value = values.getJSONObject(index)
            val operation = value.getString("operation")
            require(operation in supported) {
                "Unsupported reader progress operation: $operation"
            }
            val arguments = value.getJSONObject("arguments")
            val stimulus = JSONObject()
                .put("operation", operation)
                .put("arguments", JSONObject(arguments.toString()))
            runCase(value.getString("id"), operation, stimulus) {
                readerProgressRuntimeProjection(operation, arguments)
            }
        }
    }

    private suspend fun readerProgressRuntimeProjection(
        operation: String,
        arguments: JSONObject
    ): JSONObject {
        clearProgressRuntimeState()
        val previousReadRecordEnabled = AppConfig.enableReadRecord
        AppConfig.enableReadRecord = false
        return try {
            when (operation) {
                "layout_set_page_index" ->
                    layoutSetPageIndexProjection(arguments)
                "layout_char_to_page" ->
                    layoutCharToPageProjection(arguments)
                "save_read_page_changed" ->
                    saveReadPageChangedProjection(arguments)
                "reset_progress" ->
                    resetProgressProjection(arguments)
                "audio_save_read" ->
                    audioSaveReadProjection(arguments)
                else -> error("Unsupported reader progress operation")
            }
        } finally {
            drainReadBookExecutor()
            AppConfig.enableReadRecord = previousReadRecordEnabled
            clearProgressRuntimeState()
        }
    }

    private fun layoutSetPageIndexProjection(
        arguments: JSONObject
    ): JSONObject {
        val book = progressBook(
            chapterIndex = 0,
            chapterPos = 0,
            chapterTitle = "既有标题"
        )
        seedProgressBook(book)
        ReadBook.resetData(book)
        ReadBook.curTextChapter = textChapter(arguments, book, 0)
        val requestedPageIndex = arguments.getInt("page_index")
        ReadBook.setPageIndex(requestedPageIndex)
        drainReadBookExecutor()
        val persisted = requireNotNull(appDb.bookDao.getBook(book.bookUrl))
        return JSONObject()
            .put("requested_page_index", requestedPageIndex)
            .put("runtime_char_position", ReadBook.durChapterPos)
            .put("runtime_page_index", ReadBook.durPageIndex)
            .put("persisted_chapter_index", persisted.durChapterIndex)
            .put("persisted_char_position", persisted.durChapterPos)
            .put("persisted_chapter_title", persisted.durChapterTitle)
    }

    private fun layoutCharToPageProjection(
        arguments: JSONObject
    ): JSONObject {
        val chapter = textChapter(
            arguments,
            progressBook(),
            chapterIndex = 0
        )
        val values = arguments.getJSONArray("char_indices")
        return JSONObject()
            .put("layout_completed", chapter.isCompleted)
            .put(
                "mappings",
                JSONArray().apply {
                    for (index in 0 until values.length()) {
                        val charIndex = values.getInt(index)
                        put(
                            JSONObject()
                                .put("char_index", charIndex)
                                .put(
                                    "page_index",
                                    chapter.getPageIndexByCharIndex(charIndex)
                                )
                        )
                    }
                }
            )
    }

    private fun saveReadPageChangedProjection(
        arguments: JSONObject
    ): JSONObject {
        val book = progressBook(
            chapterIndex = arguments.getInt("stored_chapter_index"),
            chapterPos = 5,
            chapterTitle = "既有标题"
        )
        seedProgressBook(book)
        ReadBook.resetData(book)
        ReadBook.durChapterIndex =
            arguments.getInt("runtime_chapter_index")
        ReadBook.durChapterPos =
            arguments.getInt("runtime_chapter_pos")
        val pageChanged = arguments.getBoolean("page_changed")
        ReadBook.saveRead(pageChanged)
        drainReadBookExecutor()
        val persisted = requireNotNull(appDb.bookDao.getBook(book.bookUrl))
        return JSONObject()
            .put("page_changed", pageChanged)
            .put("persisted_chapter_index", persisted.durChapterIndex)
            .put("persisted_char_position", persisted.durChapterPos)
            .put("persisted_chapter_title", persisted.durChapterTitle)
            .put("last_check_count", persisted.lastCheckCount)
            .put("timestamp_was_refreshed", persisted.durChapterTime > 1L)
    }

    private fun resetProgressProjection(
        arguments: JSONObject
    ): JSONObject {
        val book = progressBook(
            chapterIndex = arguments.getInt("stored_chapter_index"),
            chapterPos = arguments.getInt("stored_chapter_pos"),
            chapterTitle = "既有标题"
        )
        seedProgressBook(book)
        ReadBook.resetData(book)
        val persisted = requireNotNull(appDb.bookDao.getBook(book.bookUrl))
        return JSONObject()
            .put("chapter_size", ReadBook.chapterSize)
            .put("runtime_chapter_index", ReadBook.durChapterIndex)
            .put("runtime_char_position", ReadBook.durChapterPos)
            .put("persisted_chapter_index", persisted.durChapterIndex)
            .put("persisted_char_position", persisted.durChapterPos)
    }

    private suspend fun audioSaveReadProjection(
        arguments: JSONObject
    ): JSONObject {
        val book = progressBook(
            chapterIndex = arguments.getInt("stored_chapter_index"),
            chapterPos = arguments.getInt("stored_chapter_pos"),
            chapterTitle = "既有标题"
        )
        seedProgressBook(book)
        AudioPlay.book = book
        AudioPlay.saveRead()
        val persisted = withTimeout(5_000) {
            while (true) {
                val current = appDb.bookDao.getBook(book.bookUrl)
                if (
                    current?.durChapterTitle == "第二章" &&
                    current.lastCheckCount == 0
                ) {
                    return@withTimeout current
                }
                delay(10)
            }
            error("unreachable")
        }
        return JSONObject()
            .put("persisted_chapter_index", persisted.durChapterIndex)
            .put("persisted_char_position", persisted.durChapterPos)
            .put("persisted_chapter_title", persisted.durChapterTitle)
            .put("last_check_count", persisted.lastCheckCount)
            .put("timestamp_was_refreshed", persisted.durChapterTime > 1L)
    }

    private fun progressBook(
        chapterIndex: Int = 0,
        chapterPos: Int = 0,
        chapterTitle: String = "既有标题"
    ): Book = Book(
        bookUrl = "/android-runtime/reader-progress/book.txt",
        originName = "RuntimeLab",
        name = "RuntimeLab 阅读进度",
        author = "RuntimeLab",
        totalChapterNum = 3,
        durChapterTitle = chapterTitle,
        durChapterIndex = chapterIndex,
        durChapterPos = chapterPos,
        durChapterTime = 1L,
        lastCheckCount = 7
    )

    private fun seedProgressBook(book: Book) {
        appDb.bookDao.insert(book)
        val titles = listOf("第一章", "第二章", "第三章")
        appDb.bookChapterDao.insert(
            *titles.mapIndexed { index, title ->
                BookChapter(
                    url = "/android-runtime/reader-progress/$index",
                    title = title,
                    bookUrl = book.bookUrl,
                    index = index
                )
            }.toTypedArray()
        )
    }

    private fun textChapter(
        arguments: JSONObject,
        book: Book,
        chapterIndex: Int
    ): TextChapter {
        val starts = arguments.getJSONArray("page_starts")
        val texts = arguments.getJSONArray("page_texts")
        require(starts.length() == texts.length() && starts.length() > 0)
        val chapter = TextChapter(
            chapter = BookChapter(
                url = "/android-runtime/reader-progress/$chapterIndex",
                title = "第${chapterIndex + 1}章",
                bookUrl = book.bookUrl,
                index = chapterIndex
            ),
            position = chapterIndex,
            title = "第${chapterIndex + 1}章",
            chaptersSize = 3,
            sameTitleRemoved = false,
            isVip = false,
            isPay = false,
            effectiveReplaceRules = null
        )
        val field = TextChapter::class.java.getDeclaredField("textPages")
        field.isAccessible = true
        @Suppress("UNCHECKED_CAST")
        val pages = field.get(chapter) as ArrayList<TextPage>
        for (index in 0 until starts.length()) {
            val text = texts.getString(index)
            val page = TextPage(
                index = index,
                text = text,
                title = chapter.title,
                chapterSize = 3,
                chapterIndex = chapterIndex
            )
            page.addLine(
                TextLine(
                    text = text,
                    chapterPosition = starts.getInt(index)
                )
            )
            page.textChapter = chapter
            pages.add(page)
        }
        chapter.isCompleted = arguments.getBoolean("layout_completed")
        return chapter
    }

    private fun clearProgressRuntimeState() {
        drainReadBookExecutor()
        AudioPlay.book = null
        AudioPlay.durChapter = null
        ReadBook.book = null
        ReadBook.prevTextChapter = null
        ReadBook.curTextChapter = null
        ReadBook.nextTextChapter = null
        clearReadRecords()
        appDb.bookDao.all
            .filter {
                it.bookUrl.startsWith(
                    "/android-runtime/reader-progress/"
                )
            }
            .forEach {
                appDb.bookChapterDao.delByBook(it.bookUrl)
                appDb.bookDao.delete(it)
            }
    }

    private suspend fun runReaderProgressTocRemapCases() {
        val values = input.getJSONArray("cases")
        for (index in 0 until values.length()) {
            val value = values.getJSONObject(index)
            require(
                value.getString("operation") ==
                    "reader_progress_toc_remap"
            ) {
                "Unsupported reader progress TOC remap operation"
            }
            val arguments = value.getJSONObject("arguments")
            val stimulus = JSONObject()
                .put("operation", "reader_progress_toc_remap")
                .put("arguments", JSONObject(arguments.toString()))
            runCase(
                value.getString("id"),
                "reader_progress_toc_remap",
                stimulus
            ) {
                readerProgressTocRemapProjection(arguments)
            }
        }
    }

    private suspend fun runAppStartupCases() {
        val values = input.getJSONArray("cases")
        for (index in 0 until values.length()) {
            val value = values.getJSONObject(index)
            val operation = value.getString("operation")
            require(
                operation == "app_startup_welcome" ||
                    operation == "app_startup_main_pipeline"
            ) {
                "Unsupported app startup operation"
            }
            val arguments = value.getJSONObject("arguments")
            val stimulus = JSONObject()
                .put("operation", operation)
                .put("arguments", JSONObject(arguments.toString()))
            runCase(value.getString("id"), operation, stimulus) {
                when (operation) {
                    "app_startup_welcome" ->
                        welcomeStartupProjection(arguments)
                    else ->
                        mainStartupProjection(arguments)
                }
            }
        }
    }

    private suspend fun welcomeStartupProjection(
        arguments: JSONObject
    ): JSONObject {
        prepareStableMainStartup()
        val target = InstrumentationRegistry.getInstrumentation().targetContext
        target.putPrefBoolean(
            PreferKey.defaultToRead,
            arguments.getBoolean("default_to_read")
        )
        val instrumentation =
            InstrumentationRegistry.getInstrumentation()
        val startMonitor = StartupIntentMonitor(target.packageName)
        instrumentation.addMonitor(startMonitor)
        val scenario = ActivityScenario.launch<WelcomeActivity>(
            Intent(target, WelcomeActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        )
        try {
            waitForStartupCondition("main-start-dispatched") {
                startMonitor.wasDispatched(MainActivity::class.java)
            }
            val expectsReader =
                arguments.getBoolean("default_to_read")
            if (expectsReader) {
                waitForStartupCondition("reader-start-dispatched") {
                    startMonitor.wasDispatched(
                        ReadBookActivity::class.java
                    )
                }
                waitForStartupCondition("reader-observed") {
                    isTargetActivityPresent(ReadBookActivity::class.java)
                }
            }
            waitForStartupCondition("welcome-destroyed") {
                scenario.state == Lifecycle.State.DESTROYED
            }
            instrumentation.waitForIdleSync()
            val downstreamSequence = startMonitor.downstreamSequence()
            val mainIndex = downstreamSequence.indexOf(
                MainActivity::class.java.simpleName
            )
            val readerIndex = downstreamSequence.indexOf(
                ReadBookActivity::class.java.simpleName
            )
            require(mainIndex >= 0) {
                "MainActivity start dispatch was not recorded"
            }
            require(
                if (expectsReader) {
                    readerIndex > mainIndex
                } else {
                    readerIndex < 0
                }
            ) {
                "Downstream start order did not match defaultToRead"
            }
            val readerStarted =
                startMonitor.wasDispatched(ReadBookActivity::class.java)
            return JSONObject()
                .put(
                    "downstream_start_sequence",
                    JSONArray(downstreamSequence)
                )
                .put("main_started", true)
                .put("reader_started", readerStarted)
                .put(
                    "reader_activity_observed",
                    isTargetActivityPresent(ReadBookActivity::class.java)
                )
                .put("welcome_destroyed", true)
        } finally {
            if (scenario.state != Lifecycle.State.DESTROYED) {
                scenario.close()
            }
            instrumentation.removeMonitor(startMonitor)
            finishTargetActivities()
            target.putPrefBoolean(PreferKey.defaultToRead, false)
        }
    }

    private suspend fun waitForStartupCondition(
        label: String,
        timeoutMillis: Long = 5_000,
        condition: () -> Boolean
    ) {
        val deadline = SystemClock.elapsedRealtime() + timeoutMillis
        while (!condition()) {
            check(SystemClock.elapsedRealtime() < deadline) {
                "Startup condition timed out: $label"
            }
            delay(20)
        }
    }

    private fun isTargetActivityPresent(
        activityClass: Class<out Activity>
    ): Boolean =
        currentTargetActivities().any { activityClass.isInstance(it) }

    private class StartupIntentMonitor(
        private val packageName: String
    ) : Instrumentation.ActivityMonitor() {
        private val dispatchedClassNames = mutableListOf<String>()

        override fun onStartActivity(
            intent: Intent
        ): Instrumentation.ActivityResult? {
            val component = intent.component
            if (component?.packageName == packageName) {
                synchronized(this) {
                    dispatchedClassNames.add(
                        component.className.substringAfterLast('.')
                    )
                }
            }
            return null
        }

        fun wasDispatched(
            activityClass: Class<out Activity>
        ): Boolean = synchronized(this) {
            dispatchedClassNames.contains(activityClass.simpleName)
        }

        fun downstreamSequence(): List<String> =
            synchronized(this) {
                dispatchedClassNames.filter {
                    it == MainActivity::class.java.simpleName ||
                        it == ReadBookActivity::class.java.simpleName
                }
            }
    }

    private fun currentTargetActivities(): List<Activity> {
        val result = AtomicReference<List<Activity>>(emptyList())
        InstrumentationRegistry.getInstrumentation().runOnMainSync {
            val monitor = ActivityLifecycleMonitorRegistry.getInstance()
            result.set(
                listOf(
                    Stage.CREATED,
                    Stage.STARTED,
                    Stage.RESUMED,
                    Stage.PAUSED,
                    Stage.STOPPED
                ).flatMap { stage ->
                    monitor.getActivitiesInStage(stage)
                }.distinct()
            )
        }
        return result.get()
    }

    private suspend fun finishTargetActivities() {
        val requested = mutableSetOf<Activity>()
        withTimeout(10_000) {
            while (true) {
                val snapshot = currentTargetActivities()
                if (snapshot.isEmpty()) {
                    break
                }
                val pending = snapshot.filterNot {
                    it in requested || it.isFinishing || it.isDestroyed
                }
                requested.addAll(pending)
                InstrumentationRegistry.getInstrumentation()
                    .runOnMainSync {
                        pending.asReversed()
                            .forEach(Activity::finishAndRemoveTask)
                    }
                delay(50)
            }
        }
        InstrumentationRegistry.getInstrumentation().waitForIdleSync()
    }

    private suspend fun mainStartupProjection(
        arguments: JSONObject
    ): JSONObject {
        val target = InstrumentationRegistry.getInstrumentation().targetContext
        resetStartupPreferences(target)
        val local = target.getSharedPreferences(
            "local",
            Context.MODE_PRIVATE
        )
        local.edit()
            .putBoolean(
                "privacyPolicyOk",
                arguments.getString("privacy_state") == "accepted"
            )
            .putLong(
                "appVersionCode",
                when (arguments.getString("stored_version")) {
                    "current" -> appInfo.versionCode
                    "previous" -> maxOf(0L, appInfo.versionCode - 1L)
                    else -> 0L
                }
            )
            .putBoolean("firstOpen", arguments.getBoolean("first_open"))
            .putBoolean("appCrash", arguments.getBoolean("app_crash"))
            .apply {
                when (arguments.getString("password_state")) {
                    "empty" -> putString("password", "")
                    "nonempty" -> putString("password", "oracle-secret")
                    else -> remove("password")
                }
            }
            .commit()

        val dialogs = JSONArray()
        val scenario = ActivityScenario.launch<MainActivity>(
            Intent(target, MainActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        )
        var activity: MainActivity? = null
        scenario.onActivity { activity = it }
        try {
            if (arguments.optString("privacy_action") == "refuse") {
                waitForText(R.string.refuse)
                dialogs.put("privacy")
                onView(withText(R.string.refuse)).perform(click())
            } else if (arguments.optString("privacy_action") == "agree") {
                waitForText(R.string.agree)
                dialogs.put("privacy")
                onView(withText(R.string.agree)).perform(click())
            }

            if (
                arguments.getBoolean("first_open") &&
                arguments.optString("privacy_action") != "refuse"
            ) {
                val main = requireNotNull(activity)
                waitForTextDialog(main)
                dialogs.put("help")
                onView(withId(R.id.menu_close)).perform(click())
            }
            if (
                arguments.getString("password_state") == "unset" &&
                arguments.optString("privacy_action") != "refuse"
            ) {
                waitForText(android.R.string.cancel)
                dialogs.put("local_password")
                onView(withText(android.R.string.cancel)).perform(click())
            }

            delay(350)
            InstrumentationRegistry.getInstrumentation().waitForIdleSync()
            val main = requireNotNull(activity)
            return JSONObject()
                .put("build_debug", BuildConfig.DEBUG)
                .put("dialog_sequence", dialogs)
                .put("activity_finishing", main.isFinishing)
                .put("privacy_accepted", LocalConfig.privacyPolicyOk)
                .put(
                    "version_matches_current",
                    LocalConfig.versionCode == appInfo.versionCode
                )
                .put(
                    "first_open_after",
                    local.getBoolean("firstOpen", true)
                )
                .put(
                    "password_state_after",
                    when (LocalConfig.password) {
                        null -> "unset"
                        "" -> "empty"
                        else -> "nonempty"
                    }
                )
                .put("app_crash_after", LocalConfig.appCrash)
                .put("last_backup_after", LocalConfig.lastBackup)
                .put(
                    "help_dialog_remaining",
                    hasTextDialog(main)
                )
                .put(
                    "update_log_visible",
                    isTextVisible(R.string.update_log)
                )
        } finally {
            scenario.close()
            resetStartupPreferences(target)
        }
    }

    private fun prepareStableMainStartup() {
        val target = InstrumentationRegistry.getInstrumentation().targetContext
        resetStartupPreferences(target)
        val local = target.getSharedPreferences(
            "local",
            Context.MODE_PRIVATE
        )
        local.edit()
            .putBoolean("privacyPolicyOk", true)
            .putLong("appVersionCode", appInfo.versionCode)
            .putBoolean("firstOpen", false)
            .putString("password", "")
            .putBoolean("appCrash", false)
            .commit()
    }

    private fun resetStartupPreferences(target: Context) {
        target.getSharedPreferences("local", Context.MODE_PRIVATE)
            .edit()
            .clear()
            .commit()
        target.defaultSharedPreferences.edit()
            .remove(PreferKey.defaultToRead)
            .remove(PreferKey.webDavAccount)
            .remove(PreferKey.webDavPassword)
            .remove(PreferKey.autoRefresh)
            .commit()
    }

    private suspend fun waitForText(resourceId: Int) {
        withTimeout(5_000) {
            while (!isTextVisible(resourceId)) {
                delay(20)
            }
        }
    }

    private suspend fun waitForTextDialog(activity: MainActivity) {
        withTimeout(5_000) {
            while (!hasTextDialog(activity)) {
                delay(20)
            }
        }
    }

    private fun hasTextDialog(activity: MainActivity): Boolean {
        val present = AtomicBoolean(false)
        InstrumentationRegistry.getInstrumentation().runOnMainSync {
            val fragmentManager = activity.supportFragmentManager
            if (!activity.isDestroyed && !fragmentManager.isDestroyed) {
                fragmentManager.executePendingTransactions()
                present.set(
                    fragmentManager.fragments.any {
                        it is TextDialog && it.isAdded
                    }
                )
            }
        }
        return present.get()
    }

    private fun isTextVisible(resourceId: Int): Boolean =
        try {
            onView(withText(resourceId)).check { view, error ->
                if (error != null || view == null || !view.isShown) {
                    throw AssertionError("Text is not visible")
                }
            }
            true
        } catch (_: Throwable) {
            false
        }

    private fun readerProgressTocRemapProjection(
        arguments: JSONObject
    ): JSONObject {
        val titles = arguments.getJSONArray("new_titles")
        val chapters = ArrayList<BookChapter>(titles.length())
        for (index in 0 until titles.length()) {
            chapters.add(
                BookChapter(
                    url = "/android-runtime/toc-remap/$index",
                    title = titles.getString(index),
                    bookUrl = "/android-runtime/toc-remap/book",
                    index = index
                )
            )
        }
        val oldTitle =
            if (arguments.isNull("old_title")) null
            else arguments.getString("old_title")
        val selectedIndex = BookHelp.getDurChapter(
            arguments.getInt("old_index"),
            oldTitle,
            chapters,
            arguments.getInt("old_list_size")
        )
        val inBounds = selectedIndex in chapters.indices
        return JSONObject()
            .put("selected_index", selectedIndex)
            .put("selected_index_in_bounds", inBounds)
            .put(
                "selected_title",
                if (inBounds) chapters[selectedIndex].title
                else JSONObject.NULL
            )
            .put("new_chapter_count", chapters.size)
    }

    private suspend fun runReaderPrefetchPolicyCases() {
        val values = input.getJSONArray("cases")
        for (index in 0 until values.length()) {
            val value = values.getJSONObject(index)
            require(
                value.getString("operation") == "reader_prefetch_policy"
            ) {
                "Unsupported reader prefetch operation"
            }
            val arguments = value.getJSONObject("arguments")
            val stimulus = JSONObject()
                .put("operation", "reader_prefetch_policy")
                .put("arguments", JSONObject(arguments.toString()))
            runCase(
                value.getString("id"),
                "reader_prefetch_policy",
                stimulus
            ) {
                readerPrefetchPolicyProjection(
                    value.getString("id"),
                    arguments
                )
            }
        }
    }

    private suspend fun readerPrefetchPolicyProjection(
        caseId: String,
        arguments: JSONObject
    ): JSONObject {
        clearPrefetchRuntimeState()
        val previousPreDownloadNum = AppConfig.preDownloadNum
        val book = prefetchBook(caseId, arguments)
        return try {
            seedPrefetchBook(book, arguments)
            ReadBook.resetData(book)
            ReadBook.durChapterIndex =
                arguments.getInt("current_chapter")
            ReadBook.downloadedChapters.addAll(
                jsonInts(arguments.getJSONArray("pre_downloaded_indices"))
            )
            val failureCounts = arguments.getJSONArray("failure_counts")
            for (index in 0 until failureCounts.length()) {
                val value = failureCounts.getJSONObject(index)
                ReadBook.downloadFailChapters[value.getInt("index")] =
                    value.getInt("count")
            }
            AppConfig.preDownloadNum =
                arguments.getInt("pre_download_num")
            when (arguments.getString("mode")) {
                "settled" -> settledPrefetchProjection()
                "observe_workers" -> prefetchWorkersProjection()
                "replace_job" -> replacementPrefetchProjection(arguments)
                else -> error("Unsupported reader prefetch mode")
            }
        } finally {
            AppConfig.preDownloadNum = previousPreDownloadNum
            clearPrefetchRuntimeState()
        }
    }

    private suspend fun settledPrefetchProjection(): JSONObject {
        invokePreDownload()
        val task = ReadBook.preDownloadTask
        if (task != null) {
            withTimeout(5_000) {
                while (!task.isCompleted) {
                    delay(10)
                }
            }
        }
        return JSONObject()
            .put("task_created", task != null)
            .put("task_completed", task?.isCompleted == true)
            .put(
                "downloaded_indices",
                intProjection(ReadBook.downloadedChapters)
            )
            .put(
                "failure_counts",
                failureCountProjection()
            )
            .put(
                "loading_indices",
                intProjection(prefetchLoadingIndices())
            )
    }

    private suspend fun prefetchWorkersProjection(): JSONObject {
        invokePreDownload()
        val task = requireNotNull(ReadBook.preDownloadTask)
        val expectedFirstIndices = listOf(
            ReadBook.durChapterIndex - 2,
            ReadBook.durChapterIndex + 2
        ).sorted()
        withTimeout(900) {
            while (
                !prefetchLoadingIndices().containsAll(expectedFirstIndices)
            ) {
                delay(5)
            }
        }
        val loading = prefetchLoadingIndices()
        val childCount = task.children.count()
        task.cancel()
        return JSONObject()
            .put("task_created", true)
            .put("child_job_count", childCount)
            .put(
                "initial_loading_indices",
                intProjection(loading)
            )
            .put(
                "directions_started",
                loading.containsAll(expectedFirstIndices)
            )
    }

    private suspend fun replacementPrefetchProjection(
        arguments: JSONObject
    ): JSONObject {
        invokePreDownload()
        val first = requireNotNull(ReadBook.preDownloadTask)
        val expectedFirstIndices = listOf(
            ReadBook.durChapterIndex - 2,
            ReadBook.durChapterIndex + 2
        )
        withTimeout(900) {
            while (
                !prefetchLoadingIndices().containsAll(expectedFirstIndices)
            ) {
                delay(5)
            }
        }
        ReadBook.durChapterIndex =
            arguments.getInt("replacement_current_chapter")
        invokePreDownload()
        val replacement = requireNotNull(ReadBook.preDownloadTask)
        withTimeout(900) {
            while (!first.isCancelled) {
                delay(5)
            }
        }
        replacement.cancel()
        return JSONObject()
            .put("first_task_cancelled", first.isCancelled)
            .put("replacement_task_created", true)
            .put("task_identity_changed", replacement !== first)
            .put(
                "replacement_current_chapter",
                ReadBook.durChapterIndex
            )
    }

    private fun invokePreDownload() {
        val method = ReadBook::class.java.getDeclaredMethod("preDownload")
        method.isAccessible = true
        method.invoke(ReadBook)
        drainReadBookExecutor()
    }

    private fun prefetchBook(
        caseId: String,
        arguments: JSONObject
    ): Book = Book(
        bookUrl = "/android-runtime/reader-prefetch/$caseId.txt",
        origin = if (arguments.getBoolean("local_book")) {
            "loc_book"
        } else {
            "runtime-prefetch-source"
        },
        originName = "RuntimeLab",
        name = "RuntimeLab 预取 $caseId",
        author = "RuntimeLab",
        type = if (arguments.getBoolean("local_book")) {
            BookType.local
        } else {
            BookType.text
        },
        totalChapterNum = arguments.getInt("chapter_size"),
        durChapterIndex = arguments.getInt("current_chapter")
    )

    private fun seedPrefetchBook(
        book: Book,
        arguments: JSONObject
    ) {
        BookHelp.clearCache(book)
        appDb.bookChapterDao.delByBook(book.bookUrl)
        appDb.bookDao.getBook(book.bookUrl)?.let {
            appDb.bookDao.delete(it)
        }
        appDb.bookDao.insert(book)
        val chapterSize = arguments.getInt("chapter_size")
        val chapters = (0 until chapterSize).map { index ->
            BookChapter(
                url = "/android-runtime/reader-prefetch/chapter/$index",
                title = "第${index + 1}章",
                bookUrl = book.bookUrl,
                index = index
            )
        }
        appDb.bookChapterDao.insert(*chapters.toTypedArray())
        val cached = jsonInts(arguments.getJSONArray("cached_indices")).toSet()
        chapters
            .filter { it.index in cached }
            .forEach {
                BookHelp.saveText(book, it, "cached-${it.index}")
            }
    }

    private suspend fun clearPrefetchRuntimeState() {
        val task = ReadBook.preDownloadTask
        task?.cancel()
        ReadBook.downloadScope.coroutineContext.cancelChildren()
        if (task != null) {
            withTimeout(5_000) {
                while (!task.isCompleted) {
                    delay(10)
                }
            }
        }
        drainReadBookExecutor()
        ReadBook.preDownloadTask = null
        ReadBook.downloadedChapters.clear()
        ReadBook.downloadFailChapters.clear()
        synchronized(ReadBook) {
            prefetchLoadingList().clear()
        }
        ReadBook.book = null
        appDb.bookDao.all
            .filter {
                it.bookUrl.startsWith(
                    "/android-runtime/reader-prefetch/"
                )
            }
            .forEach {
                BookHelp.clearCache(it)
                appDb.bookChapterDao.delByBook(it.bookUrl)
                appDb.bookDao.delete(it)
            }
    }

    private fun prefetchLoadingIndices(): List<Int> =
        synchronized(ReadBook) {
            prefetchLoadingList().toList().sorted()
        }

    @Suppress("UNCHECKED_CAST")
    private fun prefetchLoadingList(): ArrayList<Int> {
        val field = ReadBook::class.java.getDeclaredField(
            "loadingChapters"
        )
        field.isAccessible = true
        return field.get(ReadBook) as ArrayList<Int>
    }

    private fun jsonInts(values: JSONArray): List<Int> =
        (0 until values.length()).map(values::getInt)

    private fun intProjection(values: Collection<Int>): JSONArray =
        JSONArray().apply {
            values.toSortedSet().forEach { put(it) }
        }

    private fun failureCountProjection(): JSONArray =
        JSONArray().apply {
            ReadBook.downloadFailChapters
                .toSortedMap()
                .forEach { (index, count) ->
                    put(
                        JSONObject()
                            .put("index", index)
                            .put("count", count)
                    )
                }
        }

    private suspend fun runPostFormCases() {
        val values = input.getJSONArray("cases")
        for (index in 0 until values.length()) {
            val value = values.getJSONObject(index)
            require(value.getString("operation") == "search") {
                "POST form scenario only accepts search stimuli"
            }
            val keyword = value
                .getJSONObject("arguments")
                .getString("keyword")
            runCase(
                value.getString("id"),
                "search",
                postSearchRequest(keyword)
            ) {
                searchProjection(
                    WebBook.searchBookAwait(source, keyword)
                )
            }
        }
    }

    private suspend fun runXmlResponseCases() {
        val values = input.getJSONArray("cases")
        for (index in 0 until values.length()) {
            val value = values.getJSONObject(index)
            require(value.getString("operation") == "raw_response") {
                "XML response scenario only accepts raw_response stimuli"
            }
            val target = value
                .getJSONObject("request")
                .getString("target")
            val analyze = AnalyzeUrl(
                mUrl = "$deviceOrigin$target",
                baseUrl = source.bookSourceUrl,
                source = source,
                headerMapF = source.getHeaderMap(true)
            )
            runCase(
                value.getString("id"),
                "raw_response",
                request(analyze.url)
            ) {
                val response = analyze.getStrResponseAwait(
                    useWebView = false
                )
                JSONObject()
                    .put("body", nullable(response.body))
                    .put("final_url", logical(response.url))
            }
        }
    }

    private suspend fun runResponseDecodingCases() {
        val values = input.getJSONArray("cases")
        for (index in 0 until values.length()) {
            val value = values.getJSONObject(index)
            require(value.getString("operation") == "response_decoding") {
                "Response decoding scenario only accepts response_decoding stimuli"
            }
            val target = value
                .getJSONObject("request")
                .getString("target")
            val analyze = AnalyzeUrl(
                mUrl = "$deviceOrigin$target",
                baseUrl = source.bookSourceUrl,
                source = source,
                headerMapF = source.getHeaderMap(true)
            )
            runCase(
                value.getString("id"),
                "response_decoding",
                analyzedRequest(analyze)
            ) {
                val response = analyze.getStrResponseAwait(
                    useWebView = false
                )
                JSONObject()
                    .put("body", nullable(response.body))
                    .put("final_url", logical(response.url))
                    .put("status_code", response.code())
                    .put("is_successful", response.isSuccessful())
            }
        }
    }

    private suspend fun runRetryRedirectCases() {
        val values = input.getJSONArray("cases")
        for (index in 0 until values.length()) {
            val value = values.getJSONObject(index)
            require(value.getString("operation") == "retry_redirect") {
                "Retry redirect scenario only accepts retry_redirect stimuli"
            }
            val id = value.getString("id")
            val record = JSONObject()
                .put("id", id)
                .put("operation", "retry_redirect")
            try {
                val (request, result) = when (
                    value.getJSONObject("arguments").getString("mode")
                ) {
                    "analyze_url" -> retryAnalyzeProjection(value)
                    "helper_status_sequence" ->
                        helperStatusSequenceProjection(value)
                    "helper_network_exception" ->
                        helperNetworkExceptionProjection(value)
                    "helper_cancellation" ->
                        helperCancellationProjection(value)
                    else -> error("Unsupported retry redirect mode")
                }
                requestPlan.put(request)
                record
                    .put("request", request)
                    .put("result", result)
                    .put("issue", JSONObject.NULL)
            } catch (error: Throwable) {
                val request = retryFallbackRequest(value)
                requestPlan.put(request)
                record
                    .put("request", request)
                    .put("result", JSONObject.NULL)
                    .put(
                        "issue",
                        JSONObject()
                            .put("code", "android_exception")
                            .put("exception_type", error.javaClass.name)
                    )
            }
            cases.put(record)
        }
    }

    private suspend fun runCookieSessionCases() {
        val values = input.getJSONArray("cases")
        for (index in 0 until values.length()) {
            val value = values.getJSONObject(index)
            require(value.getString("operation") == "cookie_session") {
                "Cookie session scenario only accepts cookie_session stimuli"
            }
            val id = value.getString("id")
            val record = JSONObject()
                .put("id", id)
                .put("operation", "cookie_session")
            try {
                val (request, result) = cookieSessionProjection(value)
                requestPlan.put(request)
                record
                    .put("request", request)
                    .put("result", result)
                    .put("issue", JSONObject.NULL)
            } catch (error: Throwable) {
                val request = cookieHelperRequest(value)
                requestPlan.put(request)
                record
                    .put("request", request)
                    .put("result", JSONObject.NULL)
                    .put(
                        "issue",
                        JSONObject()
                            .put("code", "android_exception")
                            .put("exception_type", error.javaClass.name)
                    )
            }
            cases.put(record)
        }
    }

    private suspend fun runDynamicWebCases() {
        val values = input.getJSONArray("cases")
        for (index in 0 until values.length()) {
            val value = values.getJSONObject(index)
            require(value.getString("operation") == "dynamic_web") {
                "Dynamic web scenario only accepts dynamic_web stimuli"
            }
            val id = value.getString("id")
            val record = JSONObject()
                .put("id", id)
                .put("operation", "dynamic_web")
            try {
                val (request, result) = dynamicWebProjection(value)
                requestPlan.put(request)
                record
                    .put("request", request)
                    .put("result", result)
                    .put("issue", JSONObject.NULL)
            } catch (error: Throwable) {
                val request = dynamicWebFallbackRequest(value)
                requestPlan.put(request)
                record
                    .put("request", request)
                    .put("result", JSONObject.NULL)
                    .put(
                        "issue",
                        JSONObject()
                            .put("code", "android_exception")
                            .put("exception_type", error.javaClass.name)
                    )
            }
            cases.put(record)
        }
    }

    private suspend fun runRuleVariableScopeCases() {
        val values = input.getJSONArray("cases")
        for (index in 0 until values.length()) {
            val value = values.getJSONObject(index)
            require(value.getString("operation") == "rule_variable_scope") {
                "Rule variable scenario only accepts rule_variable_scope stimuli"
            }
            val requestValue = value.getJSONObject("request")
            val request = request(
                deviceOrigin + requestValue.getString("target")
            )
            runCase(
                value.getString("id"),
                "rule_variable_scope",
                request
            ) {
                ruleVariableScopeProjection(value)
            }
        }
    }

    private suspend fun runRuleBackendDispatchCases() {
        val values = input.getJSONArray("cases")
        for (index in 0 until values.length()) {
            val value = values.getJSONObject(index)
            require(value.getString("operation") == "rule_backend_dispatch") {
                "Rule backend scenario only accepts rule_backend_dispatch stimuli"
            }
            val requestValue = value.getJSONObject("request")
            val request = request(
                deviceOrigin + requestValue.getString("target")
            )
            runCase(
                value.getString("id"),
                "rule_backend_dispatch",
                request
            ) {
                ruleBackendDispatchProjection(value.getJSONObject("arguments"))
            }
        }
    }

    private suspend fun runRuleCombinationCases() {
        val values = input.getJSONArray("cases")
        for (index in 0 until values.length()) {
            val value = values.getJSONObject(index)
            require(
                value.getString("operation") ==
                    "rule_combination_coercion"
            ) {
                "Rule combination scenario only accepts " +
                    "rule_combination_coercion stimuli"
            }
            val requestValue = value.getJSONObject("request")
            val request = request(
                deviceOrigin + requestValue.getString("target")
            )
            runCase(
                value.getString("id"),
                "rule_combination_coercion",
                request
            ) {
                ruleCombinationProjection(
                    value.getJSONObject("arguments")
                )
            }
        }
    }

    private suspend fun runDOMSelectorBackendCases() {
        val values = input.getJSONArray("cases")
        for (index in 0 until values.length()) {
            val value = values.getJSONObject(index)
            require(
                value.getString("operation") ==
                    "dom_selector_backends"
            ) {
                "DOM selector scenario only accepts " +
                    "dom_selector_backends stimuli"
            }
            val requestValue = value.getJSONObject("request")
            val request = request(
                deviceOrigin + requestValue.getString("target")
            )
            runCase(
                value.getString("id"),
                "dom_selector_backends",
                request
            ) {
                domSelectorProjection(
                    value.getJSONObject("arguments")
                )
            }
        }
    }

    private suspend fun runJSONPathRegexBackendCases() {
        val values = input.getJSONArray("cases")
        for (index in 0 until values.length()) {
            val value = values.getJSONObject(index)
            require(
                value.getString("operation") ==
                    "jsonpath_regex_backends"
            ) {
                "JSONPath/Regex scenario only accepts " +
                    "jsonpath_regex_backends stimuli"
            }
            val requestValue = value.getJSONObject("request")
            val request = request(
                deviceOrigin + requestValue.getString("target")
            )
            runCase(
                value.getString("id"),
                "jsonpath_regex_backends",
                request
            ) {
                jsonPathRegexProjection(
                    value.getJSONObject("arguments")
                )
            }
        }
    }

    private suspend fun runContentCacheQueueCompletionCases() {
        val values = input.getJSONArray("cases")
        for (index in 0 until values.length()) {
            val value = values.getJSONObject(index)
            require(
                value.getString("operation") ==
                    "content_cache_queue_completion"
            ) {
                "Content cache scenario only accepts " +
                    "content_cache_queue_completion stimuli"
            }
            val requestValue = value.getJSONObject("request")
            val request = request(
                deviceOrigin + requestValue.getString("target")
            )
            runCase(
                value.getString("id"),
                "content_cache_queue_completion",
                request
            ) {
                contentCacheQueueCompletionProjection(
                    value.getJSONObject("arguments")
                )
            }
        }
    }

    private fun contentCacheQueueCompletionProjection(
        arguments: JSONObject
    ): JSONObject = when (val mode = arguments.getString("mode")) {
        "content_presence" -> contentPresenceProjection(arguments)
        "text_cache_lifecycle" -> textCacheLifecycleProjection(arguments)
        "image_completion" -> imageCompletionProjection(arguments)
        "queue_range_stop_resume" ->
            queueRangeStopResumeProjection(arguments)
        "retry_budget" -> retryBudgetProjection(arguments)
        "success_cancel" -> successCancelProjection(arguments)
        "registry_cleanup" -> registryCleanupProjection(arguments)
        else -> error("Unsupported content cache mode: $mode")
    }

    private fun contentPresenceProjection(
        arguments: JSONObject
    ): JSONObject {
        val remote = cacheProbeBook(arguments)
        val chapter = cacheProbeChapter(arguments, remote)
        val local = Book(
            bookUrl = arguments.getString("book_url") + "/local",
            origin = "local",
            originName = arguments.getString("local_txt_name"),
            name = arguments.getString("book_name") + " Local"
        )
        val volumeTitle = arguments.getString("volume_title")
        val pseudoVolume = BookChapter(
            url = "$volumeTitle::marker",
            title = volumeTitle,
            isVolume = true,
            bookUrl = remote.bookUrl,
            index = 1
        )
        val ordinaryVolume = BookChapter(
            url = "/volume/ordinary",
            title = volumeTitle,
            isVolume = true,
            bookUrl = remote.bookUrl,
            index = 2
        )
        BookHelp.clearCache(remote)
        return try {
            JSONObject()
                .put(
                    "local_txt_without_file",
                    BookHelp.hasContent(local, chapter.copy(bookUrl = local.bookUrl))
                )
                .put(
                    "pseudo_volume_without_file",
                    BookHelp.hasContent(remote, pseudoVolume)
                )
                .put(
                    "ordinary_volume_without_file",
                    BookHelp.hasContent(remote, ordinaryVolume)
                )
                .put(
                    "remote_chapter_without_file",
                    BookHelp.hasContent(remote, chapter)
                )
        } finally {
            BookHelp.clearCache(remote)
        }
    }

    private fun textCacheLifecycleProjection(
        arguments: JSONObject
    ): JSONObject {
        val book = cacheProbeBook(arguments)
        val chapter = cacheProbeChapter(arguments, book)
        val content = arguments.getString("content")
        BookHelp.clearCache(book)
        return try {
            val before = BookHelp.hasContent(book, chapter)
            BookHelp.saveText(book, chapter, "")
            val afterEmpty = BookHelp.hasContent(book, chapter)
            BookHelp.saveText(book, chapter, content)
            val afterText = BookHelp.hasContent(book, chapter)
            val stored = BookHelp.getContent(book, chapter)
            val files = BookHelp.getChapterFiles(book).toList().sorted()
            BookHelp.delContent(book, chapter)
            JSONObject()
                .put("before_save", before)
                .put("after_empty_save", afterEmpty)
                .put("after_text_save", afterText)
                .put("stored_content", nullable(stored))
                .put("chapter_files", JSONArray(files))
                .put(
                    "expected_file_name",
                    chapter.getFileName()
                )
                .put(
                    "after_delete",
                    BookHelp.hasContent(book, chapter)
                )
        } finally {
            BookHelp.clearCache(book)
        }
    }

    private fun imageCompletionProjection(
        arguments: JSONObject
    ): JSONObject {
        val book = cacheProbeBook(arguments)
        val chapter = cacheProbeChapter(arguments, book)
        val missing = arguments.getString("missing_image_url")
        val valid = arguments.getString("valid_svg_url")
        BookHelp.clearCache(book)
        val invalidImage = BookHelp.getImage(book, missing)
        val validImage = BookHelp.getImage(book, valid)
        invalidImage.delete()
        validImage.delete()
        return try {
            val withoutText = BookHelp.hasImageContent(book, chapter)
            BookHelp.saveText(
                book,
                chapter,
                arguments.getString("plain_content")
            )
            val plainTextComplete = BookHelp.hasImageContent(book, chapter)
            BookHelp.saveText(
                book,
                chapter,
                "<p>text</p><img src=\"$missing\">"
            )
            val missingImageComplete = BookHelp.hasImageContent(book, chapter)
            invalidImage.parentFile?.mkdirs()
            invalidImage.writeText("not-an-image")
            val invalidImageComplete = BookHelp.hasImageContent(book, chapter)
            val invalidDeleted = !invalidImage.exists()
            BookHelp.saveText(
                book,
                chapter,
                "<p>text</p><img src=\"$valid\">"
            )
            validImage.parentFile?.mkdirs()
            validImage.writeText(arguments.getString("valid_svg"))
            val validSVGComplete = BookHelp.hasImageContent(book, chapter)
            JSONObject()
                .put("without_text", withoutText)
                .put("plain_text_complete", plainTextComplete)
                .put("text_file_present", BookHelp.hasContent(book, chapter))
                .put("missing_image_complete", missingImageComplete)
                .put("invalid_image_complete", invalidImageComplete)
                .put("invalid_image_deleted", invalidDeleted)
                .put("valid_svg_complete", validSVGComplete)
                .put("valid_svg_retained", validImage.exists())
        } finally {
            BookHelp.clearCache(book)
        }
    }

    private fun queueRangeStopResumeProjection(
        arguments: JSONObject
    ): JSONObject {
        resetCacheBookState()
        val book = cacheProbeBook(arguments)
        val model = CacheBook.CacheBookModel(source, book)
        return try {
            model.addDownload(
                arguments.getInt("first_start"),
                arguments.getInt("first_end")
            )
            model.addDownload(
                arguments.getInt("second_start"),
                arguments.getInt("second_end")
            )
            val beforeStop = cacheModelState(model)
            val registeredBeforeStop =
                CacheBook.cacheBookMap[book.bookUrl] === model
            model.stop()
            val afterStop = cacheModelState(model)
            val registeredAfterStop =
                CacheBook.cacheBookMap[book.bookUrl] === model
            model.addDownload(
                arguments.getInt("resume_index"),
                arguments.getInt("resume_index")
            )
            JSONObject()
                .put("before_stop", beforeStop)
                .put("registered_before_stop", registeredBeforeStop)
                .put("after_stop", afterStop)
                .put("registered_after_stop", registeredAfterStop)
                .put("after_resume", cacheModelState(model))
        } finally {
            resetCacheBookState()
        }
    }

    private fun retryBudgetProjection(
        arguments: JSONObject
    ): JSONObject {
        resetCacheBookState()
        return try {
            val ordinaryBook = cacheProbeBook(arguments)
            val ordinaryChapter = cacheProbeChapter(
                arguments,
                ordinaryBook,
                arguments.getInt("chapter_index")
            )
            val ordinaryModel = CacheBook.CacheBookModel(
                source,
                ordinaryBook
            )
            ordinaryModel.addDownload(
                ordinaryChapter.index,
                ordinaryChapter.index
            )
            val attempts = JSONArray()
            repeat(3) {
                beginCacheAttempt(ordinaryModel, ordinaryChapter.index)
                invokeCacheModel(
                    ordinaryModel,
                    "onPreError",
                    ordinaryChapter,
                    IOException("ordinary-${it + 1}")
                )
                val waitingDuringBackoff = cacheModelBoolean(
                    ordinaryModel,
                    "waitingRetry"
                )
                invokeCacheModel(
                    ordinaryModel,
                    "onPostError",
                    ordinaryChapter,
                    IOException("ordinary-${it + 1}")
                )
                attempts.put(
                    JSONObject()
                        .put("attempt", it + 1)
                        .put(
                            "error_count",
                            CacheBook.errorDownloadMap[
                                ordinaryChapter.primaryStr()
                            ] ?: 0
                        )
                        .put(
                            "waiting_during_backoff",
                            waitingDuringBackoff
                        )
                        .put(
                            "requeued",
                            cacheModelIndices(
                                ordinaryModel,
                                "waitDownloadSet"
                            ).contains(ordinaryChapter.index)
                        )
                )
            }

            val concurrentBook = ordinaryBook.copy(
                bookUrl = ordinaryBook.bookUrl + "/concurrent"
            )
            val concurrentChapter = ordinaryChapter.copy(
                bookUrl = concurrentBook.bookUrl,
                url = ordinaryChapter.url + "/concurrent",
                index = arguments.getInt("concurrent_index")
            )
            val concurrentModel = CacheBook.CacheBookModel(
                source,
                concurrentBook
            )
            concurrentModel.addDownload(
                concurrentChapter.index,
                concurrentChapter.index
            )
            beginCacheAttempt(concurrentModel, concurrentChapter.index)
            val concurrentError = ConcurrentException("busy", 1)
            invokeCacheModel(
                concurrentModel,
                "onPreError",
                concurrentChapter,
                concurrentError
            )
            invokeCacheModel(
                concurrentModel,
                "onPostError",
                concurrentChapter,
                concurrentError
            )

            val stoppedBook = ordinaryBook.copy(
                bookUrl = ordinaryBook.bookUrl + "/stopped"
            )
            val stoppedChapter = ordinaryChapter.copy(
                bookUrl = stoppedBook.bookUrl,
                url = ordinaryChapter.url + "/stopped",
                index = arguments.getInt("stopped_index")
            )
            val stoppedModel = CacheBook.CacheBookModel(source, stoppedBook)
            stoppedModel.addDownload(
                stoppedChapter.index,
                stoppedChapter.index
            )
            beginCacheAttempt(stoppedModel, stoppedChapter.index)
            val stoppedError = IOException("stopped")
            invokeCacheModel(
                stoppedModel,
                "onPreError",
                stoppedChapter,
                stoppedError
            )
            stoppedModel.stop()
            invokeCacheModel(
                stoppedModel,
                "onPostError",
                stoppedChapter,
                stoppedError
            )

            JSONObject()
                .put("ordinary_attempts", attempts)
                .put(
                    "ordinary_is_stop_after_budget",
                    ordinaryModel.isStop()
                )
                .put(
                    "concurrent_error_count",
                    CacheBook.errorDownloadMap[
                        concurrentChapter.primaryStr()
                    ] ?: 0
                )
                .put(
                    "concurrent_requeued",
                    cacheModelIndices(
                        concurrentModel,
                        "waitDownloadSet"
                    ).contains(concurrentChapter.index)
                )
                .put(
                    "stopped_error_count",
                    CacheBook.errorDownloadMap[
                        stoppedChapter.primaryStr()
                    ] ?: 0
                )
                .put(
                    "stopped_requeued",
                    cacheModelIndices(
                        stoppedModel,
                        "waitDownloadSet"
                    ).contains(stoppedChapter.index)
                )
                .put("stopped_is_stop", stoppedModel.isStop())
        } finally {
            resetCacheBookState()
        }
    }

    private fun successCancelProjection(
        arguments: JSONObject
    ): JSONObject {
        resetCacheBookState()
        return try {
            val book = cacheProbeBook(arguments)
            val baseChapter = cacheProbeChapter(arguments, book)
            val successChapter = baseChapter.copy(
                index = arguments.getInt("success_index")
            )
            val successModel = CacheBook.CacheBookModel(source, book)
            successModel.addDownload(
                successChapter.index,
                successChapter.index
            )
            beginCacheAttempt(successModel, successChapter.index)
            CacheBook.errorDownloadMap[successChapter.primaryStr()] = 2
            invokeCacheModel(successModel, "onSuccess", successChapter)

            val cancelBook = book.copy(bookUrl = book.bookUrl + "/cancel")
            val cancelChapter = baseChapter.copy(
                bookUrl = cancelBook.bookUrl,
                url = baseChapter.url + "/cancel",
                index = arguments.getInt("cancel_index")
            )
            val cancelModel = CacheBook.CacheBookModel(source, cancelBook)
            cancelModel.addDownload(
                cancelChapter.index,
                cancelChapter.index
            )
            beginCacheAttempt(cancelModel, cancelChapter.index)
            invokeCacheModel(cancelModel, "onCancel", cancelChapter.index)

            val stoppedBook = book.copy(bookUrl = book.bookUrl + "/stopped")
            val stoppedChapter = baseChapter.copy(
                bookUrl = stoppedBook.bookUrl,
                url = baseChapter.url + "/stopped",
                index = arguments.getInt("stopped_cancel_index")
            )
            val stoppedModel = CacheBook.CacheBookModel(source, stoppedBook)
            stoppedModel.addDownload(
                stoppedChapter.index,
                stoppedChapter.index
            )
            beginCacheAttempt(stoppedModel, stoppedChapter.index)
            stoppedModel.stop()
            invokeCacheModel(stoppedModel, "onCancel", stoppedChapter.index)

            JSONObject()
                .put(
                    "success_recorded",
                    CacheBook.successDownloadSet.contains(
                        successChapter.primaryStr()
                    )
                )
                .put(
                    "success_removed_prior_error",
                    !CacheBook.errorDownloadMap.containsKey(
                        successChapter.primaryStr()
                    )
                )
                .put(
                    "success_removed_on_download",
                    !cacheModelIndices(
                        successModel,
                        "onDownloadSet"
                    ).contains(successChapter.index)
                )
                .put(
                    "cancel_requeued",
                    cacheModelIndices(
                        cancelModel,
                        "waitDownloadSet"
                    ).contains(cancelChapter.index)
                )
                .put(
                    "stopped_cancel_requeued",
                    cacheModelIndices(
                        stoppedModel,
                        "waitDownloadSet"
                    ).contains(stoppedChapter.index)
                )
        } finally {
            resetCacheBookState()
        }
    }

    private fun registryCleanupProjection(
        arguments: JSONObject
    ): JSONObject {
        resetCacheBookState()
        val book = cacheProbeBook(arguments)
        val model = CacheBook.getOrCreate(source, book)
        val index = arguments.getInt("chapter_index")
        return try {
            model.addDownload(index, index)
            invokeCacheModel(model, "onFinally")
            val retainedWithWait =
                CacheBook.cacheBookMap[book.bookUrl] === model
            cacheModelIndices(model, "waitDownloadSet").clear()
            cacheModelIndices(model, "onDownloadSet").clear()
            setCacheModelBoolean(model, "waitingRetry", true)
            val isStopWithOnlyWaitingRetry = model.isStop()
            invokeCacheModel(model, "onFinally")
            JSONObject()
                .put("registered_initially", true)
                .put("registry_retained_with_wait", retainedWithWait)
                .put(
                    "is_stop_with_only_waiting_retry",
                    isStopWithOnlyWaitingRetry
                )
                .put(
                    "registry_removed_with_only_waiting_retry",
                    !CacheBook.cacheBookMap.containsKey(book.bookUrl)
                )
        } finally {
            resetCacheBookState()
        }
    }

    private fun cacheProbeBook(arguments: JSONObject): Book = Book(
        bookUrl = arguments.getString("book_url"),
        origin = source.bookSourceUrl,
        originName = source.bookSourceName,
        name = arguments.getString("book_name")
    )

    private fun cacheProbeChapter(
        arguments: JSONObject,
        book: Book,
        index: Int = arguments.optInt("chapter_index", 0)
    ): BookChapter = BookChapter(
        url = arguments.optString(
            "chapter_url",
            "/chapter/$index"
        ),
        title = arguments.optString(
            "chapter_title",
            "Chapter $index"
        ),
        bookUrl = book.bookUrl,
        index = index
    )

    private fun cacheModelState(
        model: CacheBook.CacheBookModel
    ): JSONObject = JSONObject()
        .put(
            "wait_indices",
            JSONArray(
                cacheModelIndices(model, "waitDownloadSet").toList()
            )
        )
        .put(
            "on_download_indices",
            JSONArray(
                cacheModelIndices(model, "onDownloadSet").toList()
            )
        )
        .put("wait_count", model.waitCount)
        .put("on_download_count", model.onDownloadCount)
        .put("is_run", model.isRun())
        .put("is_stop", model.isStop())

    @Suppress("UNCHECKED_CAST")
    private fun cacheModelIndices(
        model: CacheBook.CacheBookModel,
        name: String
    ): MutableSet<Int> = CacheBook.CacheBookModel::class.java
        .getDeclaredField(name)
        .apply { isAccessible = true }
        .get(model) as MutableSet<Int>

    private fun cacheModelBoolean(
        model: CacheBook.CacheBookModel,
        name: String
    ): Boolean = CacheBook.CacheBookModel::class.java
        .getDeclaredField(name)
        .apply { isAccessible = true }
        .getBoolean(model)

    private fun setCacheModelBoolean(
        model: CacheBook.CacheBookModel,
        name: String,
        value: Boolean
    ) {
        CacheBook.CacheBookModel::class.java
            .getDeclaredField(name)
            .apply { isAccessible = true }
            .setBoolean(model, value)
    }

    private fun beginCacheAttempt(
        model: CacheBook.CacheBookModel,
        index: Int
    ) {
        cacheModelIndices(model, "waitDownloadSet").remove(index)
        cacheModelIndices(model, "onDownloadSet").add(index)
    }

    private fun invokeCacheModel(
        model: CacheBook.CacheBookModel,
        name: String,
        vararg arguments: Any?
    ): Any? {
        val method = CacheBook.CacheBookModel::class.java.declaredMethods
            .single {
                it.name == name &&
                    it.parameterTypes.size == arguments.size
            }
            .apply { isAccessible = true }
        return try {
            method.invoke(model, *arguments)
        } catch (error: InvocationTargetException) {
            throw error.targetException
        }
    }

    private fun resetCacheBookState() {
        CacheBook.cacheBookMap.clear()
        CacheBook.clear()
    }

    private fun ruleBackendDispatchProjection(
        arguments: JSONObject
    ): JSONObject = when (val mode = arguments.getString("mode")) {
        "html_prefix_dispatch" -> htmlPrefixDispatchProjection(arguments)
        "json_content_dispatch" -> jsonContentDispatchProjection(arguments)
        "javascript_dispatch" -> javascriptDispatchProjection(arguments)
        "regex_stickiness" -> regexStickinessProjection(arguments)
        "parser_cache_lifecycle" -> parserCacheProjection(arguments)
        "native_object_access" -> nativeObjectProjection(arguments)
        "null_content" -> nullContentProjection()
        "foreign_content_isolation" ->
            foreignContentIsolationProjection(arguments)
        else -> error("Unsupported rule backend mode: $mode")
    }

    private fun ruleCombinationProjection(
        arguments: JSONObject
    ): JSONObject = when (val mode = arguments.getString("mode")) {
        "string_and_list" -> stringAndListProjection(arguments)
        "scalar_matrix" -> scalarCoercionProjection(arguments)
        "element_matrix" -> elementConsumerProjection(arguments)
        "sequential_chain" -> sequentialRuleProjection(arguments)
        "url_list" -> urlListProjection(arguments)
        "empty_matrix" -> emptyRuleProjection(arguments)
        "exception_boundary" -> ruleExceptionProjection(arguments)
        else -> error("Unsupported rule combination mode: $mode")
    }

    private fun domSelectorProjection(
        arguments: JSONObject
    ): JSONObject = when (val mode = arguments.getString("mode")) {
        "css_strings" -> cssStringProjection(arguments)
        "css_indexing" -> cssIndexProjection(arguments)
        "css_combinations" -> cssCombinationProjection(arguments)
        "css_url" -> cssURLProjection(arguments)
        "css_failure" -> cssFailureProjection(arguments)
        "xpath_strings" -> xpathStringProjection(arguments)
        "xpath_nodes" -> xpathNodeProjection(arguments)
        "xpath_fragments" -> xpathFragmentProjection(arguments)
        "xpath_namespace_functions" ->
            xpathNamespaceFunctionProjection(arguments)
        "xpath_failure" -> xpathFailureProjection(arguments)
        else -> error("Unsupported DOM selector mode: $mode")
    }

    private fun jsonPathRegexProjection(
        arguments: JSONObject
    ): JSONObject = when (val mode = arguments.getString("mode")) {
        "jsonpath_matrix" -> jsonPathMatrixProjection(
            arguments.getString("content"),
            arguments.getJSONObject("rules")
        )
        "jsonpath_object_input" -> jsonPathMatrixProjection(
            GSON.fromJson(
                arguments.getJSONObject("content_object").toString(),
                Any::class.java
            ),
            arguments.getJSONObject("rules")
        )
        "jsonpath_failure" -> jsonPathFailureProjection(arguments)
        "regex_capture" -> regexCaptureProjection(arguments)
        "regex_replacement" -> regexReplacementProjection(arguments)
        "regex_failure" -> regexFailureProjection(arguments)
        else -> error("Unsupported JSONPath/Regex mode: $mode")
    }

    private fun jsonPathMatrixProjection(
        content: Any,
        rules: JSONObject
    ): JSONObject = JSONObject().apply {
        val keys = rules.keys().asSequence().toList().sorted()
        keys.forEach { key ->
            val rule = rules.getString(key)
            put(
                key,
                JSONObject()
                    .put(
                        "string",
                        stringOutcome {
                            AnalyzeRule().setContent(content)
                                .getString(rule)
                        }
                    )
                    .put(
                        "list",
                        stringListOutcome {
                            AnalyzeRule().setContent(content)
                                .getStringList(rule)
                        }
                    )
                    .put(
                        "element",
                        anyOutcome {
                            AnalyzeRule().setContent(content)
                                .getElement(rule)
                        }
                    )
                    .put(
                        "elements",
                        anyOutcome {
                            AnalyzeRule().setContent(content)
                                .getElements(rule)
                        }
                    )
            )
        }
    }

    private fun jsonPathFailureProjection(
        arguments: JSONObject
    ): JSONObject {
        val rules = JSONObject()
            .put("missing", arguments.getString("missing_rule"))
            .put("null", arguments.getString("null_rule"))
            .put("malformed", arguments.getString("malformed_rule"))
        return jsonPathMatrixProjection(
            arguments.getString("content"),
            rules
        )
    }

    private fun regexCaptureProjection(
        arguments: JSONObject
    ): JSONObject {
        val content = arguments.getString("content")
        val rules = arguments.getJSONObject("rules")
        return JSONObject().apply {
            val keys = rules.keys().asSequence().toList().sorted()
            keys.forEach { key ->
                val rule = rules.getString(key)
                put(
                    key,
                    JSONObject()
                        .put(
                            "element",
                            anyOutcome {
                                AnalyzeRule().setContent(content)
                                    .getElement(rule)
                            }
                        )
                        .put(
                            "elements",
                            anyOutcome {
                                AnalyzeRule().setContent(content)
                                    .getElements(rule)
                            }
                        )
                )
            }
        }
    }

    private fun regexReplacementProjection(
        arguments: JSONObject
    ): JSONObject {
        val content = arguments.getString("content")
        val rules = arguments.getJSONObject("rules")
        return JSONObject().apply {
            val keys = rules.keys().asSequence().toList().sorted()
            keys.forEach { key ->
                val rule = rules.getString(key)
                put(
                    key,
                    JSONObject()
                        .put(
                            "string",
                            stringOutcome {
                                AnalyzeRule().setContent(content)
                                    .getString(rule)
                            }
                        )
                        .put(
                            "list",
                            stringListOutcome {
                                AnalyzeRule().setContent(content)
                                    .getStringList(rule)
                            }
                        )
                )
            }
        }
    }

    private fun regexFailureProjection(
        arguments: JSONObject
    ): JSONObject {
        val content = arguments.getString("content")
        val malformed = arguments.getString("malformed_capture_rule")
        val optional = arguments.getString("optional_single_rule")
        return JSONObject()
            .put(
                "malformed_capture",
                JSONObject()
                    .put(
                        "element",
                        anyOutcome {
                            AnalyzeRule().setContent(content)
                                .getElement(malformed)
                        }
                    )
                    .put(
                        "elements",
                        anyOutcome {
                            AnalyzeRule().setContent(content)
                                .getElements(malformed)
                        }
                    )
            )
            .put(
                "optional_single",
                anyOutcome {
                    AnalyzeRule().setContent(content)
                        .getElement(optional)
                }
            )
            .put(
                "invalid_replace_all",
                stringOutcome {
                    AnalyzeRule().setContent(content).getString(
                        arguments.getString("invalid_replace_all_rule")
                    )
                }
            )
            .put(
                "invalid_replace_first",
                stringOutcome {
                    AnalyzeRule().setContent(content).getString(
                        arguments.getString("invalid_replace_first_rule")
                    )
                }
            )
    }

    private fun anyOutcome(block: () -> Any?): JSONObject =
        runCatching(block).fold(
            onSuccess = { value ->
                JSONObject()
                    .put("completed", true)
                    .put("value", stableAny(value))
                    .put("exception_type", JSONObject.NULL)
            },
            onFailure = { error ->
                JSONObject()
                    .put("completed", false)
                    .put("value", JSONObject.NULL)
                    .put("exception_type", error.javaClass.name)
            }
        )

    private fun stableAny(value: Any?): Any = when (value) {
        null -> JSONObject.NULL
        is Map<*, *> -> JSONObject().apply {
            value.keys
                .map { it.toString() }
                .sorted()
                .forEach { key ->
                    put(key, stableAny(value[key]))
                }
        }
        is Iterable<*> -> JSONArray().apply {
            value.forEach { item -> put(stableAny(item)) }
        }
        is Array<*> -> JSONArray().apply {
            value.forEach { item -> put(stableAny(item)) }
        }
        is String, is Number, is Boolean -> value
        else -> JSONObject()
            .put("type", value.javaClass.name)
            .put("rendered", value.toString())
            .put("json", GSON.toJson(value))
    }

    private fun cssStringProjection(arguments: JSONObject): JSONObject =
        stringRuleMatrix(
            arguments.getString("content"),
            arguments.getJSONObject("rules")
        )

    private fun cssIndexProjection(arguments: JSONObject): JSONObject =
        stringRuleMatrix(
            arguments.getString("content"),
            arguments.getJSONObject("rules")
        )

    private fun cssCombinationProjection(
        arguments: JSONObject
    ): JSONObject = stringRuleMatrix(
        arguments.getString("content"),
        arguments.getJSONObject("rules")
    )

    private fun stringRuleMatrix(
        content: String,
        rules: JSONObject
    ): JSONObject = JSONObject().apply {
        val keys = rules.keys().asSequence().toList().sorted()
        keys.forEach { key ->
            val rule = rules.getString(key)
            put(
                key,
                JSONObject()
                    .put(
                        "string",
                        AnalyzeRule().setContent(content).getString(rule)
                    )
                    .put(
                        "list",
                        nullableStringList(
                            AnalyzeRule().setContent(content)
                                .getStringList(rule)
                        )
                    )
            )
        }
    }

    private fun cssURLProjection(arguments: JSONObject): JSONObject {
        val content = arguments.getString("content")
        val redirectURL = arguments.getString("redirect_url")
        val rules = arguments.getJSONObject("rules")
        return JSONObject().apply {
            val keys = rules.keys().asSequence().toList().sorted()
            keys.forEach { key ->
                val rule = rules.getString(key)
                put(
                    key,
                    JSONObject()
                        .put(
                            "raw_string",
                            AnalyzeRule().setContent(content)
                                .getString(rule)
                        )
                        .put(
                            "absolute_string",
                            urlAnalyzer(content, redirectURL)
                                .getString(rule, isUrl = true)
                        )
                        .put(
                            "raw_list",
                            nullableStringList(
                                AnalyzeRule().setContent(content)
                                    .getStringList(rule)
                            )
                        )
                        .put(
                            "absolute_list",
                            nullableStringList(
                                urlAnalyzer(content, redirectURL)
                                    .getStringList(rule, isUrl = true)
                            )
                        )
                )
            }
        }
    }

    private fun urlAnalyzer(
        content: String,
        redirectURL: String
    ): AnalyzeRule = AnalyzeRule()
        .setContent(content, redirectURL)
        .apply { setRedirectUrl(redirectURL) }

    private fun cssFailureProjection(arguments: JSONObject): JSONObject {
        val content = arguments.getString("content")
        val missing = arguments.getString("missing_rule")
        val missingElements = arguments.getString(
            "missing_elements_rule"
        )
        val malformed = arguments.getString("malformed_rule")
        return JSONObject()
            .put(
                "missing",
                JSONObject()
                    .put(
                        "string",
                        AnalyzeRule().setContent(content)
                            .getString(missing)
                    )
                    .put(
                        "list",
                        nullableStringList(
                            AnalyzeRule().setContent(content)
                                .getStringList(missing)
                        )
                    )
                    .put(
                        "elements_count",
                        AnalyzeRule().setContent(content)
                            .getElements(missingElements).size
                    )
            )
            .put(
                "malformed",
                JSONObject()
                    .put(
                        "string",
                        stringOutcome {
                            AnalyzeRule().setContent(content)
                                .getString(malformed)
                        }
                    )
                    .put(
                        "list",
                        stringListOutcome {
                            AnalyzeRule().setContent(content)
                                .getStringList(malformed)
                        }
                    )
                    .put(
                        "elements",
                        elementOutcome {
                            AnalyzeRule().setContent(content)
                                .getElements(malformed)
                        }
                    )
            )
    }

    private fun xpathStringProjection(
        arguments: JSONObject
    ): JSONObject = outcomeStringRuleMatrix(
        arguments.getString("content"),
        arguments.getJSONObject("rules")
    )

    private fun xpathNodeProjection(arguments: JSONObject): JSONObject {
        val content = arguments.getString("content")
        val rules = arguments.getJSONObject("rules")
        return JSONObject().apply {
            val keys = rules.keys().asSequence().toList().sorted()
            keys.forEach { key ->
                put(
                    key,
                    elementProjection(
                        AnalyzeRule().setContent(content)
                            .getElements(rules.getString(key))
                    )
                )
            }
        }
    }

    private fun xpathFragmentProjection(
        arguments: JSONObject
    ): JSONObject {
        val rules = arguments.getJSONObject("rules")
        return JSONObject()
            .put(
                "td",
                stringRuleMatrix(
                    arguments.getString("td_fragment"),
                    JSONObject().put("value", rules.getString("td"))
                ).getJSONObject("value")
            )
            .put(
                "tr",
                stringRuleMatrix(
                    arguments.getString("tr_fragment"),
                    JSONObject().put("value", rules.getString("tr"))
                ).getJSONObject("value")
            )
            .put(
                "malformed",
                stringRuleMatrix(
                    arguments.getString("malformed_html"),
                    JSONObject()
                        .put("value", rules.getString("malformed"))
                ).getJSONObject("value")
            )
    }

    private fun xpathNamespaceFunctionProjection(
        arguments: JSONObject
    ): JSONObject = outcomeStringRuleMatrix(
        arguments.getString("content"),
        arguments.getJSONObject("rules")
    )

    private fun outcomeStringRuleMatrix(
        content: String,
        rules: JSONObject
    ): JSONObject = JSONObject().apply {
        val keys = rules.keys().asSequence().toList().sorted()
        keys.forEach { key ->
            val rule = rules.getString(key)
            put(
                key,
                JSONObject()
                    .put(
                        "string",
                        stringOutcome {
                            AnalyzeRule().setContent(content)
                                .getString(rule)
                        }
                    )
                    .put(
                        "list",
                        stringListOutcome {
                            AnalyzeRule().setContent(content)
                                .getStringList(rule)
                        }
                    )
            )
        }
    }

    private fun xpathFailureProjection(arguments: JSONObject): JSONObject {
        val content = arguments.getString("content")
        val missing = arguments.getString("missing_rule")
        val malformed = arguments.getString("malformed_rule")
        return JSONObject()
            .put(
                "missing",
                JSONObject()
                    .put(
                        "string",
                        AnalyzeRule().setContent(content)
                            .getString(missing)
                    )
                    .put(
                        "list",
                        nullableStringList(
                            AnalyzeRule().setContent(content)
                                .getStringList(missing)
                        )
                    )
                    .put(
                        "elements",
                        elementProjection(
                            AnalyzeRule().setContent(content)
                                .getElements(missing)
                        )
                    )
            )
            .put(
                "malformed",
                JSONObject()
                    .put(
                        "string",
                        stringOutcome {
                            AnalyzeRule().setContent(content)
                                .getString(malformed)
                        }
                    )
                    .put(
                        "list",
                        stringListOutcome {
                            AnalyzeRule().setContent(content)
                                .getStringList(malformed)
                        }
                    )
                    .put(
                        "elements",
                        elementOutcome {
                            AnalyzeRule().setContent(content)
                                .getElements(malformed)
                        }
                    )
            )
    }

    private fun stringOutcome(block: () -> String): JSONObject =
        runCatching(block).fold(
            onSuccess = { value ->
                JSONObject()
                    .put("completed", true)
                    .put("value", value)
                    .put("exception_type", JSONObject.NULL)
            },
            onFailure = { error ->
                JSONObject()
                    .put("completed", false)
                    .put("value", JSONObject.NULL)
                    .put("exception_type", error.javaClass.name)
            }
        )

    private fun stringListOutcome(
        block: () -> List<String>?
    ): JSONObject = runCatching(block).fold(
        onSuccess = { value ->
            JSONObject()
                .put("completed", true)
                .put("value", nullableStringList(value))
                .put("exception_type", JSONObject.NULL)
        },
        onFailure = { error ->
            JSONObject()
                .put("completed", false)
                .put("value", JSONObject.NULL)
                .put("exception_type", error.javaClass.name)
        }
    )

    private fun elementOutcome(
        block: () -> List<Any>
    ): JSONObject = runCatching(block).fold(
        onSuccess = { value ->
            JSONObject()
                .put("completed", true)
                .put("value", elementProjection(value))
                .put("exception_type", JSONObject.NULL)
        },
        onFailure = { error ->
            JSONObject()
                .put("completed", false)
                .put("value", JSONObject.NULL)
                .put("exception_type", error.javaClass.name)
        }
    )

    private fun elementProjection(values: List<Any>): JSONArray =
        JSONArray().apply {
            values.forEach { value ->
                put(
                    when (value) {
                        is Element -> JSONObject()
                            .put("kind", "jsoup_element")
                            .put("tag", value.tagName())
                            .put("text", value.text())
                            .put("rendered", value.outerHtml())
                        is JXNode -> JSONObject()
                            .put(
                                "kind",
                                if (value.isElement) {
                                    "xpath_element"
                                } else {
                                    "xpath_value"
                                }
                            )
                            .put(
                                "tag",
                                if (value.isElement) {
                                    value.asElement().tagName()
                                } else {
                                    JSONObject.NULL
                                }
                            )
                            .put("as_string", value.asString())
                            .put("rendered", value.toString())
                        else -> JSONObject()
                            .put("kind", value.javaClass.name)
                            .put("rendered", value.toString())
                    }
                )
            }
        }

    private fun stringAndListProjection(
        arguments: JSONObject
    ): JSONObject {
        val content = arguments.getString("content")
        val rule = arguments.getString("rule")
        return JSONObject()
            .put(
                "string",
                AnalyzeRule().setContent(content).getString(rule)
            )
            .put(
                "list",
                nullableStringList(
                    AnalyzeRule().setContent(content)
                        .getStringList(rule)
                )
            )
    }

    private fun scalarCoercionProjection(
        arguments: JSONObject
    ): JSONObject {
        val content = arguments.getString("content")
        val rules = arguments.getJSONObject("rules")
        return JSONObject().put(
            "values",
            JSONArray().apply {
                listOf("number", "boolean", "null", "string")
                    .forEach { label ->
                        val rule = rules.getString(label)
                        put(
                            JSONObject()
                                .put("label", label)
                                .put(
                                    "string",
                                    AnalyzeRule()
                                        .setContent(content)
                                        .getString(rule)
                                )
                                .put(
                                    "list",
                                    nullableStringList(
                                        AnalyzeRule()
                                            .setContent(content)
                                            .getStringList(rule)
                                    )
                                )
                        )
                    }
            }
        )
    }

    private fun elementConsumerProjection(
        arguments: JSONObject
    ): JSONObject {
        val content = arguments.getString("content")
        val objectValue = AnalyzeRule().setContent(content)
            .getElement(arguments.getString("object_rule"))
        val elementsValue = AnalyzeRule().setContent(content)
            .getElements(arguments.getString("elements_rule"))
        val scalarValue = AnalyzeRule().setContent(content)
            .getElement(arguments.getString("scalar_rule"))
        return JSONObject()
            .put("object_type", nullable(objectValue?.javaClass?.name))
            .put("object_json", GSON.toJson(objectValue))
            .put("elements_count", elementsValue.size)
            .put("elements_json", GSON.toJson(elementsValue))
            .put("scalar_type", nullable(scalarValue?.javaClass?.name))
            .put("scalar_json", GSON.toJson(scalarValue))
    }

    private fun sequentialRuleProjection(
        arguments: JSONObject
    ): JSONObject {
        val content = arguments.getString("content")
        return JSONObject()
            .put(
                "string",
                AnalyzeRule().setContent(content).getString(
                    arguments.getString("string_rule")
                )
            )
            .put(
                "list",
                nullableStringList(
                    AnalyzeRule().setContent(content).getStringList(
                        arguments.getString("list_rule")
                    )
                )
            )
    }

    private fun urlListProjection(arguments: JSONObject): JSONObject {
        val analyze = AnalyzeRule().setContent(
            arguments.getString("content")
        )
        analyze.setRedirectUrl(arguments.getString("redirect_url"))
        return JSONObject().put(
            "urls",
            nullableStringList(
                analyze.getStringList(
                    arguments.getString("rule"),
                    isUrl = true
                )
            )
        )
    }

    private fun emptyRuleProjection(arguments: JSONObject): JSONObject {
        val content = arguments.getString("content")
        val missing = arguments.getString("missing_rule")
        return JSONObject()
            .put(
                "empty_string",
                AnalyzeRule().setContent(content).getString(null)
            )
            .put(
                "empty_list",
                nullableStringList(
                    AnalyzeRule().setContent(content)
                        .getStringList(null)
                )
            )
            .put(
                "empty_element",
                nullable(
                    AnalyzeRule().setContent(content)
                        .getElement("")?.toString()
                )
            )
            .put(
                "empty_elements_count",
                AnalyzeRule().setContent(content)
                    .getElements("").size
            )
            .put(
                "missing_string",
                AnalyzeRule().setContent(content).getString(missing)
            )
            .put(
                "missing_list",
                nullableStringList(
                    AnalyzeRule().setContent(content)
                        .getStringList(missing)
                )
            )
    }

    private fun ruleExceptionProjection(
        arguments: JSONObject
    ): JSONObject {
        var completed = false
        var value: String? = null
        var exceptionType: String? = null
        try {
            value = AnalyzeRule()
                .setContent(arguments.getString("content"))
                .getString(arguments.getString("rule"))
            completed = true
        } catch (error: Throwable) {
            exceptionType = error.javaClass.name
        }
        return JSONObject()
            .put("completed", completed)
            .put("value", nullable(value))
            .put("exception_type", nullable(exceptionType))
    }

    private fun nullableStringList(value: List<String>?): Any =
        value?.let(::JSONArray) ?: JSONObject.NULL

    private fun htmlPrefixDispatchProjection(
        arguments: JSONObject
    ): JSONObject {
        val analyze = AnalyzeRule().setContent(arguments.getString("content"))
        val ruleKeys = listOf(
            "default_rule",
            "css_rule",
            "escaped_default_rule",
            "xpath_rule",
            "leading_xpath_rule"
        )
        return JSONObject()
            .put(
                "modes",
                JSONObject().apply {
                    ruleKeys.forEach { key ->
                        put(
                            key.removeSuffix("_rule"),
                            sourceRuleProjection(
                                analyze,
                                arguments.getString(key)
                            )
                        )
                    }
                }
            )
            .put(
                "default_value",
                analyze.getString(arguments.getString("default_rule"))
            )
            .put(
                "css_value",
                analyze.getString(arguments.getString("css_rule"))
            )
            .put(
                "escaped_default_value",
                analyze.getString(
                    arguments.getString("escaped_default_rule")
                )
            )
            .put(
                "xpath_value",
                analyze.getString(arguments.getString("xpath_rule"))
            )
            .put(
                "leading_xpath_value",
                analyze.getString(
                    arguments.getString("leading_xpath_rule")
                )
            )
    }

    private fun jsonContentDispatchProjection(
        arguments: JSONObject
    ): JSONObject {
        val analyze = AnalyzeRule().setContent(arguments.getString("content"))
        val ruleKeys = listOf(
            "auto_rule",
            "signature_rule",
            "explicit_rule",
            "list_rule"
        )
        return JSONObject()
            .put(
                "modes",
                JSONObject().apply {
                    ruleKeys.forEach { key ->
                        put(
                            key.removeSuffix("_rule"),
                            sourceRuleProjection(
                                analyze,
                                arguments.getString(key)
                            )
                        )
                    }
                }
            )
            .put(
                "auto_value",
                analyze.getString(arguments.getString("auto_rule"))
            )
            .put(
                "signature_value",
                analyze.getString(arguments.getString("signature_rule"))
            )
            .put(
                "explicit_value",
                analyze.getString(arguments.getString("explicit_rule"))
            )
            .put(
                "list_values",
                JSONArray(
                    analyze.getStringList(
                        arguments.getString("list_rule")
                    ) ?: emptyList<String>()
                )
            )
    }

    private fun javascriptDispatchProjection(
        arguments: JSONObject
    ): JSONObject {
        val analyze = AnalyzeRule().setContent(arguments.getString("content"))
        val embeddedRule = arguments.getString("embedded_rule")
        val tailRule = arguments.getString("tail_rule")
        return JSONObject()
            .put("embedded_mode", sourceRuleProjection(analyze, embeddedRule))
            .put("tail_mode", sourceRuleProjection(analyze, tailRule))
            .put("embedded_value", analyze.getString(embeddedRule))
            .put("tail_value", analyze.getString(tailRule))
    }

    private fun regexStickinessProjection(
        arguments: JSONObject
    ): JSONObject {
        val analyze = AnalyzeRule().setContent(arguments.getString("content"))
        val activationRule = arguments.getString("activation_rule")
        val followupRule = arguments.getString("followup_rule")
        val activationMode = sourceRuleProjection(
            analyze,
            activationRule,
            allInOne = true
        )
        val activationValues = analyze.getElements(activationRule)
        val followupMode = sourceRuleProjection(
            analyze,
            followupRule,
            allInOne = true
        )
        val followupValues = analyze.getElements(followupRule)
        return JSONObject()
            .put("activation_mode", activationMode)
            .put("followup_mode", followupMode)
            .put(
                "activation_values",
                JSONArray(GSON.toJson(activationValues))
            )
            .put(
                "followup_values",
                JSONArray(GSON.toJson(followupValues))
            )
    }

    private fun parserCacheProjection(arguments: JSONObject): JSONObject =
        JSONObject()
            .put(
                "jsoup",
                parserCacheLifecycle(
                    arguments.getString("html_first"),
                    arguments.getString("html_second"),
                    arguments.getString("css_rule"),
                    "analyzeByJSoup"
                )
            )
            .put(
                "xpath",
                parserCacheLifecycle(
                    arguments.getString("html_first"),
                    arguments.getString("html_second"),
                    arguments.getString("xpath_rule"),
                    "analyzeByXPath"
                )
            )
            .put(
                "jsonpath",
                parserCacheLifecycle(
                    arguments.getString("json_first"),
                    arguments.getString("json_second"),
                    arguments.getString("json_rule"),
                    "analyzeByJSonPath"
                )
            )

    private fun parserCacheLifecycle(
        firstContent: String,
        secondContent: String,
        rule: String,
        fieldName: String
    ): JSONObject {
        val analyze = AnalyzeRule().setContent(firstContent)
        val firstValue = analyze.getString(rule)
        val firstParser = analyzeRuleField(analyze, fieldName)
        val repeatedValue = analyze.getString(rule)
        val repeatedParser = analyzeRuleField(analyze, fieldName)
        analyze.setContent(secondContent)
        val secondValue = analyze.getString(rule)
        val secondParser = analyzeRuleField(analyze, fieldName)
        return JSONObject()
            .put("first_value", firstValue)
            .put("repeated_value", repeatedValue)
            .put("second_value", secondValue)
            .put("same_instance_for_same_content", firstParser === repeatedParser)
            .put("replaced_after_set_content", firstParser !== secondParser)
    }

    private fun nativeObjectProjection(arguments: JSONObject): JSONObject {
        val nativeObject = requireNotNull(
            AnalyzeRule().evalJS(arguments.getString("script"))
        )
        val analyze = AnalyzeRule().setContent(nativeObject)
        val key = arguments.getString("key")
        return JSONObject()
            .put("runtime_type", nativeObject.javaClass.name)
            .put("rule_mode", sourceRuleProjection(analyze, key))
            .put("direct_value", analyze.getString(key))
    }

    private fun nullContentProjection(): JSONObject {
        var accepted = true
        var exceptionType: String? = null
        try {
            AnalyzeRule().setContent(null)
        } catch (error: Throwable) {
            accepted = false
            exceptionType = error.javaClass.name
        }
        return JSONObject()
            .put("accepted", accepted)
            .put("exception_type", nullable(exceptionType))
    }

    private fun foreignContentIsolationProjection(
        arguments: JSONObject
    ): JSONObject {
        val analyze = AnalyzeRule().setContent(
            arguments.getString("current_content")
        )
        val rule = arguments.getString("rule")
        val currentBefore = analyze.getString(rule)
        val parserBefore = analyzeRuleField(analyze, "analyzeByJSoup")
        val foreignValue = analyze.getString(
            rule,
            arguments.getString("foreign_content")
        )
        val parserAfterForeign = analyzeRuleField(analyze, "analyzeByJSoup")
        val currentAfter = analyze.getString(rule)
        val parserAfterCurrent = analyzeRuleField(analyze, "analyzeByJSoup")
        return JSONObject()
            .put("current_before", currentBefore)
            .put("foreign_value", foreignValue)
            .put("current_after", currentAfter)
            .put(
                "cache_preserved_after_foreign",
                parserBefore === parserAfterForeign
            )
            .put(
                "cache_reused_after_foreign",
                parserBefore === parserAfterCurrent
            )
    }

    private fun sourceRuleProjection(
        analyze: AnalyzeRule,
        rule: String,
        allInOne: Boolean = false
    ): JSONArray = JSONArray().apply {
        analyze.splitSourceRule(rule, allInOne).forEach { sourceRule ->
            put(
                JSONObject()
                    .put("mode", sourceRule.mode.name.lowercase())
                    .put("rule", sourceRule.rule)
            )
        }
    }

    private fun analyzeRuleField(
        analyze: AnalyzeRule,
        name: String
    ): Any? = AnalyzeRule::class.java
        .getDeclaredField(name)
        .apply { isAccessible = true }
        .get(analyze)

    private suspend fun ruleVariableScopeProjection(
        value: JSONObject
    ): JSONObject {
        val arguments = value.getJSONObject("arguments")
        return when (val mode = arguments.getString("mode")) {
            "storage_boundary" -> ruleDataStorageBoundary(arguments)
            "analyze_rule_priority" ->
                analyzeRulePriorityProjection(value, arguments)
            "analyze_url_priority" ->
                analyzeURLPriorityProjection(value, arguments)
            "rule_script_propagation" ->
                ruleScriptPropagationProjection(arguments)
            "url_script_propagation" ->
                urlScriptPropagationProjection(arguments)
            "failure_mutation" ->
                failureMutationProjection(arguments)
            "independent_contexts" ->
                independentContextProjection(arguments)
            else -> error("Unsupported rule variable mode: $mode")
        }
    }

    private fun ruleDataStorageBoundary(
        arguments: JSONObject
    ): JSONObject {
        val data = RuleData()
        val key = arguments.getString("key")
        val smallLength = arguments.getInt("small_length")
        val largeLength = arguments.getInt("large_length")
        val smallAccepted = data.putVariable(
            key,
            "s".repeat(smallLength)
        )
        val observedSmallLength = data.getVariable(key).length
        val largeAccepted = data.putVariable(
            key,
            "l".repeat(largeLength)
        )
        val observedLargeLength = data.getVariable(key).length
        val removalAccepted = data.putVariable(key, null)
        return JSONObject()
            .put("small_write_returned", smallAccepted)
            .put("small_value_length", observedSmallLength)
            .put("large_write_returned", largeAccepted)
            .put("large_value_length", observedLargeLength)
            .put("removal_returned", removalAccepted)
            .put("value_after_removal", data.getVariable(key))
            .put(
                "serialized_after_removal",
                nullable(data.getVariable())
            )
    }

    private fun analyzeRulePriorityProjection(
        value: JSONObject,
        arguments: JSONObject
    ): JSONObject {
        val id = value.getString("id")
        val key = arguments.getString("key")
        val caseSource = variableCaseSource(id)
        val book = variableBook(arguments, id)
        val chapter = variableChapter(arguments, book)
        caseSource.put(key, arguments.getString("source_value"))
        caseSource.put("source-only", "source-only-value")
        book.putVariable(key, arguments.getString("book_value"))
        book.putVariable("empty-fallback", "book-fallback")
        book.putVariable("bookName", "variable-book-name")
        chapter.putVariable(key, arguments.getString("chapter_value"))
        chapter.putVariable("empty-fallback", "")
        chapter.putVariable("title", "variable-chapter-title")
        val analyze = AnalyzeRule(book, caseSource)
        analyze.chapter = chapter
        val writeReturn = analyze.put("written", "via-analyze-rule")
        return JSONObject()
            .put("priority_value", analyze.get(key))
            .put("empty_chapter_falls_back", analyze.get("empty-fallback"))
            .put("source_fallback", analyze.get("source-only"))
            .put("book_name", analyze.get("bookName"))
            .put("chapter_title", analyze.get("title"))
            .put("write_return", writeReturn)
            .put("chapter_write", chapter.getVariable("written"))
            .put("book_write", book.getVariable("written"))
            .put("source_write", caseSource.get("written"))
    }

    private fun analyzeURLPriorityProjection(
        value: JSONObject,
        arguments: JSONObject
    ): JSONObject {
        val id = value.getString("id")
        val key = arguments.getString("key")
        val caseSource = variableCaseSource(id)
        val book = variableBook(arguments, id)
        val chapter = variableChapter(arguments, book)
        caseSource.put(key, arguments.getString("source_value"))
        caseSource.put("source-only", "source-only-value")
        book.putVariable(key, arguments.getString("book_value"))
        book.putVariable("empty-fallback", "book-fallback")
        book.putVariable("bookName", "variable-book-name")
        chapter.putVariable(key, arguments.getString("chapter_value"))
        chapter.putVariable("empty-fallback", "")
        chapter.putVariable("title", "variable-chapter-title")
        val analyze = AnalyzeUrl(
            mUrl = "$deviceOrigin/variables/priority",
            baseUrl = caseSource.bookSourceUrl,
            source = caseSource,
            ruleData = book,
            chapter = chapter
        )
        val writeReturn = analyze.put("written", "via-analyze-url")
        return JSONObject()
            .put("priority_value", analyze.get(key))
            .put("empty_chapter_falls_back", analyze.get("empty-fallback"))
            .put("source_fallback", analyze.get("source-only"))
            .put("book_name", analyze.get("bookName"))
            .put("chapter_title", analyze.get("title"))
            .put("write_return", writeReturn)
            .put("chapter_write", chapter.getVariable("written"))
            .put("book_write", book.getVariable("written"))
            .put("source_write", caseSource.get("written"))
    }

    private fun ruleScriptPropagationProjection(
        arguments: JSONObject
    ): JSONObject {
        val key = arguments.getString("key")
        val value = arguments.getString("value")
        val shared = RuleData()
        val scriptValue = AnalyzeRule(shared).evalJS(
            "java.put(${JSONObject.quote(key)},${JSONObject.quote(value)});" +
                "java.get(${JSONObject.quote(key)})"
        )
        val later = AnalyzeRule(shared)
        val isolated = AnalyzeRule(RuleData())
        return JSONObject()
            .put("script_value", nullable(scriptValue?.toString()))
            .put("later_field_value", later.get(key))
            .put("isolated_field_value", isolated.get(key))
            .put("serialized_variables", nullable(shared.getVariable()))
    }

    private fun urlScriptPropagationProjection(
        arguments: JSONObject
    ): JSONObject {
        val key = arguments.getString("key")
        val value = arguments.getString("value")
        val quotedKey = JSONObject.quote(key)
        val shared = RuleData()
        val first = AnalyzeUrl(
            mUrl =
                "<js>java.put($quotedKey,${JSONObject.quote(value)});" +
                    "${JSONObject.quote("$deviceOrigin/variables/url-written")}" +
                    "</js>",
            baseUrl = source.bookSourceUrl,
            ruleData = shared
        )
        val second = AnalyzeUrl(
            mUrl =
                "$deviceOrigin/variables/url-read/" +
                    "{{java.get($quotedKey)}}",
            baseUrl = source.bookSourceUrl,
            ruleData = shared
        )
        return JSONObject()
            .put("first_url", logical(first.url))
            .put("second_url", logical(second.url))
            .put("stored_value", shared.getVariable(key))
    }

    private fun failureMutationProjection(
        arguments: JSONObject
    ): JSONObject {
        val shared = RuleData()
        val ruleKey = arguments.getString("rule_key")
        val urlKey = arguments.getString("url_key")
        val value = arguments.getString("value")
        var ruleThrew = false
        try {
            AnalyzeRule(shared).evalJS(
                "java.put(${JSONObject.quote(ruleKey)}," +
                    "${JSONObject.quote(value)});throw 'rule-failure'"
            )
        } catch (_: Throwable) {
            ruleThrew = true
        }
        var urlThrew = false
        try {
            AnalyzeUrl(
                mUrl =
                    "<js>java.put(${JSONObject.quote(urlKey)}," +
                        "${JSONObject.quote(value)});throw 'url-failure'</js>",
                baseUrl = source.bookSourceUrl,
                ruleData = shared
            )
        } catch (_: Throwable) {
            urlThrew = true
        }
        return JSONObject()
            .put("rule_threw", ruleThrew)
            .put("rule_value_after_failure", shared.getVariable(ruleKey))
            .put("url_threw", urlThrew)
            .put("url_value_after_failure", shared.getVariable(urlKey))
    }

    private suspend fun independentContextProjection(
        arguments: JSONObject
    ): JSONObject = coroutineScope {
        val key = arguments.getString("key")
        val leftData = RuleData()
        val rightData = RuleData()
        val left = async {
            val analyze = AnalyzeRule(leftData)
            analyze.put(key, arguments.getString("left_value"))
            analyze.get(key)
        }
        val right = async {
            val analyze = AnalyzeRule(rightData)
            analyze.put(key, arguments.getString("right_value"))
            analyze.get(key)
        }
        JSONObject()
            .put("left_value", left.await())
            .put("right_value", right.await())
            .put("left_storage", leftData.getVariable(key))
            .put("right_storage", rightData.getVariable(key))
            .put(
                "storage_identity_distinct",
                leftData.variableMap !== rightData.variableMap
            )
    }

    private fun variableCaseSource(id: String): BookSource =
        GSON.fromJson(sourceJson, BookSource::class.java).apply {
            bookSourceUrl = "$deviceOrigin/variable-source/$id"
            bookSourceName = "Variable $id"
        }

    private fun variableBook(
        arguments: JSONObject,
        id: String
    ): Book = Book(
        bookUrl = "$deviceOrigin/variables/book/$id",
        origin = source.bookSourceUrl,
        originName = source.bookSourceName,
        name = arguments.getString("book_name")
    )

    private fun variableChapter(
        arguments: JSONObject,
        book: Book
    ): BookChapter = BookChapter(
        url = "$deviceOrigin/variables/chapter",
        title = arguments.getString("chapter_title"),
        bookUrl = book.bookUrl
    )

    private suspend fun dynamicWebProjection(
        value: JSONObject
    ): Pair<JSONObject, JSONObject> {
        clearDynamicCookieState()
        val arguments = value.getJSONObject("arguments")
        val requestValue = value.getJSONObject("request")
        val method = requestValue.getString("method")
        val target = requestValue.getString("target")
        val optionUseWebView =
            arguments.getBoolean("option_use_webview")
        val invocationUseWebView =
            arguments.getBoolean("invocation_use_webview")
        val option = JSONObject().put("webView", optionUseWebView)
        if (!arguments.isNull("web_js")) {
            option.put("webJs", arguments.getString("web_js"))
        }
        if (method == "POST") {
            option
                .put("method", "POST")
                .put("body", arguments.getString("body"))
        } else {
            require(method == "GET")
        }
        val analyze = AnalyzeUrl(
            mUrl = "$deviceOrigin$target,$option",
            baseUrl = source.bookSourceUrl,
            source = source,
            headerMapF = source.getHeaderMap(true)
        )
        val sourceCookieBefore = CookieStore.getCookie(deviceOrigin)
        val webCookieBefore = currentWebCookie(deviceOrigin)
        val sourceRegex =
            if (arguments.isNull("source_regex")) {
                null
            } else {
                arguments.getString("source_regex")
            }
        val response = withTimeout(15_000) {
            analyze.getStrResponseAwait(
                sourceRegex = sourceRegex,
                useWebView = invocationUseWebView
            )
        }
        return Pair(
            analyzedRequest(analyze),
            JSONObject()
                .put("configured_use_webview", optionUseWebView)
                .put("invocation_use_webview", invocationUseWebView)
                .put(
                    "configured_web_js",
                    nullable(
                        if (arguments.isNull("web_js")) {
                            null
                        } else {
                            arguments.getString("web_js")
                        }
                    )
                )
                .put("source_regex", nullable(sourceRegex))
                .put(
                    "body",
                    nullable(
                        response.body?.replace(
                            deviceOrigin,
                            logicalOrigin
                        )
                    )
                )
                .put("final_url", logical(response.url))
                .put("source_cookie_before", sourceCookieBefore)
                .put(
                    "source_cookie_after",
                    CookieStore.getCookie(deviceOrigin)
                )
                .put("web_cookie_before", nullable(webCookieBefore))
                .put(
                    "web_cookie_after",
                    nullable(currentWebCookie(deviceOrigin))
                )
        )
    }

    private fun clearDynamicCookieState() {
        resetCookieState(deviceOrigin)
        val latch = CountDownLatch(1)
        InstrumentationRegistry.getInstrumentation().runOnMainSync {
            android.webkit.CookieManager
                .getInstance()
                .removeAllCookies {
                    latch.countDown()
                }
        }
        require(latch.await(5, TimeUnit.SECONDS)) {
            "Timed out clearing WebView cookies"
        }
        InstrumentationRegistry.getInstrumentation().runOnMainSync {
            android.webkit.CookieManager.getInstance().flush()
        }
    }

    private fun currentWebCookie(url: String): String? {
        var value: String? = null
        InstrumentationRegistry.getInstrumentation().runOnMainSync {
            value = android.webkit.CookieManager
                .getInstance()
                .getCookie(url)
        }
        return value
    }

    private fun dynamicWebFallbackRequest(value: JSONObject): JSONObject {
        val requestValue = value.getJSONObject("request")
        val method = requestValue.getString("method")
        return JSONObject()
            .put("method", method)
            .put(
                "url",
                logical(deviceOrigin + requestValue.getString("target"))
            )
            .put(
                "headers",
                controlledHeaders(
                    listOf("X-Source" to "dynamic-web")
                )
            )
            .put(
                "body",
                if (method == "POST") {
                    value.getJSONObject("arguments").getString("body")
                } else {
                    JSONObject.NULL
                }
            )
            .put("timeout_ms", JSONObject.NULL)
    }

    private suspend fun cookieSessionProjection(
        value: JSONObject
    ): Pair<JSONObject, JSONObject> {
        val arguments = value.getJSONObject("arguments")
        return when (val mode = arguments.getString("mode")) {
            "parser" -> Pair(
                cookieHelperRequest(value),
                JSONObject()
                    .put(
                        "entries",
                        cookieEntries(
                            CookieStore.cookieToMap(
                                arguments.getString("cookie")
                            )
                        )
                    )
                    .put(
                        "serialized",
                        nullable(
                            CookieStore.mapToCookie(
                                CookieStore.cookieToMap(
                                    arguments.getString("cookie")
                                )
                            )
                        )
                    )
            )

            "store_merge" -> {
                resetCookieState(deviceOrigin)
                seedCookieState(arguments)
                Pair(
                    cookieHelperRequest(value),
                    cookieState(deviceOrigin)
                )
            }

            "analyze_request" -> cookieAnalyzeProjection(value)

            "response_classification" -> {
                resetCookieState(deviceOrigin)
                saveSetCookies(
                    deviceOrigin,
                    jsonStrings(arguments.getJSONArray("set_cookies"))
                )
                Pair(
                    cookieHelperRequest(value),
                    cookieState(deviceOrigin)
                )
            }

            "metadata_flattening" -> {
                resetCookieState(deviceOrigin)
                saveSetCookies(
                    deviceOrigin,
                    jsonStrings(arguments.getJSONArray("set_cookies"))
                )
                val loadURL =
                    deviceOrigin + arguments.getString("load_target")
                val loaded = CookieManager.loadRequest(
                    Request.Builder().url(loadURL).build()
                )
                Pair(
                    cookieHelperRequest(value),
                    cookieState(deviceOrigin)
                        .put("load_url", logical(loadURL))
                        .put(
                            "loaded_cookie",
                            nullable(loaded.header("Cookie"))
                        )
                )
            }

            "redirect" -> cookieRedirectProjection(value)

            "removal" -> {
                resetCookieState(deviceOrigin)
                seedCookieState(arguments)
                val before = cookieState(deviceOrigin)
                CookieManager.removeCookie(
                    deviceOrigin,
                    arguments.getString("remove_key")
                )
                val afterKey = cookieState(deviceOrigin)
                CookieStore.removeCookie(deviceOrigin)
                val afterDomain = cookieState(deviceOrigin)
                Pair(
                    cookieHelperRequest(value),
                    JSONObject()
                        .put("before", before)
                        .put("after_key_removal", afterKey)
                        .put("after_domain_removal", afterDomain)
                )
            }

            "domain_normalization" -> {
                val writeURL = arguments.getString("write_url")
                val sameSiteURL = arguments.getString("same_site_url")
                val otherSiteURL = arguments.getString("other_site_url")
                resetCookieState(writeURL)
                resetCookieState(otherSiteURL)
                CookieStore.setCookie(
                    writeURL,
                    arguments.getString("cookie")
                )
                val result = JSONObject()
                    .put(
                        "write_domain",
                        NetworkUtils.getSubDomain(writeURL)
                    )
                    .put(
                        "same_site_domain",
                        NetworkUtils.getSubDomain(sameSiteURL)
                    )
                    .put(
                        "other_site_domain",
                        NetworkUtils.getSubDomain(otherSiteURL)
                    )
                    .put(
                        "same_site_cookie",
                        CookieStore.getCookie(sameSiteURL)
                    )
                    .put(
                        "other_site_cookie",
                        CookieStore.getCookie(otherSiteURL)
                    )
                resetCookieState(writeURL)
                resetCookieState(otherSiteURL)
                Pair(cookieHelperRequest(value), result)
            }

            else -> error("Unsupported cookie session mode: $mode")
        }
    }

    private suspend fun cookieAnalyzeProjection(
        value: JSONObject
    ): Pair<JSONObject, JSONObject> {
        val arguments = value.getJSONObject("arguments")
        resetCookieState(deviceOrigin)
        seedCookieState(arguments)
        val caseSource = GSON.fromJson(sourceJson, BookSource::class.java)
        caseSource.enabledCookieJar =
            arguments.getBoolean("enabled_cookie_jar")
        val headers = HashMap(
            caseSource.getHeaderMap(true) ?: emptyMap()
        )
        headers["Cookie"] = arguments.getString("explicit_cookie")
        val target = value.getJSONObject("request").getString("target")
        val analyze = AnalyzeUrl(
            mUrl = "$deviceOrigin$target",
            baseUrl = caseSource.bookSourceUrl,
            source = caseSource,
            headerMapF = headers
        )
        val initialCookie = analyze.headerMap["Cookie"]
        val response = analyze.getStrResponseAwait(useWebView = false)
        val networkRequest =
            response.raw.networkResponse?.request ?: response.raw.request
        return Pair(
            analyzedRequest(analyze),
            cookieState(deviceOrigin)
                .put(
                    "enabled_cookie_jar",
                    caseSource.enabledCookieJar == true
                )
                .put("initial_cookie", nullable(initialCookie))
                .put(
                    "resolved_cookie",
                    nullable(analyze.headerMap["Cookie"])
                )
                .put(
                    "marker_present",
                    analyze.headerMap.containsKey(
                        CookieManager.cookieJarHeader
                    )
                )
                .put(
                    "network_cookie",
                    nullable(networkRequest.header("Cookie"))
                )
                .put(
                    "network_marker_present",
                    networkRequest.header(
                        CookieManager.cookieJarHeader
                    ) != null
                )
                .put("status_code", response.code())
                .put("final_url", logical(response.url))
        )
    }

    private suspend fun cookieRedirectProjection(
        value: JSONObject
    ): Pair<JSONObject, JSONObject> {
        resetCookieState(deviceOrigin)
        val caseSource = GSON.fromJson(sourceJson, BookSource::class.java)
        caseSource.enabledCookieJar = true
        val target = value.getJSONObject("request").getString("target")
        val analyze = AnalyzeUrl(
            mUrl = "$deviceOrigin$target",
            baseUrl = caseSource.bookSourceUrl,
            source = caseSource,
            headerMapF = caseSource.getHeaderMap(true)
        )
        val response = analyze.getStrResponseAwait(useWebView = false)
        val prior = response.raw.priorResponse
        val finalNetwork =
            response.raw.networkResponse?.request ?: response.raw.request
        var redirectCount = 0
        var cursor = prior
        while (cursor != null) {
            redirectCount += 1
            cursor = cursor.priorResponse
        }
        return Pair(
            analyzedRequest(analyze),
            cookieState(deviceOrigin)
                .put("redirect_count", redirectCount)
                .put(
                    "prior_request_cookie",
                    nullable(prior?.request?.header("Cookie"))
                )
                .put(
                    "prior_marker_present",
                    prior?.request?.header(
                        CookieManager.cookieJarHeader
                    ) != null
                )
                .put(
                    "final_request_cookie",
                    nullable(finalNetwork.header("Cookie"))
                )
                .put(
                    "final_marker_present",
                    finalNetwork.header(
                        CookieManager.cookieJarHeader
                    ) != null
                )
                .put("final_url", logical(response.url))
                .put("status_code", response.code())
        )
    }

    private fun seedCookieState(arguments: JSONObject) {
        CookieStore.setCookie(
            deviceOrigin,
            arguments.optString("persistent_cookie", "")
        )
        if (arguments.has("session_set_cookies")) {
            saveSetCookies(
                deviceOrigin,
                jsonStrings(
                    arguments.getJSONArray("session_set_cookies")
                )
            )
        }
    }

    private fun saveSetCookies(
        url: String,
        values: List<String>
    ) {
        val request = Request.Builder().url(url).build()
        val headers = Headers.Builder().apply {
            values.forEach { add("Set-Cookie", it) }
        }.build()
        val response = Response.Builder()
            .request(request)
            .protocol(Protocol.HTTP_1_1)
            .code(200)
            .message("cookie-seed")
            .headers(headers)
            .body(
                ByteArray(0).toResponseBody(
                    "text/plain; charset=utf-8".toMediaType()
                )
            )
            .build()
        CookieManager.saveResponse(response)
        response.close()
    }

    private fun resetCookieState(url: String) {
        val domain = NetworkUtils.getSubDomain(url)
        CookieStore.setCookie(url, "")
        CacheManager.deleteMemory("${domain}_session_cookie")
        CacheManager.deleteMemory("${domain}_cookieJar")
    }

    private fun cookieState(url: String): JSONObject {
        val domain = NetworkUtils.getSubDomain(url)
        return JSONObject()
            .put("domain", domain)
            .put(
                "persistent_cookie",
                CookieManager.getCookieNoSession(url)
            )
            .put(
                "session_cookie",
                nullable(CookieManager.getSessionCookie(domain))
            )
            .put("combined_cookie", CookieStore.getCookie(url))
    }

    private fun cookieEntries(
        values: Map<String, String>
    ): JSONArray = JSONArray().apply {
        values.forEach { (name, value) ->
            put(
                JSONObject()
                    .put("name", name)
                    .put("value", value)
            )
        }
    }

    private fun jsonStrings(values: JSONArray): List<String> =
        buildList {
            for (index in 0 until values.length()) {
                add(values.getString(index))
            }
        }

    private fun cookieHelperRequest(value: JSONObject): JSONObject {
        val target = value.getJSONObject("request").getString("target")
        return request(deviceOrigin + target).put(
            "headers",
            controlledHeaders(
                listOf("X-Source" to "cookie-session")
            )
        )
    }

    private suspend fun retryAnalyzeProjection(
        value: JSONObject
    ): Pair<JSONObject, JSONObject> {
        val arguments = value.getJSONObject("arguments")
        val retry = arguments.getInt("retry")
        val target = value.getJSONObject("request").getString("target")
        val option = JSONObject().put("retry", retry)
        val analyze = AnalyzeUrl(
            mUrl = "$deviceOrigin$target,$option",
            baseUrl = source.bookSourceUrl,
            source = source,
            headerMapF = source.getHeaderMap(true)
        )
        val response = analyze.getStrResponseAwait(useWebView = false)
        val redirectObserved =
            response.raw.priorResponse?.isRedirect == true
        var redirectCheckCompleted = false
        if (arguments.optBoolean("invoke_redirect_check", false)) {
            reflectedCheckRedirect(response)
            redirectCheckCompleted = true
        }
        return Pair(
            analyzedRequest(analyze),
            JSONObject()
                .put("configured_retry", reflectedInt(analyze, "retry"))
                .put("status_code", response.code())
                .put("is_successful", response.isSuccessful())
                .put("body", nullable(response.body))
                .put("final_url", logical(response.url))
                .put("redirect_observed", redirectObserved)
                .put("redirect_check_completed", redirectCheckCompleted)
        )
    }

    private suspend fun helperStatusSequenceProjection(
        value: JSONObject
    ): Pair<JSONObject, JSONObject> {
        val arguments = value.getJSONObject("arguments")
        val retry = arguments.getInt("retry")
        val rawStatuses = arguments.getJSONArray("status_sequence")
        val statuses = buildList {
            for (index in 0 until rawStatuses.length()) {
                add(rawStatuses.getInt(index))
            }
        }
        val attempts = mutableListOf<Int>()
        val fingerprints = mutableListOf<String>()
        val identities = mutableSetOf<Int>()
        val client = OkHttpClient.Builder()
            .addInterceptor { chain ->
                val request = chain.request()
                val status = statuses[minOf(attempts.size, statuses.lastIndex)]
                attempts.add(status)
                fingerprints.add(requestFingerprint(request))
                identities.add(System.identityHashCode(request))
                Response.Builder()
                    .request(request)
                    .protocol(Protocol.HTTP_1_1)
                    .code(status)
                    .message("status-$status")
                    .body(
                        "status-$status".toResponseBody(
                            "text/plain; charset=utf-8".toMediaType()
                        )
                    )
                    .build()
            }
            .build()
        val target = helperURL(value)
        val outcome = runCatching {
            client.newCallResponse(retry) {
                url(target)
                addHeader("X-Source", "retry-redirect")
            }
        }
        val response = outcome.getOrNull()
        val result = JSONObject()
            .put("configured_retry", retry)
            .put("attempt_count", attempts.size)
            .put("observed_statuses", JSONArray(attempts))
            .put("final_status", response?.code ?: JSONObject.NULL)
            .put("is_successful", response?.isSuccessful ?: false)
            .put(
                "request_fingerprints_identical",
                fingerprints.distinct().size <= 1
            )
            .put("request_instance_count", identities.size)
            .put(
                "exception_type",
                nullable(outcome.exceptionOrNull()?.javaClass?.name)
            )
        response?.close()
        return Pair(helperRequest(value), result)
    }

    private suspend fun helperNetworkExceptionProjection(
        value: JSONObject
    ): Pair<JSONObject, JSONObject> {
        val arguments = value.getJSONObject("arguments")
        val retry = arguments.getInt("retry")
        val attempts = AtomicInteger()
        val client = OkHttpClient.Builder()
            .addInterceptor {
                attempts.incrementAndGet()
                throw IOException("source-lab-network-failure")
            }
            .build()
        val outcome = runCatching {
            client.newCallResponse(retry) {
                url(helperURL(value))
                addHeader("X-Source", "retry-redirect")
            }
        }
        return Pair(
            helperRequest(value),
            JSONObject()
                .put("configured_retry", retry)
                .put("attempt_count", attempts.get())
                .put(
                    "exception_type",
                    nullable(outcome.exceptionOrNull()?.javaClass?.name)
                )
                .put("response_received", outcome.getOrNull() != null)
        )
    }

    private suspend fun helperCancellationProjection(
        value: JSONObject
    ): Pair<JSONObject, JSONObject> = coroutineScope {
        val arguments = value.getJSONObject("arguments")
        val retry = arguments.getInt("retry")
        val attempts = AtomicInteger()
        val callCancelled = AtomicBoolean(false)
        val started = CompletableDeferred<Unit>()
        val client = OkHttpClient.Builder()
            .addInterceptor { chain ->
                attempts.incrementAndGet()
                started.complete(Unit)
                while (!chain.call().isCanceled()) {
                    Thread.sleep(1)
                }
                callCancelled.set(chain.call().isCanceled())
                throw IOException("cancelled")
            }
            .build()
        val call = async {
            client.newCallResponse(retry) {
                url(helperURL(value))
                addHeader("X-Source", "retry-redirect")
            }
        }
        withTimeout(2_000) { started.await() }
        call.cancel()
        val error = try {
            call.await()
            null
        } catch (value: Throwable) {
            value
        }
        withTimeout(2_000) {
            while (!callCancelled.get()) {
                delay(1)
            }
        }
        Pair(
            helperRequest(value),
            JSONObject()
                .put("configured_retry", retry)
                .put("attempt_count", attempts.get())
                .put("call_cancelled", callCancelled.get())
                .put("cancellation_propagated", error is CancellationException)
                .put("response_received", error == null)
        )
    }

    private fun helperRequest(value: JSONObject): JSONObject =
        request(helperURL(value)).put(
            "headers",
            controlledHeaders(
                listOf("X-Source" to "retry-redirect")
            )
        )

    private fun helperURL(value: JSONObject): String =
        deviceOrigin + value.getJSONObject("request").getString("target")

    private fun requestFingerprint(request: Request): String =
        request.method + "\u0000" + request.url + "\u0000" + request.headers

    private fun retryFallbackRequest(value: JSONObject): JSONObject {
        val target = value.getJSONObject("request").getString("target")
        return request(deviceOrigin + target).put(
            "headers",
            controlledHeaders(
                listOf("X-Source" to "retry-redirect")
            )
        )
    }

    private fun reflectedCheckRedirect(response: StrResponse) {
        val method = WebBook::class.java.getDeclaredMethod(
            "checkRedirect",
            BookSource::class.java,
            StrResponse::class.java
        )
        method.isAccessible = true
        try {
            method.invoke(WebBook, source, response)
        } catch (error: InvocationTargetException) {
            throw error.targetException
        }
    }

    private suspend fun runRequestOptionCases() {
        val values = input.getJSONArray("cases")
        for (index in 0 until values.length()) {
            val value = values.getJSONObject(index)
            require(value.getString("operation") == "request_options") {
                "Request option scenario only accepts request_options stimuli"
            }
            val arguments = value.getJSONObject("arguments")
            val persistentCookie = arguments.getString("persistent_cookie")
            val option = arguments.getJSONObject("option")
            val target = value
                .getJSONObject("request")
                .getString("target")
            CookieStore.removeCookie(deviceOrigin)
            if (persistentCookie.isNotEmpty()) {
                CookieStore.setCookie(deviceOrigin, persistentCookie)
            }
            try {
                val inheritedHeaders = controlledHeaders(
                    source.getHeaderMap(true).orEmpty().entries.map {
                        it.key to it.value
                    }
                )
                val analyze = AnalyzeUrl(
                    mUrl = "$deviceOrigin$target,${option}",
                    baseUrl = source.bookSourceUrl,
                    source = source,
                    headerMapF = source.getHeaderMap(true)
                )
                val constructedHeaders = controlledHeaders(
                    analyze.headerMap.entries.map { it.key to it.value }
                )
                val request = request(analyze.url)
                    .put("headers", constructedHeaders)
                val retryField =
                    AnalyzeUrl::class.java.getDeclaredField("retry")
                retryField.isAccessible = true
                val retry = retryField.getInt(analyze)
                runCase(
                    value.getString("id"),
                    "request_options",
                    request
                ) {
                    val response = analyze.getStrResponseAwait(
                        useWebView = false
                    )
                    val networkRequest =
                        response.raw.networkResponse?.request
                            ?: response.raw.request
                    val networkHeaderPairs = buildList {
                        for (headerIndex in 0 until networkRequest.headers.size) {
                            add(
                                networkRequest.headers.name(headerIndex) to
                                    networkRequest.headers.value(headerIndex)
                            )
                        }
                    }
                    JSONObject()
                        .put("inherited_headers", inheritedHeaders)
                        .put("constructed_headers", constructedHeaders)
                        .put(
                            "resolved_headers",
                            controlledHeaders(
                                analyze.headerMap.entries.map {
                                    it.key to it.value
                                }
                            )
                        )
                        .put(
                            "network_headers",
                            controlledHeaders(networkHeaderPairs)
                        )
                        .put("retry", retry)
                        .put("status_code", response.code())
                        .put("body", nullable(response.body))
                        .put("final_url", logical(response.url))
                }
            } finally {
                CookieStore.removeCookie(deviceOrigin)
            }
        }
    }

    private fun runFieldEncodingCases() {
        val values = input.getJSONArray("cases")
        for (index in 0 until values.length()) {
            val value = values.getJSONObject(index)
            require(value.getString("operation") == "field_encoding") {
                "Field encoding scenario only accepts field_encoding stimuli"
            }
            val id = value.getString("id")
            val arguments = value.getJSONObject("arguments")
            val method = arguments.getString("method")
            val fieldsText = arguments.getString("fields")
            val target = value.getJSONObject("request").getString("target")
            val option = JSONObject()
            if (method == "POST") {
                option.put("method", "POST").put("body", fieldsText)
            }
            if (arguments.has("charset")) {
                option.put("charset", arguments.getString("charset"))
            }
            val rawURL =
                if (method == "GET") {
                    "$deviceOrigin$target?$fieldsText"
                } else {
                    "$deviceOrigin$target,$option"
                }
            val fallbackRequest = request("$deviceOrigin$target")
                .put("method", method)
            val record = JSONObject()
                .put("id", id)
                .put("operation", "field_encoding")
            try {
                val analyze = AnalyzeUrl(
                    mUrl = rawURL,
                    baseUrl = source.bookSourceUrl,
                    source = source,
                    headerMapF = source.getHeaderMap(true)
                )
                val fieldMap = reflectedFieldMap(analyze)
                val encoded = fieldMap.entries.joinToString("&") {
                    "${it.key}=${it.value}"
                }
                val analyzedRequest =
                    if (method == "GET") {
                        request("${reflectedString(analyze, "urlNoQuery")}?$encoded")
                    } else {
                        request(analyze.url)
                            .put("method", "POST")
                            .put("body", encoded)
                    }
                requestPlan.put(analyzedRequest)
                record
                    .put("request", analyzedRequest)
                    .put(
                        "result",
                        JSONObject()
                            .put("method", method)
                            .put(
                                "query_string",
                                nullable(reflectedNullableString(analyze, "queryStr"))
                            )
                            .put(
                                "field_map",
                                JSONArray().apply {
                                    fieldMap.forEach { (key, fieldValue) ->
                                        put(
                                            JSONObject()
                                                .put("key", key)
                                                .put("value", fieldValue)
                                        )
                                    }
                                }
                            )
                    )
                    .put("issue", JSONObject.NULL)
            } catch (error: Throwable) {
                requestPlan.put(fallbackRequest)
                record
                    .put("request", fallbackRequest)
                    .put("result", JSONObject.NULL)
                    .put(
                        "issue",
                        JSONObject()
                            .put("code", "android_exception")
                            .put("exception_type", error.javaClass.name)
                    )
            }
            cases.put(record)
        }
    }

    private fun runURLTemplateCompilationCases() {
        val values = input.getJSONArray("cases")
        for (index in 0 until values.length()) {
            val value = values.getJSONObject(index)
            require(value.getString("operation") == "url_template_compilation") {
                "URL template scenario only accepts url_template_compilation stimuli"
            }
            val id = value.getString("id")
            val arguments = value.getJSONObject("arguments")
            val template = arguments.getString("template")
            val key =
                if (arguments.has("key")) arguments.getString("key") else null
            val page =
                if (arguments.has("page")) arguments.getInt("page") else null
            val baseUrl =
                if (arguments.has("base_path")) {
                    deviceOrigin + arguments.getString("base_path")
                } else {
                    deviceOrigin
                }
            val fallback = value.getJSONObject("request")
            val fallbackRequest = request(
                deviceOrigin + fallback.getString("target")
            ).put("method", fallback.getString("method"))
            val record = JSONObject()
                .put("id", id)
                .put("operation", "url_template_compilation")
            try {
                val analyze = AnalyzeUrl(
                    mUrl = template,
                    key = key,
                    page = page,
                    baseUrl = baseUrl,
                    source = source,
                    headerMapF = source.getHeaderMap(true)
                )
                val fields = reflectedFieldMap(analyze)
                val encodedFields = fields.entries.joinToString("&") {
                    "${it.key}=${it.value}"
                }
                val method = if (analyze.isPost()) "POST" else "GET"
                val body =
                    if (analyze.isPost() && fields.isNotEmpty()) {
                        encodedFields
                    } else {
                        analyze.body
                    }
                val requestURL =
                    if (!analyze.isPost() && fields.isNotEmpty()) {
                        "${reflectedString(analyze, "urlNoQuery")}?$encodedFields"
                    } else {
                        analyze.url
                    }
                val analyzedRequest = request(requestURL)
                    .put("method", method)
                    .put("body", nullable(body))
                requestPlan.put(analyzedRequest)
                record
                    .put("request", analyzedRequest)
                    .put(
                        "result",
                        JSONObject()
                            .put("rule_url", analyze.ruleUrl)
                            .put("url", logical(analyze.url))
                            .put(
                                "url_no_query",
                                logical(reflectedString(analyze, "urlNoQuery"))
                            )
                            .put("method", method)
                            .put("body", nullable(body))
                            .put(
                                "query_string",
                                nullable(
                                    reflectedNullableString(
                                        analyze,
                                        "queryStr"
                                    )
                                )
                            )
                            .put(
                                "field_map",
                                JSONArray().apply {
                                    fields.forEach { (fieldKey, fieldValue) ->
                                        put(
                                            JSONObject()
                                                .put("key", fieldKey)
                                                .put("value", fieldValue)
                                        )
                                    }
                                }
                            )
                            .put("retry", reflectedInt(analyze, "retry"))
                    )
                    .put("issue", JSONObject.NULL)
            } catch (error: Throwable) {
                requestPlan.put(fallbackRequest)
                record
                    .put("request", fallbackRequest)
                    .put("result", JSONObject.NULL)
                    .put(
                        "issue",
                        JSONObject()
                            .put("code", "android_exception")
                            .put("exception_type", error.javaClass.name)
                    )
            }
            cases.put(record)
        }
    }

    private suspend fun runRateLimitStateCases() {
        val values = input.getJSONArray("cases")
        for (index in 0 until values.length()) {
            val value = values.getJSONObject(index)
            require(value.getString("operation") == "rate_limit_state") {
                "Rate limit scenario only accepts rate_limit_state stimuli"
            }
            val target = value.getJSONObject("request").getString("target")
            runCase(
                value.getString("id"),
                "rate_limit_state",
                request("$deviceOrigin$target")
            ) {
                rateLimitProjection(value)
            }
        }
    }

    private suspend fun runTransportDispatchCases() {
        val values = input.getJSONArray("cases")
        for (index in 0 until values.length()) {
            val value = values.getJSONObject(index)
            require(value.getString("operation") == "transport_dispatch") {
                "Transport dispatch scenario only accepts transport_dispatch stimuli"
            }
            when (value.getJSONObject("arguments").getString("mode")) {
                "response" -> runTransportCase(value) {
                    val analyze = transportAnalyze(value)
                    analyze.getResponseAwait().use { response ->
                        val networkRequest =
                            response.networkResponse?.request ?: response.request
                        Pair(
                            observedRequest(networkRequest),
                            responseProjection(response)
                        )
                    }
                }

                "typed_string" -> runTransportCase(value) {
                    val analyze = transportAnalyze(value)
                    val response = analyze.getStrResponseAwait(useWebView = false)
                    Pair(
                        analyzedRequest(analyze),
                        JSONObject()
                            .put("body_hex", nullable(response.body))
                            .put("final_url", logical(response.url))
                    )
                }

                "byte_array" -> runTransportCase(value) {
                    val analyze = transportAnalyze(value)
                    val bytes = analyze.getByteArrayAwait()
                    Pair(
                        analyzedRequest(analyze),
                        JSONObject()
                            .put("bytes_base64", base64(bytes))
                            .put("byte_count", bytes.size)
                    )
                }

                "input_stream" -> runTransportCase(value) {
                    val analyze = transportAnalyze(value)
                    val bytes = analyze.getInputStreamAwait().use {
                        it.readBytes()
                    }
                    Pair(
                        analyzedRequest(analyze),
                        JSONObject()
                            .put("bytes_base64", base64(bytes))
                            .put("byte_count", bytes.size)
                    )
                }

                "data_uri" -> runTransportCase(value) {
                    val analyze = transportAnalyze(value)
                    val byteArray = analyze.getByteArrayAwait()
                    val streamBytes = analyze.getInputStreamAwait().use {
                        it.readBytes()
                    }
                    Pair(
                        analyzedRequest(analyze),
                        JSONObject()
                            .put("byte_array_base64", base64(byteArray))
                            .put("input_stream_base64", base64(streamBytes))
                            .put("same_bytes", byteArray.contentEquals(streamBytes))
                    )
                }

                "media_models" -> runTransportCase(value) {
                    val analyze = transportAnalyze(value)
                    val glide = analyze.getGlideUrl()
                    val mediaUri = requireNotNull(
                        analyze.getMediaItem().localConfiguration
                    ).uri.toString()
                    val mediaParts = mediaUri.split("🚧", limit = 2)
                    require(mediaParts.size == 2) {
                        "MediaItem did not preserve the URL/header boundary"
                    }
                    val mediaHeaders = JSONObject(mediaParts[1])
                    val mediaHeaderPairs = buildList {
                        mediaHeaders.keys().forEach { name ->
                            add(name to mediaHeaders.getString(name))
                        }
                    }
                    Pair(
                        analyzedRequest(analyze),
                        JSONObject()
                            .put("glide_url", logical(glide.toStringUrl()))
                            .put(
                                "glide_headers",
                                controlledHeaders(
                                    glide.headers.entries.map {
                                        it.key to it.value
                                    }
                                )
                            )
                            .put("media_url", logical(mediaParts[0]))
                            .put(
                                "media_headers",
                                controlledHeaders(mediaHeaderPairs)
                            )
                    )
                }

                "client_policy" -> runTransportCase(value) {
                    val arguments = value.getJSONObject("arguments")
                    val readTimeout = arguments.getLong("read_timeout_ms")
                    val analyze = transportAnalyze(value)
                    val client = reflectedClient(analyze)
                    Pair(
                        analyzedRequest(analyze, readTimeout.toInt()),
                        JSONObject()
                            .put(
                                "proxy_header_removed",
                                analyze.headerMap.keys.none {
                                    it.equals("proxy", ignoreCase = true)
                                }
                            )
                            .put("proxy_configured", client.proxy != null)
                            .put(
                                "proxy_type",
                                nullable(client.proxy?.type()?.name)
                            )
                            .put(
                                "read_timeout_ms",
                                client.readTimeoutMillis
                            )
                            .put(
                                "call_timeout_ms",
                                client.callTimeoutMillis
                            )
                            .put(
                                "request_headers",
                                controlledHeaders(
                                    analyze.headerMap.entries.map {
                                        it.key to it.value
                                    }
                                )
                            )
                    )
                }

                else -> error(
                    "Unsupported transport dispatch mode: " +
                        value.getJSONObject("arguments").getString("mode")
                )
            }
        }
    }

    private suspend fun runTransportCase(
        value: JSONObject,
        execute: suspend () -> Pair<JSONObject, JSONObject>
    ) {
        val id = value.getString("id")
        val record = JSONObject()
            .put("id", id)
            .put("operation", "transport_dispatch")
        try {
            val (request, result) = execute()
            requestPlan.put(request)
            record
                .put("request", request)
                .put("result", result)
                .put("issue", JSONObject.NULL)
        } catch (error: Throwable) {
            val request = fallbackTransportRequest(value)
            requestPlan.put(request)
            record
                .put("request", request)
                .put("result", JSONObject.NULL)
                .put(
                    "issue",
                    JSONObject()
                        .put("code", "android_exception")
                        .put("exception_type", error.javaClass.name)
                )
        }
        cases.put(record)
    }

    private fun transportAnalyze(value: JSONObject): AnalyzeUrl {
        val request = value.getJSONObject("request")
        val arguments = value.getJSONObject("arguments")
        val target = request.getString("target")
        val rawURL =
            if (target.startsWith("data:")) target else deviceOrigin + target
        if (arguments.getString("mode") == "client_policy") {
            return AnalyzeUrl(
                mUrl = rawURL,
                baseUrl = source.bookSourceUrl,
                source = source,
                readTimeout = arguments.getLong("read_timeout_ms"),
                headerMapF = mapOf(
                    "proxy" to arguments.getString("proxy"),
                    "X-Policy" to "source"
                )
            )
        }
        val option = JSONObject()
        if (request.getString("method") == "POST") {
            option
                .put("method", "POST")
                .put("body", arguments.getString("body"))
        }
        if (arguments.has("content_type")) {
            option.put(
                "headers",
                JSONObject().put(
                    "Content-Type",
                    arguments.getString("content_type")
                )
            )
        }
        if (arguments.has("type")) {
            option.put("type", arguments.getString("type"))
        }
        if (arguments.has("header_name")) {
            option.put(
                "headers",
                JSONObject().put(
                    arguments.getString("header_name"),
                    arguments.getString("header_value")
                )
            )
        }
        val ruleURL =
            if (option.length() == 0) rawURL else "$rawURL,$option"
        return AnalyzeUrl(
            mUrl = ruleURL,
            baseUrl = source.bookSourceUrl,
            source = source,
            headerMapF = source.getHeaderMap(true)
        )
    }

    private fun fallbackTransportRequest(value: JSONObject): JSONObject {
        val request = value.getJSONObject("request")
        val arguments = value.getJSONObject("arguments")
        val target = request.getString("target")
        val url =
            if (target.startsWith("data:")) target else deviceOrigin + target
        val result = request(url).put("method", request.getString("method"))
        if (arguments.has("body")) {
            result.put("body", arguments.getString("body"))
        }
        if (arguments.has("content_type")) {
            result.put(
                "headers",
                controlledHeaders(
                    listOf(
                        "Content-Type" to arguments.getString("content_type")
                    )
                )
            )
        }
        if (arguments.has("read_timeout_ms")) {
            result.put("timeout_ms", arguments.getInt("read_timeout_ms"))
        }
        return result
    }

    private fun observedRequest(
        value: Request,
        timeoutMillis: Int? = null
    ): JSONObject {
        val requestBody = value.body
        val body =
            if (requestBody == null) {
                null
            } else {
                Buffer().use { buffer ->
                    requestBody.writeTo(buffer)
                    buffer.readString(Charsets.UTF_8)
                }
            }
        val headers = buildList {
            for (index in 0 until value.headers.size) {
                add(
                    value.headers.name(index) to
                        value.headers.value(index)
                )
            }
        }
        return JSONObject()
            .put("method", value.method)
            .put("url", logical(value.url.toString()))
            .put("headers", controlledHeaders(headers))
            .put("body", nullable(body))
            .put("timeout_ms", timeoutMillis ?: JSONObject.NULL)
    }

    private fun analyzedRequest(
        analyze: AnalyzeUrl,
        timeoutMillis: Int? = null
    ): JSONObject =
        JSONObject()
            .put("method", if (analyze.isPost()) "POST" else "GET")
            .put("url", logical(analyze.url))
            .put(
                "headers",
                controlledHeaders(
                    analyze.headerMap.entries.map {
                        it.key to it.value
                    }
                )
            )
            .put(
                "body",
                if (analyze.isPost()) nullable(analyze.body) else JSONObject.NULL
            )
            .put("timeout_ms", timeoutMillis ?: JSONObject.NULL)

    private fun responseProjection(response: Response): JSONObject {
        val bytes = response.body?.bytes() ?: byteArrayOf()
        return JSONObject()
            .put("status_code", response.code)
            .put("final_url", logical(response.request.url.toString()))
            .put("body_base64", base64(bytes))
            .put("byte_count", bytes.size)
    }

    private fun reflectedClient(analyze: AnalyzeUrl): OkHttpClient {
        val method = AnalyzeUrl::class.java.getDeclaredMethod("getClient")
        method.isAccessible = true
        return try {
            method.invoke(analyze) as OkHttpClient
        } catch (error: InvocationTargetException) {
            throw error.targetException
        }
    }

    private fun base64(value: ByteArray): String =
        Base64.encodeToString(value, Base64.NO_WRAP)

    private fun rateLimitProjection(value: JSONObject): JSONObject {
        val id = value.getString("id")
        val arguments = value.getJSONObject("arguments")
        val mode = arguments.getString("mode")
        val rate = arguments.getString("concurrent_rate")
        fun analyze(key: String = id): AnalyzeUrl {
            val caseSource = GSON.fromJson(sourceJson, BookSource::class.java)
            caseSource.bookSourceUrl = "$deviceOrigin/rate-source/$key"
            caseSource.bookSourceName = "Rate $key"
            caseSource.concurrentRate = rate
            return AnalyzeUrl(
                mUrl = "$deviceOrigin/rate-limit/$id",
                baseUrl = caseSource.bookSourceUrl,
                source = caseSource,
                headerMapF = caseSource.getHeaderMap(true)
            )
        }

        return when (mode) {
            "disabled" -> {
                val record = reflectedFetchStart(analyze())
                JSONObject()
                    .put("active", record != null)
                    .put("rate", rate)
            }

            "interval_shared" -> {
                val first = requireNotNull(reflectedFetchStart(analyze()))
                val second = deniedWait(analyze())
                val frequencyOnDenial = first.frequency
                reflectedFetchEnd(analyze(), first)
                val afterEnd = deniedWait(analyze())
                JSONObject()
                    .put("first_allowed", true)
                    .put("second_same_key_denied", second > 0)
                    .put("after_end_still_denied", afterEnd > 0)
                    .put("record_mode", "minimum_interval")
                    .put("frequency_on_denial", frequencyOnDenial)
            }

            "window_boundary" -> {
                val limiter = analyze()
                var allowed = 0
                var record: AnalyzeUrl.ConcurrentRecord? = null
                var denied = 0
                repeat(4) {
                    try {
                        record = reflectedFetchStart(limiter)
                        allowed += 1
                    } catch (error: ConcurrentException) {
                        denied = error.waitTime
                    }
                }
                JSONObject()
                    .put("allowed_before_denial", allowed)
                    .put("denied_wait_positive", denied > 0)
                    .put("record_mode", "count_per_window")
                    .put("frequency_on_denial", requireNotNull(record).frequency)
            }

            "distinct_keys" -> {
                val first = requireNotNull(reflectedFetchStart(analyze("$id-a")))
                val second = requireNotNull(reflectedFetchStart(analyze("$id-b")))
                JSONObject()
                    .put("both_allowed", true)
                    .put("records_are_distinct", first !== second)
            }

            "invalid_degrades" -> {
                val limiter = analyze()
                val first = requireNotNull(reflectedFetchStart(limiter))
                val second = requireNotNull(reflectedFetchStart(limiter))
                JSONObject()
                    .put("both_allowed", true)
                    .put("same_record", first === second)
                    .put("is_count_window", first.isConcurrent)
                    .put("frequency_after_second", second.frequency)
            }

            else -> error("Unsupported rate limit mode: $mode")
        }
    }

    private fun reflectedFetchStart(
        analyze: AnalyzeUrl
    ): AnalyzeUrl.ConcurrentRecord? {
        val method = AnalyzeUrl::class.java.getDeclaredMethod("fetchStart")
        method.isAccessible = true
        return try {
            method.invoke(analyze) as? AnalyzeUrl.ConcurrentRecord
        } catch (error: InvocationTargetException) {
            throw error.targetException
        }
    }

    private fun reflectedFetchEnd(
        analyze: AnalyzeUrl,
        record: AnalyzeUrl.ConcurrentRecord
    ) {
        val method = AnalyzeUrl::class.java.getDeclaredMethod(
            "fetchEnd",
            AnalyzeUrl.ConcurrentRecord::class.java
        )
        method.isAccessible = true
        method.invoke(analyze, record)
    }

    private fun deniedWait(analyze: AnalyzeUrl): Int =
        try {
            reflectedFetchStart(analyze)
            0
        } catch (error: ConcurrentException) {
            error.waitTime
        }

    @Suppress("UNCHECKED_CAST")
    private fun reflectedFieldMap(
        analyze: AnalyzeUrl
    ): LinkedHashMap<String, String> {
        val field = AnalyzeUrl::class.java.getDeclaredField("fieldMap")
        field.isAccessible = true
        return field.get(analyze) as LinkedHashMap<String, String>
    }

    private fun reflectedString(analyze: AnalyzeUrl, name: String): String =
        requireNotNull(reflectedNullableString(analyze, name))

    private fun reflectedNullableString(
        analyze: AnalyzeUrl,
        name: String
    ): String? {
        val field = AnalyzeUrl::class.java.getDeclaredField(name)
        field.isAccessible = true
        return field.get(analyze) as? String
    }

    private fun reflectedInt(analyze: AnalyzeUrl, name: String): Int {
        val field = AnalyzeUrl::class.java.getDeclaredField(name)
        field.isAccessible = true
        return field.getInt(analyze)
    }

    private fun controlledHeaders(
        values: List<Pair<String, String>>
    ): JSONArray =
        JSONArray().apply {
            values
                .filter {
                    val name = it.first.lowercase()
                    name == "cookie" ||
                        name == "cookiejar" ||
                        name == "content-type" ||
                        name.startsWith("x-")
                }
                .sortedWith(
                    compareBy<Pair<String, String>>(
                        { it.first.lowercase() },
                        { it.first },
                        { it.second }
                    )
                )
                .forEach { (name, value) ->
                    put(
                        JSONObject()
                            .put("name", name)
                            .put("value", value)
                    )
                }
        }

    private fun postSearchRequest(keyword: String): JSONObject {
        val analyze = AnalyzeUrl(
            mUrl = requireNotNull(source.searchUrl),
            key = keyword,
            page = 1,
            baseUrl = source.bookSourceUrl,
            source = source,
            headerMapF = source.getHeaderMap(true)
        )
        require(analyze.isPost()) {
            "POST form scenario did not produce POST"
        }
        val field = AnalyzeUrl::class.java.getDeclaredField("fieldMap")
        field.isAccessible = true
        @Suppress("UNCHECKED_CAST")
        val fields = field.get(analyze) as LinkedHashMap<String, String>
        val body = fields.entries.joinToString("&") {
            "${it.key}=${it.value}"
        }
        return JSONObject()
            .put("method", "POST")
            .put("url", logical(analyze.url))
            .put(
                "headers",
                JSONArray().apply {
                    analyze.headerMap.entries
                        .sortedBy { it.key.lowercase() }
                        .forEach {
                            put(
                                JSONObject()
                                    .put("name", it.key)
                                    .put("value", it.value)
                            )
                        }
                }
            )
            .put("body", body)
            .put(
                "body_base64",
                Base64.encodeToString(
                    body.toByteArray(Charsets.UTF_8),
                    Base64.NO_WRAP
                )
            )
            .put(
                "form_fields",
                JSONArray().apply {
                    fields.forEach { (key, value) ->
                        put(
                            JSONObject()
                                .put("key", key)
                                .put("value", value)
                        )
                    }
                }
            )
            .put("timeout_ms", JSONObject.NULL)
    }

    private suspend fun contentProjection(
        relativeURL: String,
        index: Int
    ): JSONObject {
        val book = Book(
            bookUrl = "$deviceOrigin/books/star-river/index.html",
            tocUrl = "$deviceOrigin/books/star-river/toc.html",
            origin = source.bookSourceUrl,
            originName = source.bookSourceName,
            name = "星河纪事"
        )
        val chapter = BookChapter(
            url = relativeURL,
            title = "",
            baseUrl = "$deviceOrigin/books/star-river/toc.html",
            bookUrl = book.bookUrl,
            index = index
        )
        val value = WebBook.getContentAwait(
            source,
            book,
            chapter,
            needSave = false
        )
        return JSONObject()
            .put("content", value.replace(deviceOrigin, logicalOrigin))
            .put("chapter_url", logical(chapter.getAbsoluteURL()))
    }

    private suspend fun runCase(
        id: String,
        operation: String,
        request: JSONObject,
        execute: suspend () -> JSONObject
    ) {
        requestPlan.put(request)
        val record = JSONObject()
            .put("id", id)
            .put("operation", operation)
            .put("request", request)
        try {
            record
                .put("result", execute())
                .put("issue", JSONObject.NULL)
        } catch (error: Throwable) {
            Log.e(
                "LegadoOracle",
                "case=$id operation=$operation failed",
                error
            )
            record
                .put("result", JSONObject.NULL)
                .put(
                    "issue",
                    JSONObject()
                        .put("code", "android_exception")
                        .put("exception_type", error.javaClass.name)
                )
        }
        cases.put(record)
    }

    private fun searchRequest(keyword: String): JSONObject {
        val analyze = AnalyzeUrl(
            mUrl = requireNotNull(source.searchUrl),
            key = keyword,
            page = 1,
            baseUrl = source.bookSourceUrl,
            source = source,
            headerMapF = source.getHeaderMap(true)
        )
        return request(analyze.url)
    }

    private fun request(url: String): JSONObject =
        JSONObject()
            .put("method", "GET")
            .put("url", logical(url))
            .put("headers", JSONArray())
            .put("body", JSONObject.NULL)
            .put("timeout_ms", JSONObject.NULL)

    private fun searchProjection(values: List<SearchBook>): JSONObject =
        JSONObject().put(
            "books",
            JSONArray().apply {
                values.forEach { value ->
                    put(
                        JSONObject()
                            .put("name", value.name)
                            .put("author", value.author)
                            .put("kind", nullable(value.kind))
                            .put("intro", nullable(value.intro))
                            .put("last_chapter", nullable(value.latestChapterTitle))
                            .put("book_url", logical(value.bookUrl))
                            .put("cover_url", nullableURL(value.coverUrl))
                    )
                }
            }
        )

    private fun bookProjection(value: Book): JSONObject =
        JSONObject()
            .put("name", value.name)
            .put("author", value.author)
            .put("kind", nullable(value.kind))
            .put("intro", nullable(value.intro))
            .put("last_chapter", nullable(value.latestChapterTitle))
            .put("book_url", logical(value.bookUrl))
            .put("toc_url", logical(value.tocUrl))
            .put("cover_url", nullableURL(value.coverUrl))

    private fun chapterProjection(values: List<BookChapter>): JSONObject =
        JSONObject().put(
            "chapters",
            JSONArray().apply {
                values.forEach { value ->
                    put(
                        JSONObject()
                            .put("index", value.index)
                            .put("title", value.title)
                            .put("url", logical(value.getAbsoluteURL()))
                            .put("is_volume", value.isVolume)
                            .put("is_vip", value.isVip)
                            .put("is_pay", value.isPay)
                    )
                }
            }
        )

    private fun nullable(value: String?): Any =
        value ?: JSONObject.NULL

    private fun nullableURL(value: String?): Any =
        value?.let(::logical) ?: JSONObject.NULL

    private fun logical(value: String): String =
        if (value.startsWith(deviceOrigin)) {
            logicalOrigin + value.removePrefix(deviceOrigin)
        } else {
            value
        }

    private fun requiredArgument(name: String): String =
        requireNotNull(arguments.getString(name)) {
            "Missing instrumentation argument: $name"
        }

    companion object {
        const val OUTPUT_FILE = "legado-oracle-raw.json"
    }
}

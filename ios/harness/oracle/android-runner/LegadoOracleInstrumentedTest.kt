package io.legado.app.oracle

import android.util.Base64
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import io.legado.app.data.entities.Book
import io.legado.app.data.entities.BookChapter
import io.legado.app.data.entities.BookSource
import io.legado.app.data.entities.Bookmark
import io.legado.app.data.entities.SearchBook
import io.legado.app.data.appDb
import io.legado.app.exception.ConcurrentException
import io.legado.app.help.CacheManager
import io.legado.app.help.book.BookHelp
import io.legado.app.help.http.CookieManager
import io.legado.app.help.http.CookieStore
import io.legado.app.help.http.StrResponse
import io.legado.app.help.http.newCallResponse
import io.legado.app.model.CacheBook
import io.legado.app.model.analyzeRule.AnalyzeRule
import io.legado.app.model.analyzeRule.AnalyzeUrl
import io.legado.app.model.analyzeRule.RuleData
import io.legado.app.model.webBook.WebBook
import io.legado.app.utils.GSON
import io.legado.app.utils.NetworkUtils
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File
import java.io.IOException
import java.lang.reflect.InvocationTargetException
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
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
        if (isAndroidRuntimeScenario) {
            "android-runtime://local"
        } else {
            source.bookSourceUrl.trimEnd('/')
        }
    }
    private val cases = JSONArray()
    private val requestPlan = JSONArray()

    @Test
    fun runCharacterization() = runBlocking {
        if (!isAndroidRuntimeScenario) {
            require(deviceOrigin.startsWith("http://127.0.0.1:")) {
                "Oracle source must use the run-scoped device loopback origin"
            }
            source.enabledCookieJar =
                scenarioId == "sl-source-request-header-cookie-retry-layering-001" ||
                    scenarioId == "sl-source-cookie-persistent-session-merge-runtime-001"
        }

        when (scenarioId) {
            "rl-reader-bookmark-search-runtime-risk-001" ->
                runBookmarkRuntimeCases()
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

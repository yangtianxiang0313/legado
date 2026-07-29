package io.legado.app.oracle

import android.util.Base64
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import io.legado.app.data.entities.Book
import io.legado.app.data.entities.BookChapter
import io.legado.app.data.entities.BookSource
import io.legado.app.data.entities.SearchBook
import io.legado.app.help.http.CookieStore
import io.legado.app.model.analyzeRule.AnalyzeUrl
import io.legado.app.model.webBook.WebBook
import io.legado.app.utils.GSON
import kotlinx.coroutines.runBlocking
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File

@RunWith(AndroidJUnit4::class)
class LegadoOracleInstrumentedTest {
    private val arguments = InstrumentationRegistry.getArguments()
    private val logicalOrigin = requiredArgument("logicalOrigin").trimEnd('/')
    private val scenarioId = requiredArgument("scenarioId")
    private val input = JSONObject(
        String(
            Base64.decode(
                requiredArgument("inputBase64"),
                Base64.DEFAULT
            ),
            Charsets.UTF_8
        )
    )
    private val sourceJson = String(
        Base64.decode(requiredArgument("sourceBase64"), Base64.DEFAULT),
        Charsets.UTF_8
    )
    private val source = GSON.fromJson(sourceJson, BookSource::class.java)
    private val deviceOrigin = source.bookSourceUrl.trimEnd('/')
    private val cases = JSONArray()
    private val requestPlan = JSONArray()

    @Test
    fun runSourceLabCharacterization() = runBlocking {
        require(deviceOrigin.startsWith("http://127.0.0.1:")) {
            "Oracle source must use the run-scoped device loopback origin"
        }
        source.enabledCookieJar =
            scenarioId == "sl-source-request-header-cookie-retry-layering-001"

        when (scenarioId) {
            "sl-post-form-001" -> runPostFormCases()
            "sl-source-response-xml-declaration-normalization-001" ->
                runXmlResponseCases()
            "sl-source-request-header-cookie-retry-layering-001" ->
                runRequestOptionCases()
            "sl-source-request-field-encoding-runtime-001" ->
                runFieldEncodingCases()
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

    private fun controlledHeaders(
        values: List<Pair<String, String>>
    ): JSONArray =
        JSONArray().apply {
            values
                .filter {
                    val name = it.first.lowercase()
                    name == "cookie" ||
                        name == "cookiejar" ||
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

package io.legado.app.oracle

import android.util.Base64
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import io.legado.app.data.entities.Book
import io.legado.app.data.entities.BookChapter
import io.legado.app.data.entities.BookSource
import io.legado.app.data.entities.SearchBook
import io.legado.app.exception.ConcurrentException
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
import java.lang.reflect.InvocationTargetException
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okio.Buffer

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
            "sl-source-request-url-template-compilation-001" ->
                runURLTemplateCompilationCases()
            "sl-source-session-rate-limit-shared-state-001" ->
                runRateLimitStateCases()
            "sl-source-transport-request-dispatch-contract-001" ->
                runTransportDispatchCases()
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

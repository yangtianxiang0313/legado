import AppUseCases
import Foundation
import LibraryDomain
import SourceRuntime

@MainActor
enum SearchEnvironment {
    private static let cookieStore = SourceCookieStore(
        persistence: UserDefaultsSourceCookiePersistence()
    )

    static func makeSession(
        persistedSources: [BookSourceDraft] = []
    ) -> SearchSession {
        let externalBaseURL = ProcessInfo.processInfo.environment[
            "LEGADO_SEARCH_BASE_URL"
        ]
        let baseURL = externalBaseURL ?? "http://legado.local"
        let transport = makeTransport(externalBaseURL: externalBaseURL)
        let sources = makeSources(
            baseURL: baseURL,
            persistedSources: persistedSources
        )
        return SearchSession(
            groups: Array(Set(sources.map(\.group))).sorted(),
            executor: SourceSearchBooksExecutor(
                sources: sources,
                transport: transport,
                cookieStore: cookieStore
            )
        )
    }

    static func exploreSources(
        persistedSources: [BookSourceDraft] = []
    ) -> [ExploreSourceSummary] {
        makeSources(
            baseURL: ProcessInfo.processInfo.environment[
                "LEGADO_SEARCH_BASE_URL"
            ] ?? "http://legado.local",
            persistedSources: persistedSources,
            includeDisabled: true
        ).compactMap { descriptor in
            guard descriptor.exploreDefinition?.enabled == true else {
                return nil
            }
            return ExploreSourceSummary(
                id: descriptor.id,
                name: descriptor.name,
                group: descriptor.group
            )
        }
    }

    static func sourceSwitchTargets(
        persistedSources: [BookSourceDraft] = []
    ) -> [BookSourceDraft] {
        let baseURL = ProcessInfo.processInfo.environment[
            "LEGADO_SEARCH_BASE_URL"
        ] ?? "http://legado.local"
        let builtIn = [
            BookSourceDraft(
                sourceURL: "\(baseURL)/source/science-fiction",
                name: "本地科幻书源",
                group: "科幻"
            ),
            BookSourceDraft(
                sourceURL: "\(baseURL)/source/fantasy",
                name: "本地奇幻书源",
                group: "奇幻"
            ),
        ]
        let builtInIDs = Set(builtIn.map(\.sourceURL))
        return builtIn + persistedSources.filter {
            !builtInIDs.contains($0.sourceURL)
        }
    }

    static func makeExploreSession(
        sourceID: String,
        persistedSources: [BookSourceDraft] = []
    ) -> ExploreSession {
        let externalBaseURL = ProcessInfo.processInfo.environment[
            "LEGADO_SEARCH_BASE_URL"
        ]
        let baseURL = externalBaseURL ?? "http://legado.local"
        let descriptors = makeSources(
            baseURL: baseURL,
            persistedSources: persistedSources,
            includeDisabled: true
        ).compactMap { source -> ExploreSourceDescriptor? in
            guard
                let definition = source.exploreDefinition,
                definition.enabled
            else {
                return nil
            }
            return ExploreSourceDescriptor(
                summary: ExploreSourceSummary(
                    id: source.id,
                    name: source.name,
                    group: source.group
                ),
                definition: definition
            )
        }
        let executor = SourceExploreBooksExecutor(
            descriptors: descriptors,
            transport: makeTransport(externalBaseURL: externalBaseURL)
        )
        let summary = executor.sources.first(where: {
            $0.id == sourceID
        }) ?? ExploreSourceSummary(
            id: sourceID,
            name: sourceID,
            group: ""
        )
        return ExploreSession(source: summary, executor: executor)
    }

    static func makeChapterLoader(
        persistedSources: [BookSourceDraft] = []
    ) -> any BookChapterLoading {
        let externalBaseURL = ProcessInfo.processInfo.environment[
            "LEGADO_SEARCH_BASE_URL"
        ]
        let baseURL = externalBaseURL ?? "http://legado.local"
        return SourceBookChapterLoader(
            sources: makeSources(
                baseURL: baseURL,
                persistedSources: persistedSources,
                includeDisabled: true
            ),
            transport: makeTransport(externalBaseURL: externalBaseURL),
            cookieStore: cookieStore
        )
    }

    static func makeReaderContentLoader(
        persistedSources: [BookSourceDraft] = []
    ) -> any ReaderContentLoading {
        let externalBaseURL = ProcessInfo.processInfo.environment[
            "LEGADO_SEARCH_BASE_URL"
        ]
        let baseURL = externalBaseURL ?? "http://legado.local"
        return SourceReaderContentLoader(
            sources: makeSources(
                baseURL: baseURL,
                persistedSources: persistedSources,
                includeDisabled: true
            ),
            transport: makeTransport(externalBaseURL: externalBaseURL),
            cookieStore: cookieStore
        )
    }

    static func importBookURL(
        _ rawValue: String,
        library: ShelfLibrary,
        persistedSources: [BookSourceDraft] = []
    ) async throws -> ShelfBookItem {
        let value = rawValue.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard
            let bookEndpoint = try? SourceEndpoint(
                resolving: value,
                relativeTo: URL(string: "http://legado.invalid")!
            ),
            let baseURL = originBaseURL(bookEndpoint.logicalURL)
        else {
            throw BookURLImportEnvironmentError.invalidURL
        }
        let logicalBookURL = bookEndpoint.logicalURL.absoluteString
        if let existing = await library.item(forURL: logicalBookURL) {
            return existing
        }

        let externalBaseURL = ProcessInfo.processInfo.environment[
            "LEGADO_SEARCH_BASE_URL"
        ]
        let environmentBaseURL = externalBaseURL ?? "http://legado.local"
        let sources = makeSources(
            baseURL: environmentBaseURL,
            persistedSources: persistedSources,
            includeDisabled: true
        )
        let matches = sources.map { source in
            RemoteBookSourceCandidate(
                sourceID: source.id,
                sourceName: source.name,
                match: source.definition.sourceURL == baseURL
                    ? .exactBase
                    : patternMatch(
                        source.definition.bookURLPattern,
                        value: logicalBookURL
                    )
            )
        }
        guard
            let selectedIndex = matches.firstIndex(where: {
                $0.match == .exactBase
            }) ?? matches.firstIndex(where: {
                $0.match == .pattern
            })
        else {
            throw BookURLImportEnvironmentError.sourceNotFound
        }
        let selected = sources[selectedIndex]
        let execution = try await SourceBookInfoPipeline(
            definition: selected.definition,
            transport: makeTransport(externalBaseURL: externalBaseURL),
            cookieStore: cookieStore
        ).load(
            book: SourceBook(
                name: "",
                author: nil,
                intro: nil,
                kind: nil,
                lastChapter: nil,
                bookEndpoint: bookEndpoint,
                coverURL: nil,
                tocEndpoint: nil
            )
        )
        let resolved = RemoteBookImporter.resolve(
            existingBook: nil,
            orderedSources: matches,
            fetchedBook: ImportedBook(
                id: LibraryDomain.BookID(rawValue: logicalBookURL),
                name: execution.book.name,
                author: normalizedAuthor(execution.book.author ?? ""),
                originName: selected.name,
                originKind: matches[selectedIndex].match == .exactBase
                    ? .exactBase
                    : .pattern,
                isLocal: false,
                isArchive: false,
                chapterCount: 0
            )
        )
        guard resolved.outcome == .added else {
            throw BookURLImportEnvironmentError.fetchFailed
        }
        let candidate = ShelfBookCandidate(
            name: execution.book.name,
            author: normalizedAuthor(execution.book.author ?? ""),
            kind: execution.book.kind ?? "",
            lastChapter: execution.book.lastChapter ?? "",
            intro: execution.book.intro ?? "",
            bookURL: execution.book.bookURL.absoluteString,
            bookRequestExpression:
                execution.book.bookEndpoint.requestExpression,
            coverURL: execution.book.coverURL?.absoluteString,
            originName: selected.name,
            sourceID: selected.id
        )
        await library.add(candidate)
        guard
            let item = await library.item(forURL: logicalBookURL)
        else {
            throw BookURLImportEnvironmentError.persistenceFailed
        }
        let toc = library.chapterSession(
            loader: SourceBookChapterLoader(
                sources: [selected],
                transport: makeTransport(
                    externalBaseURL: externalBaseURL
                ),
                cookieStore: cookieStore
            )
        )
        await toc.load(book: item, force: true)
        guard
            let reloaded = await library.item(forURL: logicalBookURL)
        else {
            throw BookURLImportEnvironmentError.persistenceFailed
        }
        return reloaded
    }

    static func resolveSourceSwitch(
        current: ShelfBookItem,
        target: BookSourceDraft,
        persistedSources: [BookSourceDraft]
    ) async throws -> (
        candidate: ShelfBookCandidate,
        chapters: [LibraryDomain.BookChapter]
    ) {
        let externalBaseURL = ProcessInfo.processInfo.environment[
            "LEGADO_SEARCH_BASE_URL"
        ]
        let baseURL = externalBaseURL ?? "http://legado.local"
        let sources = makeSources(
            baseURL: baseURL,
            persistedSources: persistedSources,
            includeDisabled: true
        )
        guard let descriptor = sources.first(where: {
            $0.id == target.sourceURL
        }) else {
            throw SourceSwitchEnvironmentError.unsupportedSource
        }
        let transport = makeTransport(externalBaseURL: externalBaseURL)
        let results = try await SourceSearchBooksExecutor(
            sources: [descriptor],
            transport: transport,
            cookieStore: cookieStore
        ).search(
            query: current.candidate.name,
            scope: .source(
                name: descriptor.name,
                identifier: descriptor.id
            )
        )
        guard let result = results.first(where: {
            $0.name == current.candidate.name
                && normalizedAuthor($0.author)
                    == normalizedAuthor(current.candidate.author)
        }) ?? results.first else {
            throw SourceSwitchEnvironmentError.bookNotFound
        }
        let candidate = ShelfBookCandidate(
            name: result.name,
            author: result.author,
            kind: result.kind,
            lastChapter: result.lastChapter,
            intro: result.intro,
            bookURL: result.bookURL,
            bookRequestExpression: result.bookRequestExpression,
            coverURL: result.coverURL,
            originName: result.originName,
            sourceID: descriptor.id
        )
        let transient = ShelfBookItem(
            id: current.id,
            candidate: candidate,
            membership: current.membership,
            order: current.order,
            chapterCount: current.chapterCount,
            progress: current.progress
        )
        let chapters = try await SourceBookChapterLoader(
            sources: [descriptor],
            transport: transport,
            cookieStore: cookieStore
        ).load(book: transient)
        return (candidate, chapters)
    }

    private static func makeTransport(
        externalBaseURL: String?
    ) -> any HTTPTransport {
        if ProcessInfo.processInfo.arguments.contains(
            "--offline-source-transport"
        ) {
            return OfflineBookSourceTransport()
        }
        if externalBaseURL == nil {
            return LocalBookSourceTransport()
        }
        return URLSessionBookSourceTransport()
    }

    private static func makeSources(
        baseURL: String,
        persistedSources: [BookSourceDraft] = [],
        includeDisabled: Bool = false
    ) -> [SearchSourceDescriptor] {
        var values = [
            source(
                baseURL: baseURL,
                id: "\(baseURL)/source/science-fiction",
                name: "本地科幻书源",
                group: "科幻",
                order: 0
            ),
            source(
                baseURL: baseURL,
                id: "\(baseURL)/source/fantasy",
                name: "本地奇幻书源",
                group: "奇幻",
                order: 1
            ),
        ]
        for draft in persistedSources {
            guard
                includeDisabled
                    || (draft.importMetadata?.enabled ?? true),
                let descriptor = persistedSource(draft)
            else { continue }
            if let index = values.firstIndex(where: {
                $0.id == descriptor.id
            }) {
                values[index] = descriptor
            } else {
                values.append(descriptor)
            }
        }
        return values
    }

    private static func persistedSource(
        _ draft: BookSourceDraft
    ) -> SearchSourceDescriptor? {
        guard
            let data = draft.rawDefinition,
            let root = try? JSONSerialization.jsonObject(with: data)
                as? [String: Any],
            let search = root["ruleSearch"] as? [String: Any],
            let info = root["ruleBookInfo"] as? [String: Any],
            let toc = root["ruleToc"] as? [String: Any],
            let content = root["ruleContent"] as? [String: Any],
            let searchURL = string(root, "searchUrl"),
            !searchURL.isEmpty,
            let list = string(search, "bookList"),
            let searchName = string(search, "name"),
            let searchAuthor = string(search, "author"),
            let searchBookURL = string(search, "bookUrl"),
            let infoName = string(info, "name"),
            let infoAuthor = string(info, "author"),
            let tocURL = string(info, "tocUrl"),
            let chapterList = string(toc, "chapterList"),
            let chapterName = string(toc, "chapterName"),
            let chapterURL = string(toc, "chapterUrl"),
            let contentRule = string(content, "content")
        else {
            return nil
        }
        let sourceURL = draft.sourceURL
        let runtime = HTMLCSSSourceDefinition(
                    searchURLTemplate: searchURL,
                    search: SearchRules(
                        list: list,
                        name: HTMLCSSRule(searchName),
                        author: HTMLCSSRule(searchAuthor),
                        intro: .optional(
                            string(search, "intro")
                        ),
                        kind: .optional(
                            string(search, "kind")
                        ),
                        wordCount: .optional(
                            string(search, "wordCount")
                        ),
                        lastChapter: .optional(
                            string(search, "lastChapter")
                        ),
                        bookURL: HTMLCSSRule(
                            searchBookURL,
                            value: .href
                        ),
                        coverURL: .optional(
                            string(search, "coverUrl"),
                            value: .src
                        )
                    ),
                    explore: (root["ruleExplore"] as? [String: Any])
                        .flatMap(exploreRules),
                    bookInfo: BookInfoRules(
                        name: HTMLCSSRule(infoName),
                        author: HTMLCSSRule(infoAuthor),
                        intro: .optional(
                            string(info, "intro")
                        ),
                        kind: .optional(
                            string(info, "kind")
                        ),
                        lastChapter: .optional(
                            string(info, "lastChapter")
                        ),
                        coverURL: .optional(
                            string(info, "coverUrl"),
                            value: .src
                        ),
                        tocURL: HTMLCSSRule(tocURL, value: .href)
                    ),
                    toc: TOCRules(
                        list: chapterList,
                        name: HTMLCSSRule(chapterName),
                        url: HTMLCSSRule(chapterURL, value: .href)
                    ),
                    content: ContentRules(
                        content: HTMLCSSRule(
                            contentRule,
                            value: .html
                        )
                    )
                )
        let searchDefinition = SourceSearchDefinition(
            sourceURL: sourceURL,
            sourceName: draft.name,
            originOrder: Int(
                draft.importMetadata?.customOrder ?? 0
            ),
            bookURLPattern: string(root, "bookUrlPattern"),
            sourceHeaders: sourceHeaders(root),
            enabledCookieJar: root["enabledCookieJar"] as? Bool ?? false,
            runtime: runtime
        )
        let catalog = (
            string(root, "exploreUrl") ?? draft.exploreURL
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        let exploreDefinition = catalog.isEmpty
            ? nil
            : SourceExploreDefinition(
                source: searchDefinition,
                enabled: draft.importMetadata?.enabledExplore ?? true,
                catalog: catalog
            )
        return SearchSourceDescriptor(
            id: sourceURL,
            name: draft.name,
            group: draft.group,
            definition: searchDefinition,
            exploreDefinition: exploreDefinition
        )
    }

    private static func exploreRules(
        _ object: [String: Any]
    ) -> SearchRules? {
        guard
            let list = string(object, "bookList"),
            !list.isEmpty,
            let name = string(object, "name"),
            !name.isEmpty,
            let bookURL = string(object, "bookUrl"),
            !bookURL.isEmpty
        else {
            return nil
        }
        return SearchRules(
            list: list,
            name: HTMLCSSRule(name),
            author: .optional(string(object, "author")),
            intro: .optional(string(object, "intro")),
            kind: .optional(string(object, "kind")),
            wordCount: .optional(string(object, "wordCount")),
            lastChapter: .optional(string(object, "lastChapter")),
            bookURL: HTMLCSSRule(bookURL, value: .href),
            coverURL: .optional(
                string(object, "coverUrl"),
                value: .src
            )
        )
    }

    private static func string(
        _ object: [String: Any],
        _ key: String
    ) -> String? {
        guard let value = object[key] as? String else { return nil }
        return value
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func sourceHeaders(
        _ object: [String: Any]
    ) -> [SourceHeaderField] {
        let values: [String: Any]
        if let direct = object["header"] as? [String: Any] {
            values = direct
        } else if
            let raw = object["header"] as? String,
            let data = raw.data(using: .utf8),
            let decoded = try? JSONSerialization.jsonObject(with: data)
                as? [String: Any]
        {
            values = decoded
        } else {
            return []
        }
        return values.compactMap { name, value in
            guard let string = value as? String else { return nil }
            return try? SourceHeaderField(name: name, value: string)
        }.sorted {
            let left = $0.name.lowercased()
            let right = $1.name.lowercased()
            return left == right ? $0.name < $1.name : left < right
        }
    }

    private static func normalizedAuthor(_ value: String) -> String {
        value.replacingOccurrences(of: "作者：", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func source(
        baseURL: String,
        id: String,
        name: String,
        group: String,
        order: Int
    ) -> SearchSourceDescriptor {
        let definition = SourceSearchDefinition(
            sourceURL: id,
            sourceName: name,
            originOrder: order,
            bookURLPattern:
                #"^"# + NSRegularExpression.escapedPattern(
                    for: baseURL
                ) + #"/books/"#,
            runtime: HTMLCSSSourceDefinition(
                searchURLTemplate:
                    "\(baseURL)/search?source=\(group)&q={{key}}",
                search: SearchRules(
                    list: ".book-item",
                    name: HTMLCSSRule(".book-name"),
                    author: HTMLCSSRule(".book-author"),
                    intro: HTMLCSSRule(".book-intro"),
                    kind: HTMLCSSRule(".book-kind"),
                    wordCount: HTMLCSSRule(".book-word-count"),
                    lastChapter: HTMLCSSRule(".book-last-chapter"),
                    bookURL: HTMLCSSRule(
                        "a.book-link",
                        value: .href
                    ),
                    coverURL: HTMLCSSRule(
                        "img.book-cover",
                        value: .src
                    )
                ),
                bookInfo: BookInfoRules(
                    name: HTMLCSSRule("h1.book-name"),
                    author: HTMLCSSRule(".book-author"),
                    intro: HTMLCSSRule(".book-intro"),
                    kind: HTMLCSSRule(".book-kind"),
                    lastChapter: HTMLCSSRule(".book-last-chapter"),
                    coverURL: HTMLCSSRule(
                        "img.book-cover",
                        value: .src
                    ),
                    tocURL: HTMLCSSRule(
                        "a.toc-link",
                        value: .href
                    )
                ),
                toc: TOCRules(
                    list: ".chapter",
                    name: HTMLCSSRule("a"),
                    url: HTMLCSSRule("a", value: .href)
                ),
                content: ContentRules(
                    content: HTMLCSSRule(
                        "#content",
                        value: .html
                    )
                )
            )
        )
        return SearchSourceDescriptor(
            id: id,
            name: name,
            group: group,
            definition: definition,
            exploreDefinition: SourceExploreDefinition(
                source: definition,
                enabled: true,
                catalog:
                    "\(group)精选::\(baseURL)/explore/"
                    + "{{page}}?source=\(group)"
            )
        )
    }

    private static func originBaseURL(_ url: URL) -> String? {
        guard let scheme = url.scheme, let host = url.host else {
            return nil
        }
        var value = "\(scheme)://\(host)"
        if let port = url.port {
            value += ":\(port)"
        }
        return value
    }

    private static func patternMatch(
        _ pattern: String?,
        value: String
    ) -> RemoteBookSourceMatch {
        guard let pattern, !pattern.isEmpty else { return .none }
        do {
            let expression = try NSRegularExpression(pattern: pattern)
            let range = NSRange(value.startIndex..., in: value)
            return expression.firstMatch(
                in: value,
                range: range
            ) == nil ? .none : .pattern
        } catch {
            return .invalidPattern
        }
    }
}

private enum SourceSwitchEnvironmentError: Error {
    case unsupportedSource
    case bookNotFound
}

private enum BookURLImportEnvironmentError: Error {
    case invalidURL
    case sourceNotFound
    case fetchFailed
    case persistenceFailed
}

private actor OfflineBookSourceTransport: HTTPTransport {
    func execute(_ request: HTTPRequest) async throws -> HTTPResponse {
        throw HTTPTransportFailure.connectionFailed
    }
}

private actor LocalBookSourceTransport: HTTPTransport {
    func execute(_ request: HTTPRequest) async throws -> HTTPResponse {
        let components = URLComponents(
            string: request.url.absoluteString
        )
        let path = components?.path ?? ""
        let body: String
        if path.hasPrefix("/explore/") {
            body = exploreHTML(
                path: path,
                components: components
            )
        } else if let book = Self.books.first(where: { $0.path == path }) {
            body = book.detailHTML
        } else if let book = Self.books.first(
            where: { "\($0.path)/toc" == path }
        ) {
            body = book.tocHTML
        } else if let match = Self.books.compactMap({
            $0.chapterHTML(path: path)
        }).first {
            body = match
        } else {
            body = searchHTML(components: components)
        }
        return try HTTPResponse(
            statusCode: 200,
            effectiveURL: request.url,
            body: HTTPBody(Data(body.utf8))
        )
    }

    private func searchHTML(
        components: URLComponents?
    ) -> String {
        let query = components?.queryItems?.first {
            $0.name == "q"
        }?.value ?? ""
        let group = components?.queryItems?.first {
            $0.name == "source"
        }?.value ?? ""
        let books = Self.books.filter {
            ($0.name.contains(query) || $0.author.contains(query))
                && (group.isEmpty || $0.group == group)
        }
        let html = books.map(\.html).joined(separator: "\n")
        return "<html><body>\(html)</body></html>"
    }

    private func exploreHTML(
        path: String,
        components: URLComponents?
    ) -> String {
        let page = Int(path.split(separator: "/").last ?? "") ?? 1
        let group = components?.queryItems?.first {
            $0.name == "source"
        }?.value ?? ""
        let books = page == 1
            ? Self.books.filter { group.isEmpty || $0.group == group }
            : []
        return "<html><body>"
            + books.map(\.html).joined(separator: "\n")
            + "</body></html>"
    }

    private static let books = [
        LocalBook(
            name: "星河纪事",
            author: "林舟",
            group: "科幻",
            kind: "科幻,冒险",
            lastChapter: "第二章 回声",
            intro: "远航者在群星之间追索失落信标。",
            path: "/books/star-river"
        ),
        LocalBook(
            name: "星河之外",
            author: "顾岚",
            group: "科幻",
            kind: "科幻",
            lastChapter: "第十章 归航",
            intro: "一次跨越边境星云的归航。",
            path: "/books/beyond-stars"
        ),
        LocalBook(
            name: "奇幻星河",
            author: "苏遥",
            group: "奇幻",
            kind: "奇幻",
            lastChapter: "第五章 星门",
            intro: "魔法星门连接了两片大陆。",
            path: "/books/fantasy-river"
        ),
    ]
}

private struct LocalBook: Sendable {
    let name: String
    let author: String
    let group: String
    let kind: String
    let lastChapter: String
    let intro: String
    let path: String

    var html: String {
        """
        <article class="book-item">
          <a class="book-link" href="\(path)"></a>
          <span class="book-name">\(name)</span>
          <span class="book-author">作者：\(author)</span>
          <span class="book-kind">\(kind)</span>
          <span class="book-last-chapter">\(lastChapter)</span>
          <p class="book-intro">\(intro)</p>
        </article>
        """
    }

    var detailHTML: String {
        """
        <html><body>
          <h1 class="book-name">\(name)</h1>
          <span class="book-author">作者：\(author)</span>
          <span class="book-kind">\(kind)</span>
          <span class="book-last-chapter">\(lastChapter)</span>
          <p class="book-intro">\(intro)</p>
          <a class="toc-link" href="\(path)/toc">目录</a>
        </body></html>
        """
    }

    var tocHTML: String {
        """
        <html><body>
          <div class="chapter"><a href="\(path)/chapter-1">第一章 启航</a></div>
          <div class="chapter"><a href="\(path)/chapter-2">第二章 回声</a></div>
          <div class="chapter"><a href="\(path)/chapter-3">第三章 归途</a></div>
        </body></html>
        """
    }

    func chapterHTML(path requestedPath: String) -> String? {
        let chapters = [
            (
                "\(path)/chapter-1",
                "第一章 启航",
                ["星港的晨光越过舷窗。", "远航者点亮了失落信标。"]
            ),
            (
                "\(path)/chapter-2",
                "第二章 回声",
                ["信号从群星深处返回。", "每一次回声都更接近真相。"]
            ),
            (
                "\(path)/chapter-3",
                "第三章 归途",
                ["舰队沿着星图驶向故乡。", "新的旅程已经在地平线等待。"]
            ),
        ]
        guard let chapter = chapters.first(
            where: { $0.0 == requestedPath }
        ) else { return nil }
        let paragraphs = chapter.2.map { "<p>\($0)</p>" }.joined()
        return """
        <html><body>
          <h1>\(chapter.1)</h1>
          <div id="content">\(paragraphs)</div>
        </body></html>
        """
    }
}

private struct URLSessionBookSourceTransport: HTTPTransport {
    func execute(_ request: HTTPRequest) async throws -> HTTPResponse {
        guard let url = URL(string: request.url.absoluteString) else {
            throw HTTPTransportFailure.invalidRequest
        }
        var value = URLRequest(url: url)
        value.httpMethod = request.method.rawValue
        for header in request.headers.fields {
            value.addValue(header.value, forHTTPHeaderField: header.name)
        }
        value.httpBody = request.body?.bytes
        do {
            let (data, response) = try await URLSession.shared.data(
                for: value
            )
            guard let http = response as? HTTPURLResponse else {
                throw HTTPTransportFailure.invalidResponse
            }
            return try HTTPResponse(
                statusCode: http.statusCode,
                effectiveURL: HTTPURL(
                    http.url?.absoluteString
                        ?? request.url.absoluteString
                ),
                body: HTTPBody(data)
            )
        } catch let failure as HTTPTransportFailure {
            throw failure
        } catch {
            throw HTTPTransportFailure.connectionFailed
        }
    }
}

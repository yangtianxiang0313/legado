import AppUseCases
import Foundation
import SourceRuntime

@MainActor
enum SearchEnvironment {
    static func makeSession() -> SearchSession {
        let externalBaseURL = ProcessInfo.processInfo.environment[
            "LEGADO_SEARCH_BASE_URL"
        ]
        let baseURL = externalBaseURL ?? "http://legado.local"
        let transport = makeTransport(externalBaseURL: externalBaseURL)
        let sources = makeSources(baseURL: baseURL)
        return SearchSession(
            groups: ["科幻", "奇幻"],
            executor: SourceSearchBooksExecutor(
                sources: sources,
                transport: transport
            )
        )
    }

    static func makeChapterLoader() -> any BookChapterLoading {
        let externalBaseURL = ProcessInfo.processInfo.environment[
            "LEGADO_SEARCH_BASE_URL"
        ]
        let baseURL = externalBaseURL ?? "http://legado.local"
        return SourceBookChapterLoader(
            sources: makeSources(baseURL: baseURL),
            transport: makeTransport(externalBaseURL: externalBaseURL)
        )
    }

    static func makeReaderContentLoader() -> any ReaderContentLoading {
        let externalBaseURL = ProcessInfo.processInfo.environment[
            "LEGADO_SEARCH_BASE_URL"
        ]
        let baseURL = externalBaseURL ?? "http://legado.local"
        return SourceReaderContentLoader(
            sources: makeSources(baseURL: baseURL),
            transport: makeTransport(externalBaseURL: externalBaseURL)
        )
    }

    private static func makeTransport(
        externalBaseURL: String?
    ) -> any HTTPTransport {
        externalBaseURL == nil
            ? LocalBookSourceTransport()
            : URLSessionBookSourceTransport()
    }

    private static func makeSources(
        baseURL: String
    ) -> [SearchSourceDescriptor] {
        [
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
    }

    private static func source(
        baseURL: String,
        id: String,
        name: String,
        group: String,
        order: Int
    ) -> SearchSourceDescriptor {
        SearchSourceDescriptor(
            id: id,
            name: name,
            group: group,
            definition: SourceSearchDefinition(
                sourceURL: id,
                sourceName: name,
                originOrder: order,
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
        )
    }
}

private actor LocalBookSourceTransport: HTTPTransport {
    func execute(_ request: HTTPRequest) async throws -> HTTPResponse {
        let components = URLComponents(
            string: request.url.absoluteString
        )
        let path = components?.path ?? ""
        let body: String
        if let book = Self.books.first(where: { $0.path == path }) {
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

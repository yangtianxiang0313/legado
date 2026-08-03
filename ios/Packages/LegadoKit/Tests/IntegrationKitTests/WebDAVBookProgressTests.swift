import Foundation
import IntegrationKit
import XCTest

final class WebDAVBookProgressTests: XCTestCase {
    func testBuildsAndroidCompatibleDirectoryAndReservedFileName() throws {
        let configuration = WebDAVConnectionConfiguration(
            serverURL: try XCTUnwrap(
                WebDAVServerURL(rawValue: "https://dav.example.test/dav")
            ),
            directoryName: "legado",
            credentialReference: WebDAVCredentialReference("credential")
        )
        let identity = WebDAVBookIdentity(
            name: "书 / 100%",
            author: "A&B?"
        )

        XCTAssertEqual(
            "书%20%2F%20100%25_A%26B%3F.json",
            AndroidWebDAVBookProgressPath.encodedFileName(for: identity)
        )
        XCTAssertEqual(
            "https://dav.example.test/dav/legado/bookProgress/%E4%B9%A6%20%2F%20100%25_A%26B%3F.json",
            AndroidWebDAVBookProgressPath.url(
                configuration: configuration,
                identity: identity
            )?.absoluteString
        )
    }

    func testDecodesOnlyTheRequestedBookIdentity() throws {
        let expected = WebDAVBookIdentity(name: "SyncBook", author: "SyncAuthor")
        let data = Data(
            #"{"name":"SyncBook","author":"SyncAuthor","durChapterIndex":2,"durChapterPos":15,"durChapterTime":200,"durChapterTitle":"第三章"}"#.utf8
        )

        let decoded = try AndroidWebDAVBookProgressCodec.decode(
            data,
            expectedIdentity: expected
        )
        XCTAssertEqual(2, decoded.durChapterIndex)
        XCTAssertEqual(15, decoded.durChapterPos)
        XCTAssertEqual("第三章", decoded.durChapterTitle)

        XCTAssertThrowsError(
            try AndroidWebDAVBookProgressCodec.decode(
                data,
                expectedIdentity: WebDAVBookIdentity(
                    name: "Other",
                    author: "SyncAuthor"
                )
            )
        ) { error in
            XCTAssertEqual(
                .identityMismatch,
                error as? WebDAVBookProgressCodecError
            )
        }
    }

    func testRejects404ShapedJSONAsInvalidPayload() {
        XCTAssertThrowsError(
            try AndroidWebDAVBookProgressCodec.decode(
                Data(#"{"status":404}"#.utf8),
                expectedIdentity: WebDAVBookIdentity(
                    name: "SyncBook",
                    author: "SyncAuthor"
                )
            )
        ) { error in
            XCTAssertEqual(
                .invalidPayload,
                error as? WebDAVBookProgressCodecError
            )
        }
    }

    func testIOSInteropPayloadIsProducedByTheProductCodec() throws {
        let document = WebDAVBookProgressDocument(
            name: "SyncBook",
            author: "SyncAuthor",
            durChapterIndex: 2,
            durChapterPos: 15,
            durChapterTime: 200,
            durChapterTitle: "第三章"
        )

        XCTAssertEqual(
            #"{"author":"SyncAuthor","durChapterIndex":2,"durChapterPos":15,"durChapterTime":200,"durChapterTitle":"第三章","name":"SyncBook"}"#,
            String(
                decoding: try AndroidWebDAVBookProgressCodec.encode(document),
                as: UTF8.self
            )
        )
    }
}

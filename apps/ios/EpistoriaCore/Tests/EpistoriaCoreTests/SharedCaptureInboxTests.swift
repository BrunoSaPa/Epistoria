import Foundation
import XCTest
@testable import EpistoriaCore

final class SharedCaptureInboxTests: XCTestCase {
    func testEncryptedCaptureRoundTripAndRemoval() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let id = UUID()
        let item = SharedCaptureItem(
            id: id,
            kind: .text,
            filename: "Shared text.txt",
            typeIdentifier: "public.plain-text",
            title: "Shared text",
            payload: Data("private notes".utf8)
        )

        XCTAssertEqual(try fixture.inbox.enqueue(item, key: fixture.key), id)
        XCTAssertEqual(try fixture.inbox.identifiers(in: .pending), [id])
        XCTAssertEqual(try fixture.inbox.item(id: id, location: .pending, key: fixture.key), item)

        let ciphertext = try Data(contentsOf: fixture.captureURL(id: id, location: .pending))
        XCTAssertNil(String(data: ciphertext, encoding: .utf8)?.range(of: "private notes"))
        XCTAssertFalse(ciphertext.range(of: Data("Shared text.txt".utf8)) != nil)
        XCTAssertFalse(ciphertext.range(of: Data("Shared text".utf8)) != nil)

        try fixture.inbox.remove(id: id, from: .pending)
        XCTAssertTrue(try fixture.inbox.identifiers(in: .pending).isEmpty)
    }

    func testFailedCaptureCanBeRetriedWithoutChangingCiphertext() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let item = SharedCaptureItem(kind: .link, payload: Data("https://example.com".utf8))
        try fixture.inbox.enqueue(item, key: fixture.key)
        let original = try Data(contentsOf: fixture.captureURL(id: item.id, location: .pending))

        try fixture.inbox.markFailed(id: item.id)
        XCTAssertEqual(try fixture.inbox.identifiers(in: .failed), [item.id])
        XCTAssertTrue(try fixture.inbox.identifiers(in: .pending).isEmpty)
        XCTAssertEqual(
            try Data(contentsOf: fixture.captureURL(id: item.id, location: .failed)),
            original
        )

        try fixture.inbox.retryFailed()
        XCTAssertEqual(try fixture.inbox.identifiers(in: .pending), [item.id])
        XCTAssertTrue(try fixture.inbox.identifiers(in: .failed).isEmpty)
        XCTAssertEqual(try fixture.inbox.item(id: item.id, location: .pending, key: fixture.key), item)
    }

    func testTamperedAndWrongKeyCapturesFailClosed() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let item = SharedCaptureItem(kind: .image, filename: "diagram.png", payload: Data(repeating: 9, count: 64))
        try fixture.inbox.enqueue(item, key: fixture.key)
        let url = fixture.captureURL(id: item.id, location: .pending)

        XCTAssertThrowsError(
            try fixture.inbox.item(id: item.id, location: .pending, key: Data(repeating: 7, count: 32))
        )

        var encrypted = try Data(contentsOf: url)
        encrypted[encrypted.index(before: encrypted.endIndex)] ^= 1
        try encrypted.write(to: url, options: .atomic)
        XCTAssertThrowsError(
            try fixture.inbox.item(id: item.id, location: .pending, key: fixture.key)
        )
    }

    func testLimitsRejectEmptyAndOversizedPayloadsBeforeWriting() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }

        XCTAssertThrowsError(
            try fixture.inbox.enqueue(SharedCaptureItem(kind: .text, payload: Data()), key: fixture.key)
        ) { error in
            XCTAssertEqual(error as? SharedCaptureInboxError, .invalidItem)
        }
        XCTAssertThrowsError(
            try fixture.inbox.enqueue(
                SharedCaptureItem(
                    kind: .file,
                    payload: Data(repeating: 0, count: SharedCaptureInbox.maximumPayloadBytes + 1)
                ),
                key: fixture.key
            )
        ) { error in
            XCTAssertEqual(error as? SharedCaptureInboxError, .itemTooLarge)
        }
        XCTAssertTrue(try fixture.inbox.identifiers(in: .pending).isEmpty)
    }
}

private struct Fixture {
    let root: URL
    let inbox: SharedCaptureInbox
    let key = Data(0 ..< 32)

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "epistoria-shared-capture-tests-\(UUID().uuidString)",
                isDirectory: true
            )
        inbox = SharedCaptureInbox(rootURL: root)
    }

    func captureURL(id: UUID, location: SharedCaptureInbox.Location) -> URL {
        root.appendingPathComponent(location.rawValue, isDirectory: true)
            .appendingPathComponent(id.uuidString.lowercased())
            .appendingPathExtension("capture")
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}

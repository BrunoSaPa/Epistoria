import Foundation
import XCTest
@testable import EpistoriaCore

final class CanonicalJSONTests: XCTestCase {
    private struct Value: Codable, Equatable {
        var zeta: Int
        var alpha: String
        var date: Date
    }

    func testJSONIsSortedAndUsesRFC3339() throws {
        let value = Value(zeta: 2, alpha: "one", date: Date(timeIntervalSince1970: 0.123))
        let encoded = try CanonicalJSON.encode(value)
        let string = try XCTUnwrap(String(data: encoded, encoding: .utf8))
        XCTAssertTrue(string.hasPrefix("{\"alpha\":"))
        XCTAssertTrue(string.contains("1970-01-01T00:00:00.123Z"))
        XCTAssertEqual(try CanonicalJSON.decode(Value.self, from: encoded), value)
    }

    func testOwnerEditedNoteQueryResponseRoundTrips() throws {
        let sourceId = UUID()
        let response = NoteQueryResponse(
            schemaVersion: "note-query-response/v1",
            answer: "A reviewed answer.",
            citedSourceIds: [sourceId],
            followUpQuestions: ["What follows?"]
        )

        let encoded = try CanonicalJSON.encode(response)

        XCTAssertEqual(
            try CanonicalJSON.decode(NoteQueryResponse.self, from: encoded),
            response
        )
    }
}

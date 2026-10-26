import XCTest
@testable import SessionCore

final class TodoistTaskDecodingTests: XCTestCase {
    func testDecodesDetailFields() throws {
        let json = #"{"id":"1","content":"写周报","projectId":"p","priority":4,"dueDate":"2026-10-25T15:15:00","isRecurring":false,"durationMinutes":45,"description":"**重点**","labels":["work"],"parentId":null,"url":"https://app.todoist.com/app/task/1"}"#
        let t = try JSONDecoder().decode(TodoistTask.self, from: Data(json.utf8))
        XCTAssertEqual(t.description, "**重点**")
        XCTAssertEqual(t.labels, ["work"])
        XCTAssertNil(t.parentId)
        XCTAssertEqual(t.url, "https://app.todoist.com/app/task/1")
    }

    func testOldBackendPayloadStillDecodes() throws {
        let json = #"{"id":"1","content":"x","projectId":"p","priority":1,"dueDate":null,"isRecurring":false,"durationMinutes":null}"#
        let t = try JSONDecoder().decode(TodoistTask.self, from: Data(json.utf8))
        XCTAssertEqual(t.description, "")
        XCTAssertEqual(t.labels, [])
        XCTAssertNil(t.url)
    }
}

import Foundation
import Testing

@testable import HoleberryCore

@Suite("HTTPURLResponse.isSuccess")
struct HTTPURLResponseStatusCodesTests {
  private static let testURL = URL(string: "http://test.local")!

  private func makeResponse(code: Int) -> HTTPURLResponse? {
    HTTPURLResponse(url: Self.testURL, statusCode: code, httpVersion: nil, headerFields: nil)
  }

  @Test("200 is success")
  func status200() throws {
    let response = try #require(makeResponse(code: 200))
    #expect(response.isSuccess)
  }

  @Test("201 is success")
  func status201() throws {
    let response = try #require(makeResponse(code: 201))
    #expect(response.isSuccess)
  }

  @Test("299 is success")
  func status299() throws {
    let response = try #require(makeResponse(code: 299))
    #expect(response.isSuccess)
  }

  @Test("199 is not success")
  func status199() throws {
    let response = try #require(makeResponse(code: 199))
    #expect(response.isSuccess == false)
  }

  @Test("300 is not success")
  func status300() throws {
    let response = try #require(makeResponse(code: 300))
    #expect(response.isSuccess == false)
  }

  @Test("401 is not success")
  func status401() throws {
    let response = try #require(makeResponse(code: 401))
    #expect(response.isSuccess == false)
  }

  @Test("500 is not success")
  func status500() throws {
    let response = try #require(makeResponse(code: 500))
    #expect(response.isSuccess == false)
  }
}

import Foundation

@testable import HoleberryCore

/// Configurable mock implementing `QueryStatisticsFetching` with stub batches
/// and call tracking.
@MainActor
final class MockQueryStatisticsFetcher: QueryStatisticsFetching {
  var batchStub = QueryStatisticsBatch(servers: [], results: [:])
  var fetchHandler: ((ServerScope) async -> QueryStatisticsBatch)?

  private(set) var fetchCallCount = 0
  private(set) var fetchLastScope: ServerScope?
  private(set) var logoutCallCount = 0

  func fetchStatistics(scope: ServerScope) async -> QueryStatisticsBatch {
    fetchCallCount += 1
    fetchLastScope = scope
    if let fetchHandler { return await fetchHandler(scope) }
    return batchStub
  }

  func logout() async {
    logoutCallCount += 1
  }
}

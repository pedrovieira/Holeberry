/// Controls whether a managed unblock may create an allowlist entry.
public enum DomainUnblockMode: Equatable, Sendable {
  case allowCreation
  case existingOnly
}

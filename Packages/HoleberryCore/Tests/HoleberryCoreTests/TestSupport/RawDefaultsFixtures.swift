import Defaults
import Foundation

/// Injects a raw value into the underlying suite for malformed-storage tests.
func setRawDefaultsValue<Value>(_ value: Any, for key: Defaults.Key<Value>) {
  key.suite.set(value, forKey: key.name)
}

/// Reads the raw underlying value without `Defaults` decoding.
func rawDefaultsValue<Value>(for key: Defaults.Key<Value>) -> Any? {
  key.suite.object(forKey: key.name)
}

import Foundation
import Security

/// The poster Wi-Fi password lives in the login keychain. It is not written
/// to preferences, logs, or the diagnostics report. Do not interpolate it
/// into a log line or an error string.
enum PosterPasswordStore {
  static let service = "io.github.walterkaan.public-earfi.poster-wifi"
  static let account = "poster"

  struct Load {
    var password: String
    var unreadable: Bool
  }

  enum SaveResult {
    case saved
    case cleared
    case failed(OSStatus)
  }

  static func load() -> Load {
    var query = baseQuery()
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    if status == errSecItemNotFound {
      return Load(password: "", unreadable: false)
    }
    guard status == errSecSuccess, let data = item as? Data else {
      return Load(password: "", unreadable: true)
    }
    return Load(password: String(data: data, encoding: .utf8) ?? "", unreadable: false)
  }

  static func save(_ password: String) -> SaveResult {
    if password.isEmpty {
      return delete()
    }
    let data = Data(password.utf8)
    let updated = SecItemUpdate(
      baseQuery() as CFDictionary,
      [kSecValueData as String: data] as CFDictionary
    )
    if updated == errSecSuccess {
      return .saved
    }
    if updated != errSecItemNotFound {
      _ = SecItemDelete(baseQuery() as CFDictionary)
    }
    var query = baseQuery()
    query[kSecValueData as String] = data
    query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    query[kSecAttrLabel as String] = "Public EarFi poster Wi-Fi"
    let added = SecItemAdd(query as CFDictionary, nil)
    if added == errSecSuccess {
      return .saved
    }
    return .failed(added)
  }

  @discardableResult
  static func delete() -> SaveResult {
    let status = SecItemDelete(baseQuery() as CFDictionary)
    if status == errSecSuccess || status == errSecItemNotFound {
      return .cleared
    }
    return .failed(status)
  }

  private static func baseQuery() -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
    ]
  }
}

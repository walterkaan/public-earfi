import Foundation
import Security

/// One-time move of a poster Wi-Fi password out of the login keychain.
/// After `finishedKey` is set, the app does not read or write the Keychain.
/// The password then lives in the settings store with the other preferences.
enum PosterPasswordMigration {
  static let finishedKey = "roomcast.posterPasswordLeftKeychain"
  static let service = "channel.roomcast.app.poster-wifi"
  /// Pre-rename Public EarFi item. Still read once so an older install migrates.
  private static let legacyServices = [
    "io.github.walterkaan.public-earfi.poster-wifi"
  ]
  static let account = "poster"

  struct Read {
    /// The password when an item was readable, including an empty item.
    /// Nil when nothing was stored.
    var password: String?
    /// The keychain refused the read. Leave the item for the next launch.
    var unreadable: Bool
  }

  static func read() -> Read {
    var sawUnreadable = false
    var sawEmpty = false
    for name in [service] + legacyServices {
      for protection in [true, false] {
        switch copy(service: name, dataProtection: protection) {
        case .value(let data):
          let password = String(data: data, encoding: .utf8) ?? ""
          if !password.isEmpty {
            return Read(password: password, unreadable: false)
          }
          sawEmpty = true
        case .missing:
          break
        case .unreadable:
          sawUnreadable = true
        }
      }
    }
    if sawEmpty {
      return Read(password: "", unreadable: false)
    }
    if sawUnreadable {
      return Read(password: nil, unreadable: true)
    }
    return Read(password: nil, unreadable: false)
  }

  /// Removes the current and legacy items. Missing items count as removed.
  @discardableResult
  static func deleteAll() -> Bool {
    var ok = true
    for name in [service] + legacyServices {
      for protection in [true, false] {
        let status = SecItemDelete(
          baseQuery(service: name, dataProtection: protection) as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
          ok = false
        }
      }
    }
    return ok
  }

  private enum Copy {
    case value(Data)
    case missing
    case unreadable
  }

  private static func copy(service: String, dataProtection: Bool) -> Copy {
    var query = baseQuery(service: service, dataProtection: dataProtection)
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    if status == errSecItemNotFound { return .missing }
    if status == errSecSuccess {
      if let data = item as? Data { return .value(data) }
      return .value(Data())
    }
    return .unreadable
  }

  private static func baseQuery(service: String, dataProtection: Bool) -> [String: Any] {
    var query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
    ]
    if dataProtection {
      query[kSecUseDataProtectionKeychain as String] = true
    }
    return query
  }
}

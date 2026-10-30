import Foundation
import Security

/// The poster Wi-Fi password lives in the login keychain. It is not written
/// to preferences, logs, or the diagnostics report. Do not interpolate it
/// into a log line or an error string.
enum PosterPasswordStore {
  static let service = "channel.roomcast.app.poster-wifi"
  /// Pre-rename Public EarFi service. Load migrates any leftover item here.
  private static let legacyServices = [
    "io.github.walterkaan.public-earfi.poster-wifi"
  ]
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
    if let data = copyData(service: service, dataProtection: true) {
      return Load(password: decode(data), unreadable: false)
    }
    // Items saved without kSecUseDataProtectionKeychain still live in the
    // file-based keychain. Read them, then rewrite into the data-protection
    // keychain so the next launch hits the primary path.
    if let data = copyData(service: service, dataProtection: false) {
      let password = decode(data)
      if !password.isEmpty {
        _ = save(password)
      }
      return Load(password: password, unreadable: false)
    }
    for legacy in legacyServices {
      if let data = copyData(service: legacy, dataProtection: true)
        ?? copyData(service: legacy, dataProtection: false)
      {
        let password = decode(data)
        if !password.isEmpty {
          _ = save(password)
          _ = deleteService(legacy)
        }
        return Load(password: password, unreadable: false)
      }
    }
    let status = lastCopyStatus
    if status == errSecItemNotFound {
      return Load(password: "", unreadable: false)
    }
    // errSecInteractionNotAllowed before first unlock, and friends: treat as
    // temporarily unreadable so the poster can still print a blank line.
    if status == errSecSuccess {
      return Load(password: "", unreadable: false)
    }
    return Load(password: "", unreadable: true)
  }

  static func save(_ password: String) -> SaveResult {
    if password.isEmpty {
      return delete()
    }
    let data = Data(password.utf8)
    let query = baseQuery(service: service, dataProtection: true)
    let updated = SecItemUpdate(
      query as CFDictionary,
      [kSecValueData as String: data] as CFDictionary
    )
    if updated == errSecSuccess {
      return .saved
    }
    if updated != errSecItemNotFound {
      _ = SecItemDelete(query as CFDictionary)
    }
    var add = query
    add[kSecValueData as String] = data
    add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    add[kSecAttrLabel as String] = "RoomCast poster Wi-Fi"
    let added = SecItemAdd(add as CFDictionary, nil)
    if added == errSecSuccess {
      // Drop a leftover file-based copy so load does not prefer stale data.
      _ = SecItemDelete(baseQuery(service: service, dataProtection: false) as CFDictionary)
      return .saved
    }
    return .failed(added)
  }

  @discardableResult
  static func delete() -> SaveResult {
    let primary = deleteService(service)
    for legacy in legacyServices {
      _ = deleteService(legacy)
    }
    return primary
  }

  @discardableResult
  private static func deleteService(_ serviceName: String) -> SaveResult {
    var sawFailure: OSStatus?
    for flag in [true, false] {
      let status = SecItemDelete(baseQuery(service: serviceName, dataProtection: flag) as CFDictionary)
      if status != errSecSuccess && status != errSecItemNotFound {
        sawFailure = status
      }
    }
    if let sawFailure {
      return .failed(sawFailure)
    }
    return .cleared
  }

  private static var lastCopyStatus: OSStatus = errSecItemNotFound

  private static func copyData(service: String, dataProtection: Bool) -> Data? {
    var query = baseQuery(service: service, dataProtection: dataProtection)
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    lastCopyStatus = status
    guard status == errSecSuccess else { return nil }
    if let data = item as? Data {
      return data
    }
    return nil
  }

  private static func decode(_ data: Data) -> String {
    String(data: data, encoding: .utf8) ?? ""
  }

  private static func baseQuery(service: String, dataProtection: Bool) -> [String: Any] {
    var query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
    ]
    // kSecAttrAccessible only applies with the data-protection keychain. Save
    // and load must agree on this flag or SecItemCopyMatching returns
    // errSecItemNotFound for a password that is still in Keychain Access.
    if dataProtection {
      query[kSecUseDataProtectionKeychain as String] = true
    }
    return query
  }
}

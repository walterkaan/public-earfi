import StoreKit
import SwiftUI
import UIKit

enum BroadcastLimits {
    /// Free accounts can broadcast this long inside any rolling window.
    /// A debug build uses a short window so the limit can be checked quickly.
    #if DEBUG
    static let freeSeconds: TimeInterval = 90
    static let windowSeconds: TimeInterval = 3 * 60
    #else
    static let freeSeconds: TimeInterval = 40 * 60
    static let windowSeconds: TimeInterval = 60 * 60
    #endif
}

/// Broadcast time already used by a free account. Intervals survive a relaunch.
/// A future start (the clock moved back) is ignored.
enum FreeUsage {
    private struct Span: Codable {
        var start: TimeInterval
        var end: TimeInterval
    }

    private struct Open: Codable {
        var start: TimeInterval
        var checkpoint: TimeInterval
    }

    private static let spansKey = "broadcast.freeSpans"
    private static let openKey = "broadcast.freeOpen"

    static func sealAbandoned(now: Date) {
        guard let open = loadOpen() else { return }
        let nowT = now.timeIntervalSince1970
        if open.start > nowT + 2 {
            saveOpen(nil)
            return
        }
        let end = min(max(open.checkpoint, open.start), nowT)
        if end > open.start {
            store(Span(start: open.start, end: end), now: now)
        }
        saveOpen(nil)
    }

    static func begin(now: Date) {
        let t = now.timeIntervalSince1970
        saveOpen(Open(start: t, checkpoint: t))
    }

    static func checkpoint(start: Date, now: Date) {
        var startT = start.timeIntervalSince1970
        var nowT = now.timeIntervalSince1970
        if startT > nowT + 2 { startT = nowT }
        if nowT < startT { nowT = startT }
        saveOpen(Open(start: startT, checkpoint: nowT))
    }

    static func close(start: Date, now: Date) {
        let startT = start.timeIntervalSince1970
        var endT = now.timeIntervalSince1970
        if startT > endT + 2 {
            saveOpen(nil)
            return
        }
        if endT < startT { endT = startT }
        store(Span(start: startT, end: endT), now: now)
        saveOpen(nil)
    }

    static var hasOpenSession: Bool { loadOpen() != nil }

    static func remaining(now: Date, openStart: Date?) -> TimeInterval {
        max(0, BroadcastLimits.freeSeconds - used(now: now, openStart: openStart))
    }

    static func used(now: Date, openStart: Date?) -> TimeInterval {
        let nowT = now.timeIntervalSince1970
        let windowStart = nowT - BroadcastLimits.windowSeconds
        var total = spans(now: now).reduce(0.0) { partial, span in
            partial + overlap(span, windowStart: windowStart, now: nowT)
        }
        if let openStart {
            var startT = openStart.timeIntervalSince1970
            if startT <= nowT + 2 {
                if startT > nowT { startT = nowT }
                total += overlap(Span(start: startT, end: nowT), windowStart: windowStart, now: nowT)
            }
        }
        return total
    }

    /// Whole minutes, rounded up, until some free time is back. Zero if time remains.
    static func minutesUntilAvailable(now: Date) -> Int {
        if used(now: now, openStart: nil) < BroadcastLimits.freeSeconds - 0.5 { return 0 }
        let steps = Int(BroadcastLimits.windowSeconds.rounded(.up))
        for step in 1...max(1, steps) {
            let later = now.addingTimeInterval(TimeInterval(step))
            if used(now: later, openStart: nil) < BroadcastLimits.freeSeconds - 0.5 {
                return max(1, Int((Double(step) / 60).rounded(.up)))
            }
        }
        return max(1, Int((BroadcastLimits.windowSeconds / 60).rounded(.up)))
    }

    private static func overlap(_ span: Span, windowStart: TimeInterval, now: TimeInterval) -> TimeInterval {
        if span.start > now + 2 { return 0 }
        let end = min(span.end, now)
        let start = max(span.start, windowStart)
        return max(0, end - start)
    }

    private static func spans(now: Date) -> [Span] {
        guard let data = UserDefaults.standard.data(forKey: spansKey),
              let decoded = try? JSONDecoder().decode([Span].self, from: data) else { return [] }
        let nowT = now.timeIntervalSince1970
        let windowStart = nowT - BroadcastLimits.windowSeconds
        return decoded.filter { span in
            span.start <= nowT + 2 && span.end > span.start && span.end > windowStart
        }
    }

    private static func store(_ span: Span, now: Date) {
        var all = spans(now: now)
        all.append(span)
        let nowT = now.timeIntervalSince1970
        let windowStart = nowT - BroadcastLimits.windowSeconds
        all = all.filter { $0.start <= nowT + 2 && $0.end > $0.start && $0.end > windowStart }
        if let data = try? JSONEncoder().encode(all) {
            UserDefaults.standard.set(data, forKey: spansKey)
        }
    }

    private static func loadOpen() -> Open? {
        guard let data = UserDefaults.standard.data(forKey: openKey) else { return nil }
        return try? JSONDecoder().decode(Open.self, from: data)
    }

    private static func saveOpen(_ open: Open?) {
        if let open, let data = try? JSONEncoder().encode(open) {
            UserDefaults.standard.set(data, forKey: openKey)
        } else {
            UserDefaults.standard.removeObject(forKey: openKey)
        }
    }
}

enum ProLegal {
    static let privacy = URL(string: "https://go.roomcast.channel/privacy")!
    /// Apple’s standard EULA. Use this until RoomCast publishes its own terms.
    static let terms = URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!
}

/// StoreKit 2 auto-renewable subscription. The price comes from the product
/// (`displayPrice`), never from a hardcoded amount.
@MainActor
final class ProStore: ObservableObject {
    static let productID = "channel.roomcast.go.pro.monthly"

    @Published private(set) var product: StoreKit.Product?
    @Published private(set) var isPro = false
    @Published var purchaseError: String?
    @Published private(set) var isWorking = false

    /// Called on the main actor when a verified subscription becomes active.
    var onBecamePro: (() -> Void)?

    /// Newest purchase this process has accepted. `currentEntitlements` can
    /// omit a transaction that was just bought in StoreKit Testing.
    private var trusted: StoreKit.Transaction?
    /// When this process accepted a purchase. A following refresh must not
    /// flip Pro off while StoreKit Testing is still publishing that transaction.
    private var purchasedAt: Date?
    private var updatesTask: Task<Void, Never>?

    init() {
        updatesTask = Task { [weak self] in
            for await update in StoreKit.Transaction.updates {
                await self?.handle(update)
            }
        }
        Task { await self.refresh() }
    }

    func refresh() async {
        await loadProduct()
        await refreshEntitlement()
    }

    func loadProduct() async {
        do {
            let products = try await StoreKit.Product.products(for: [Self.productID])
            product = products.first
            if products.isEmpty {
                purchaseError = "The subscription isn’t available from the App Store yet."
            } else {
                purchaseError = nil
            }
        } catch {
            purchaseError = error.localizedDescription
        }
    }

    func refreshEntitlement() async {
        if product == nil {
            await loadProduct()
        }
        let now = Date()
        var seen: [Seen] = []
        for await result in StoreKit.Transaction.currentEntitlements {
            seen.append(Seen(result, source: "currentEntitlements"))
        }
        if let result = await StoreKit.Transaction.latest(for: Self.productID) {
            seen.append(Seen(result, source: "latest"))
        }
        var history = 0
        for await result in StoreKit.Transaction.all {
            let item = Seen(result, source: "all")
            history += 1
            if item.productID == Self.productID {
                seen.append(item)
            }
        }
        if let trusted {
            seen.append(Seen(transaction: trusted, source: "trusted", verification: "verified", trust: true))
        }
        let status = await subscriptionStatus()
        let decision = decide(seen: seen, status: status, now: now)
        if decision.revokedTrusted {
            trusted = nil
            purchasedAt = nil
        } else if let winner = decision.winner {
            trusted = winner
        }
        if decision.unlocked {
            purchaseError = nil
        }
        let became = decision.unlocked && !isPro
        if isPro != decision.unlocked {
            isPro = decision.unlocked
        }
        if became {
            onBecamePro?()
        }
        logRefresh(seen: seen, status: status, history: history, now: now, unlocked: decision.unlocked, reason: decision.reason)
    }

    func purchase() async {
        if product == nil {
            await loadProduct()
        }
        guard let product else { return }
        isWorking = true
        purchaseError = nil
        defer { isWorking = false }
        do {
            let result = try await product.purchase()
            switch result {
            case .success(let verification):
                let seen = Seen(verification, source: "purchase")
                if seen.trust, seen.productID == Self.productID, seen.revocationDate == nil {
                    adopt(seen.transaction)
                    purchasedAt = Date()
                    purchaseError = nil
                    if !isPro {
                        isPro = true
                        onBecamePro?()
                    }
                } else if !seen.trust {
                    purchaseError = "The purchase could not be verified."
                } else {
                    purchaseError = "The subscription is not active."
                }
                await seen.transaction.finish()
                await refreshEntitlement()
            case .userCancelled, .pending:
                break
            @unknown default:
                break
            }
        } catch {
            purchaseError = error.localizedDescription
        }
    }

    func restore() async {
        isWorking = true
        purchaseError = nil
        defer { isWorking = false }
        do {
            try await StoreKit.AppStore.sync()
            await refreshEntitlement()
            if !isPro {
                purchaseError = "No active subscription was found for this Apple ID."
            }
        } catch {
            purchaseError = error.localizedDescription
        }
    }

    func periodLabel(_ product: StoreKit.Product) -> String {
        guard let period = product.subscription?.subscriptionPeriod else { return "period" }
        let count = period.value
        let unit: String
        switch period.unit {
        case .day: unit = count == 1 ? "day" : "days"
        case .week: unit = count == 1 ? "week" : "weeks"
        case .month: unit = count == 1 ? "month" : "months"
        case .year: unit = count == 1 ? "year" : "years"
        @unknown default: unit = "period"
        }
        if count == 1 { return unit }
        return "\(count) \(unit)"
    }

    private func handle(_ update: StoreKit.VerificationResult<StoreKit.Transaction>) async {
        let seen = Seen(update, source: "updates")
        let recent = Date().timeIntervalSince(seen.purchaseDate) < 180
        if seen.trust, seen.productID == Self.productID, seen.revocationDate == nil, (seen.activeByDate || recent) {
            adopt(seen.transaction)
            if recent { purchasedAt = Date() }
            if !isPro {
                isPro = true
                onBecamePro?()
            }
        } else if trusted?.id == seen.id, seen.revocationDate != nil {
            trusted = nil
            purchasedAt = nil
        }
        await seen.transaction.finish()
        await refreshEntitlement()
    }

    private func adopt(_ transaction: StoreKit.Transaction) {
        if let trusted, trusted.revocationDate == nil, transaction.purchaseDate < trusted.purchaseDate {
            return
        }
        trusted = transaction
    }

    /// One row in the entitlement log. `trust` is false for an unverified
    /// App Store transaction. StoreKit Testing on device often delivers
    /// `.unverified` with environment `.xcode`; those still count.
    private struct Seen {
        var source: String
        var productID: String
        var id: UInt64
        var purchaseDate: Date
        var expirationDate: Date?
        var revocationDate: Date?
        var isUpgraded: Bool
        var verification: String
        var trust: Bool
        var transaction: StoreKit.Transaction

        init(_ result: StoreKit.VerificationResult<StoreKit.Transaction>, source: String) {
            switch result {
            case .verified(let transaction):
                self.init(transaction: transaction, source: source, verification: "verified", trust: true)
            case .unverified(let transaction, let error):
                let testing = transaction.environment == .xcode
                let note = testing ? "unverified-xcode(\(error))" : "unverified(\(error))"
                self.init(transaction: transaction, source: source, verification: note, trust: testing)
            }
        }

        init(transaction: StoreKit.Transaction, source: String, verification: String, trust: Bool) {
            self.source = source
            self.productID = transaction.productID
            self.id = transaction.id
            self.purchaseDate = transaction.purchaseDate
            self.expirationDate = transaction.expirationDate
            self.revocationDate = transaction.revocationDate
            self.isUpgraded = transaction.isUpgraded
            self.verification = verification
            self.trust = trust
            self.transaction = transaction
        }

        var activeByDate: Bool {
            guard revocationDate == nil else { return false }
            guard let expirationDate else { return true }
            return expirationDate > Date()
        }
    }

    private struct StatusSeen {
        var state: String
        var productID: String
        var verification: String
        var trust: Bool
        var grants: Bool
        var dead: Bool
        var transactionID: UInt64
        var summary: String
    }

    private struct Decision {
        var unlocked: Bool
        var reason: String
        var winner: StoreKit.Transaction?
        var revokedTrusted: Bool
    }

    /// `Product.subscription.status` is the signal StoreKit itself shows in
    /// Manage Transactions. `expirationDate <= now` is not: StoreKit Testing's
    /// accelerated clock makes a still-subscribed transaction look expired,
    /// and `isUpgraded` stays true on the current record after a test renewal.
    private func subscriptionStatus() async -> [StatusSeen] {
        guard let product, let subscription = product.subscription else { return [] }
        do {
            let statuses = try await subscription.status
            return statuses.map { status in
                let seen = Seen(status.transaction, source: "status")
                let state = Self.stateName(status.state)
                let renewal = Self.renewalSummary(status.renewalInfo)
                let matches = seen.productID == Self.productID || renewal.productID == Self.productID
                let grants = matches && seen.trust && seen.revocationDate == nil
                    && (status.state == .subscribed || status.state == .inGracePeriod)
                let dead = matches && (status.state == .expired || status.state == .revoked)
                return StatusSeen(
                    state: state,
                    productID: seen.productID,
                    verification: seen.verification,
                    trust: seen.trust,
                    grants: grants,
                    dead: dead,
                    transactionID: seen.id,
                    summary: "source=status state=\(state) verification=\(seen.verification) productID=\(seen.productID) id=\(seen.id) purchaseDate=\(Self.iso(seen.purchaseDate)) expirationDate=\(Self.iso(seen.expirationDate)) revocationDate=\(Self.iso(seen.revocationDate)) isUpgraded=\(seen.isUpgraded) \(renewal.text)"
                )
            }
        } catch {
            return [StatusSeen(
                state: "error",
                productID: Self.productID,
                verification: "error",
                trust: false,
                grants: false,
                dead: false,
                transactionID: 0,
                summary: "source=status error=\(error)"
            )]
        }
    }

    private func decide(seen: [Seen], status: [StatusSeen], now: Date) -> Decision {
        let ours = seen.filter { $0.productID == Self.productID }
        let revokedTrusted = trusted.map { id in
            ours.contains { $0.id == id.id && $0.revocationDate != nil }
        } ?? false
        if status.contains(where: \.grants) {
            let winner = ours.filter { $0.trust && $0.revocationDate == nil }.max { $0.purchaseDate < $1.purchaseDate }
            return Decision(unlocked: true, reason: "status-subscribed", winner: winner?.transaction ?? trusted, revokedTrusted: false)
        }
        // Apple already drops expired, revoked, and upgraded rows here. A second
        // expiration or isUpgraded test hides a StoreKit Testing subscription.
        if let current = ours.filter({ $0.source == "currentEntitlements" && $0.trust && $0.revocationDate == nil })
            .max(by: { $0.purchaseDate < $1.purchaseDate }) {
            return Decision(unlocked: true, reason: "currentEntitlements", winner: current.transaction, revokedTrusted: false)
        }
        if let dated = ours.filter({ item in
            guard item.trust, item.revocationDate == nil, item.source != "currentEntitlements" else { return false }
            // `Transaction.all` lists every past purchase. A missing expiration
            // there is not an active subscription.
            guard let expiration = item.expirationDate else { return item.source != "all" }
            return expiration > now
        }).max(by: { $0.purchaseDate < $1.purchaseDate }) {
            return Decision(unlocked: true, reason: dated.source, winner: dated.transaction, revokedTrusted: false)
        }
        if !revokedTrusted,
           let purchasedAt,
           now.timeIntervalSince(purchasedAt) < 180,
           let trusted,
           trusted.revocationDate == nil,
           trusted.productID == Self.productID,
           !status.contains(where: { $0.dead && $0.transactionID == trusted.id }) {
            return Decision(unlocked: true, reason: "recent-purchase", winner: trusted, revokedTrusted: false)
        }
        let reason = ours.isEmpty && status.isEmpty ? "no-transaction" : "no-active-entitlement"
        return Decision(unlocked: false, reason: reason, winner: nil, revokedTrusted: revokedTrusted)
    }

    private func logRefresh(seen: [Seen], status: [StatusSeen], history: Int, now: Date, unlocked: Bool, reason: String) {
        #if DEBUG
        var parts = seen.map { item in
            "source=\(item.source) verification=\(item.verification) productID=\(item.productID) id=\(item.id) purchaseDate=\(Self.iso(item.purchaseDate)) expirationDate=\(Self.iso(item.expirationDate)) revocationDate=\(Self.iso(item.revocationDate)) isUpgraded=\(item.isUpgraded) environment=\(item.transaction.environment.rawValue)"
        }
        parts.append(contentsOf: status.map(\.summary))
        if parts.isEmpty {
            parts.append("none")
        }
        let loaded = product == nil ? "nil" : (product?.type.rawValue ?? "nil")
        let line = "[RoomCast Pro] entitlement refresh isPro=\(unlocked) reason=\(reason) expected=\(Self.productID) productType=\(loaded) history=\(history) now=\(Self.iso(now)) | " + parts.joined(separator: " || ")
        print(line.replacingOccurrences(of: "\n", with: " "))
        #else
        _ = (seen.count, status.count, history, now, unlocked, reason)
        #endif
    }

    private static func stateName(_ state: StoreKit.Product.SubscriptionInfo.RenewalState) -> String {
        switch state {
        case .subscribed: return "subscribed"
        case .inGracePeriod: return "inGracePeriod"
        case .inBillingRetryPeriod: return "inBillingRetryPeriod"
        case .expired: return "expired"
        case .revoked: return "revoked"
        @unknown default: return String(describing: state)
        }
    }

    private static func renewalSummary(_ result: StoreKit.VerificationResult<StoreKit.Product.SubscriptionInfo.RenewalInfo>) -> (productID: String, text: String) {
        let info: StoreKit.Product.SubscriptionInfo.RenewalInfo
        let verification: String
        switch result {
        case .verified(let value):
            info = value
            verification = "verified"
        case .unverified(let value, let error):
            info = value
            verification = "unverified(\(error))"
        }
        let text = "renewProduct=\(info.currentProductID) renewVerification=\(verification) willAutoRenew=\(info.willAutoRenew) billingRetry=\(info.isInBillingRetry) grace=\(iso(info.gracePeriodExpirationDate))"
        return (info.currentProductID, text)
    }

    private static func iso(_ date: Date?) -> String {
        guard let date else { return "nil" }
        return isoFormatter.string(from: date)
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}

struct PaywallView: View {
    @ObservedObject var store: ProStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Unlimited broadcasts on this iPhone. Free sessions stop at 40 minutes.")
                        .font(.body)
                        .foregroundStyle(.white.opacity(0.86))
                    offer
                    if let product = store.product {
                        Text(disclosure(product))
                            .font(.footnote)
                            .foregroundStyle(.white.opacity(0.62))
                    }
                    legalLinks
                    if let purchaseError = store.purchaseError {
                        Text(purchaseError)
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(Color.roomPink)
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color.roomNavy.ignoresSafeArea())
            .navigationTitle("RoomCast Go Pro")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
        .task { await store.refresh() }
    }

    @ViewBuilder
    private var offer: some View {
        if store.isPro {
            Text("Pro is active. Broadcasts don’t stop at 40 minutes.")
                .font(.headline)
                .foregroundStyle(Color.roomTeal)
            Button("Manage subscription") { manage() }
                .buttonStyle(PaywallButtonStyle(fill: Color.white.opacity(0.12), ink: .white))
        } else if let product = store.product {
            Text(product.displayName)
                .font(.title2.weight(.bold))
                .foregroundStyle(.white)
            if !product.description.isEmpty {
                Text(product.description)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.8))
            }
            Text("\(product.displayPrice) per \(store.periodLabel(product))")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)
            Button(store.isWorking ? "Working…" : "Subscribe") {
                Task { await store.purchase() }
            }
            .buttonStyle(PaywallButtonStyle(fill: .roomTeal, ink: .roomNavy))
            .disabled(store.isWorking)
        } else {
            ProgressView()
                .tint(.white)
            Text("The subscription price will appear when the App Store product loads.")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.8))
            Button("Retry") { Task { await store.loadProduct() } }
                .buttonStyle(PaywallButtonStyle(fill: Color.white.opacity(0.12), ink: .white))
        }
        Button(store.isWorking ? "Working…" : "Restore purchases") {
            Task { await store.restore() }
        }
        .buttonStyle(PaywallButtonStyle(fill: Color.white.opacity(0.12), ink: .white))
        .disabled(store.isWorking)
    }

    private var legalLinks: some View {
        VStack(alignment: .leading, spacing: 8) {
            Link("Privacy Policy", destination: ProLegal.privacy)
            Link("Terms of Use", destination: ProLegal.terms)
        }
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(Color.roomTeal)
    }

    private func disclosure(_ product: StoreKit.Product) -> String {
        let price = product.displayPrice
        let period = store.periodLabel(product)
        return """
        \(product.displayName) is an auto-renewable subscription. Length: \(period). Price: \(price) per \(period). \
        Payment is charged to your Apple ID when you confirm. The subscription renews automatically at \(price) per \(period) unless you cancel at least 24 hours before the end of the current period. \
        Your account is charged for renewal within 24 hours before the period ends. Manage or cancel anytime in Settings → Apple ID → Subscriptions.
        """
    }

    private func manage() {
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive })
            ?? UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first
        else { return }
        Task { try? await StoreKit.AppStore.showManageSubscriptions(in: scene) }
    }
}

private struct PaywallButtonStyle: ButtonStyle {
    var fill: Color
    var ink: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .frame(maxWidth: .infinity)
            .frame(height: 48)
            .background(fill)
            .foregroundStyle(ink)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .opacity(configuration.isPressed ? 0.86 : 1)
    }
}

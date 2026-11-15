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
        var startT = start.timeIntervalSince1970
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

    init() {
        Task { [weak self] in
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
        var pro = false
        for await result in StoreKit.Transaction.currentEntitlements {
            guard case .verified(let transaction) = result else { continue }
            guard transaction.productID == Self.productID else { continue }
            guard transaction.revocationDate == nil else { continue }
            if let expiration = transaction.expirationDate, expiration < Date() { continue }
            pro = true
        }
        isPro = pro
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
                guard case .verified(let transaction) = verification else {
                    purchaseError = "The purchase could not be verified."
                    return
                }
                await transaction.finish()
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
        guard case .verified(let transaction) = update else { return }
        await transaction.finish()
        await refreshEntitlement()
    }
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

import StoreKit
import SwiftUI
import UIKit

enum BroadcastLimits {
    /// Free broadcasts stop at 40 minutes. Pro removes the limit.
    static let freeSeconds: TimeInterval = 40 * 60
}

enum ProLegal {
    static let privacy = URL(string: "https://roomcast.channel/privacy")!
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

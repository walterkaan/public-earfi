import Foundation
import StoreKit

enum FreeSession {
    /// Free broadcasts stop at 40 minutes. Pro removes the limit.
    static let limit: TimeInterval = 40 * 60
}

/// StoreKit 2 auto-renewable subscription. The price shown in the app is
/// `Product.displayPrice` from the App Store (or the local .storekit file).
@MainActor
final class ProStore: ObservableObject {
    static let productID = "channel.roomcast.go.pro.monthly"

    @Published private(set) var isPro = false
    @Published private(set) var product: Product?
    @Published private(set) var status = ""
    @Published private(set) var busy = false

    private var updates: Task<Void, Never>?
    private var started = false

    /// Button label. Uses the storefront price when the product has loaded.
    var offerText: String {
        guard let product else { return "Upgrade to Pro" }
        return "Upgrade to Pro · \(product.displayPrice)"
    }

    /// Price plus the subscription period from the product, for the upgrade sheet.
    var priceDetail: String? {
        guard let product else { return nil }
        let period = Self.periodText(product.subscription?.subscriptionPeriod)
        if period.isEmpty { return product.displayPrice }
        return "\(product.displayPrice) / \(period)"
    }

    func start() {
        guard !started else { return }
        started = true
        updates = Task { [weak self] in
            for await update in Transaction.updates {
                guard let self else { continue }
                if let transaction = Self.verified(update) {
                    await transaction.finish()
                    await self.refreshEntitlements()
                }
            }
        }
        Task {
            await self.loadProduct()
            await self.refreshEntitlements()
        }
    }

    func purchase() async {
        guard let product else {
            status = "Pro isn’t available from the App Store yet."
            return
        }
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do {
            let result = try await product.purchase()
            switch result {
            case .success(let verification):
                guard let transaction = Self.verified(verification) else {
                    status = "The purchase couldn’t be verified."
                    return
                }
                await transaction.finish()
                await refreshEntitlements()
                status = isPro ? "Pro is active." : ""
            case .userCancelled:
                break
            case .pending:
                status = "The purchase is waiting for approval."
            @unknown default:
                break
            }
        } catch {
            status = error.localizedDescription
        }
    }

    func restore() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do {
            try await AppStore.sync()
            await refreshEntitlements()
            status = isPro ? "Pro is active." : "No Pro subscription was found for this Apple ID."
        } catch {
            status = error.localizedDescription
        }
    }

    private func loadProduct() async {
        do {
            let products = try await Product.products(for: [Self.productID])
            product = products.first
            if product == nil {
                status = "Pro isn’t available from the App Store yet."
            } else if status == "Pro isn’t available from the App Store yet." {
                status = ""
            }
        } catch {
            status = error.localizedDescription
        }
    }

    private func refreshEntitlements() async {
        var active = false
        for await result in Transaction.currentEntitlements {
            guard let transaction = Self.verified(result) else { continue }
            guard transaction.productID == Self.productID else { continue }
            guard transaction.revocationDate == nil else { continue }
            if let expiration = transaction.expirationDate, expiration < Date() { continue }
            active = true
        }
        isPro = active
    }

    private static func verified<T>(_ result: VerificationResult<T>) -> T? {
        switch result {
        case .verified(let value):
            return value
        case .unverified:
            return nil
        }
    }

    private static func periodText(_ period: Product.SubscriptionPeriod?) -> String {
        guard let period else { return "" }
        let value = period.value
        switch period.unit {
        case .day:
            return value == 1 ? "day" : "\(value) days"
        case .week:
            return value == 1 ? "week" : "\(value) weeks"
        case .month:
            return value == 1 ? "month" : "\(value) months"
        case .year:
            return value == 1 ? "year" : "\(value) years"
        @unknown default:
            return ""
        }
    }
}

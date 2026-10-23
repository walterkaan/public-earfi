import SwiftUI

@main
struct RoomCastGoApp: App {
    @StateObject private var model = BroadcastModel()

    var body: some Scene {
        WindowGroup {
            BroadcastView(model: model)
        }
    }
}

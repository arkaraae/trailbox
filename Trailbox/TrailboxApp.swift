import SwiftUI

@main
struct TrailboxApp: App {
    @StateObject private var hike = TrailboxViewModel()
    var body: some Scene {
        WindowGroup { ContentView().environmentObject(hike) }
    }
}

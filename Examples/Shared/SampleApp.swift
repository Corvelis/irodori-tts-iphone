import SwiftUI

@main struct IrodoriSampleApp: App {
    @StateObject private var model = SampleModel()
    var body: some Scene {
        WindowGroup {
            #if os(macOS)
            ContentView(model: model).frame(minWidth: 740, minHeight: 680)
            #else
            NavigationStack {
                ContentView(model: model).toolbar(.hidden, for: .navigationBar)
            }
            #endif
        }
        #if os(macOS)
        .defaultSize(width: 1060, height: 780)
        #endif
    }
}

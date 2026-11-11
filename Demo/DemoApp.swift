import SwiftUI

@main
struct DemoApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

struct ContentView: View {
    var body: some View {
        NavigationStack {
            List {
                NavigationLink("Grid") { GridExample() }
                NavigationLink("Slow and failing loads") { LoadingExample() }
                NavigationLink("Accessory overlay") { AccessoryExample() }
                NavigationLink("UIKit") { UIKitExample().navigationTitle("UIKit") }
            }
            .navigationTitle("MDPhotoBrowser")
        }
    }
}

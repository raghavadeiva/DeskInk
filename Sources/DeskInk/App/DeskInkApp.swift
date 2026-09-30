import SwiftUI

@main
struct DeskInkApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 1_080, minHeight: 700)
        }
        .defaultSize(width: 1_300, height: 820)
        .commands {
            CommandMenu("Accuracy Test") {
                Button("Generate Letter Grid…") {
                    model.generateAccuracyGrid(.letter)
                }
                Button("Generate A4 Grid…") {
                    model.generateAccuracyGrid(.a4)
                }
            }
        }
    }
}

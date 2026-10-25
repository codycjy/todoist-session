import SwiftUI

@main
struct SessionApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            MenuPanel().environmentObject(model)
        } label: {
            Text(model.menuTitle)
        }
        .menuBarExtraStyle(.window)

        Window("Session", id: "main") {
            TodayView().environmentObject(model).frame(minWidth: 720, minHeight: 480)
        }
    }
}

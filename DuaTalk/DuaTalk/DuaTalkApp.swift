import SwiftUI

@main
struct DuaTalkApp: App {
    @StateObject private var viewModel = MenuBarViewModel()

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(viewModel: viewModel)
        } label: {
            menuBarLabel
        }
        .menuBarExtraStyle(.menu)
    }

    @ViewBuilder
    private var menuBarLabel: some View {
        switch viewModel.appState {
        case .idle:
            Image(systemName: "mic")
        case .loading:
            Image(systemName: "hourglass")
        case .recording:
            Image(systemName: "record.circle.fill")
                .symbolRenderingMode(.palette)
                .foregroundStyle(.red)
        case .processing:
            Image(systemName: "hourglass")
        case .speaking:
            Image(systemName: "speaker.wave.2.fill")
                .symbolRenderingMode(.palette)
                .foregroundStyle(.blue)
        }
    }
}

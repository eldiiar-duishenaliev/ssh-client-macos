import Foundation

/// Holds the open sessions and which one is selected.
@MainActor
final class SessionStore: ObservableObject {
    @Published private(set) var sessions: [SessionController] = []
    @Published var selectedID: UUID?
    @Published var isConnectSheetPresented = false

    var selected: SessionController? {
        sessions.first { $0.id == selectedID }
    }

    /// Opens a session, selects it, and starts connecting.
    @discardableResult
    func open(_ request: ConnectionRequest) -> SessionController {
        let controller = SessionController(request: request)
        sessions.append(controller)
        selectedID = controller.id
        controller.connect()
        return controller
    }

    /// Closes a session and moves the selection.
    func close(_ controller: SessionController) {
        controller.disconnect()
        guard let index = sessions.firstIndex(where: { $0.id == controller.id }) else { return }
        sessions.remove(at: index)

        if selectedID == controller.id {
            selectedID = sessions.indices.contains(index)
                ? sessions[index].id
                : sessions.last?.id
        }
    }
}

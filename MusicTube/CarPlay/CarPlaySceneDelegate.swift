import CarPlay
import UIKit

final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    private let manager = CarPlayManager()

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didConnect interfaceController: CPInterfaceController
    ) {
        connect(interfaceController: interfaceController)
    }

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didDisconnectInterfaceController interfaceController: CPInterfaceController
    ) {
        disconnect()
    }

    private func connect(interfaceController: CPInterfaceController) {
        manager.attach(interfaceController: interfaceController)
        AppContainer.shared.carPlayManager = manager

        if let appState = AppContainer.shared.appState {
            manager.refresh(using: appState)
        }
    }

    private func disconnect() {
        manager.detach()

        if AppContainer.shared.carPlayManager === manager {
            AppContainer.shared.carPlayManager = nil
        }
    }
}

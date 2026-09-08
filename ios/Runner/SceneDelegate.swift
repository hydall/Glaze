import Flutter
import UIKit
import app_links

class SceneDelegate: FlutterSceneDelegate {
  override func scene(
    _ scene: UIScene,
    openURLContexts URLContexts: Set<UIOpenURLContext>
  ) {
    guard let url = URLContexts.first?.url else { return }
    AppLinks.shared.handleLink(url: url)
  }
}

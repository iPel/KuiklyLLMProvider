import UIKit

@main
class AppDelegate: UIResponder, UIApplicationDelegate {

    var window: UIWindow?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        window = UIWindow(frame: UIScreen.main.bounds)
        // 默认进 LLMChat，与 Android（KuiklyRenderActivity.pageName 默认值）、
        // 鸿蒙（pages/Index 路由）保持一致；CLI 预览可用 KUIKLY_PAGE 覆盖。
        let pageName = ProcessInfo.processInfo.environment["KUIKLY_PAGE"] ?? "LLMChat"
        let vc = KuiklyRenderViewController(pageName: pageName, pageData: [:])
        let nav = UINavigationController(rootViewController: vc)
        nav.isNavigationBarHidden = true
        window?.rootViewController = nav
        window?.makeKeyAndVisible()
        return true
    }
}

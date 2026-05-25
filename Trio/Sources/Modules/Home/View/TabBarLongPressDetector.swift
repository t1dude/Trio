import SwiftUI
import UIKit

/// Attaches a long-press gesture recogniser to the underlying UITabBar so that a
/// long-press on the centre tab item (the + button) can be detected without
/// interfering with regular tab-selection taps.
struct TabBarLongPressDetector: UIViewRepresentable {
    var onLongPressCenter: () -> Void

    func makeUIView(context _: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_: UIView, context: Context) {
        DispatchQueue.main.async {
            guard let tabBar = UIApplication.shared.firstKeyWindow?
                .rootViewController?.firstTabBar()
            else { return }

            guard !(tabBar.gestureRecognizers ?? []).contains(where: {
                ($0 as? UILongPressGestureRecognizer)?.delegate === context.coordinator
            }) else { return }

            let recognizer = UILongPressGestureRecognizer(
                target: context.coordinator,
                action: #selector(Coordinator.handleLongPress(_:))
            )
            recognizer.minimumPressDuration = 0.5
            recognizer.delegate = context.coordinator
            tabBar.addGestureRecognizer(recognizer)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onLongPressCenter: onLongPressCenter)
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var onLongPressCenter: () -> Void

        init(onLongPressCenter: @escaping () -> Void) {
            self.onLongPressCenter = onLongPressCenter
        }

        @objc func handleLongPress(_ recognizer: UILongPressGestureRecognizer) {
            guard recognizer.state == .began,
                  let tabBar = recognizer.view as? UITabBar
            else { return }

            let count = CGFloat(tabBar.items?.count ?? 5)
            let itemWidth = tabBar.bounds.width / count
            let touchX = recognizer.location(in: tabBar).x
            let centerIndex = floor(count / 2)

            guard touchX >= itemWidth * centerIndex,
                  touchX < itemWidth * (centerIndex + 1)
            else { return }

            DispatchQueue.main.async { [weak self] in
                self?.onLongPressCenter()
            }
        }

        func gestureRecognizer(
            _: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith _: UIGestureRecognizer
        ) -> Bool { true }
    }
}

private extension UIApplication {
    var firstKeyWindow: UIWindow? {
        connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)
    }
}

private extension UIViewController {
    func firstTabBar() -> UITabBar? {
        if let tc = self as? UITabBarController { return tc.tabBar }
        return children.lazy.compactMap { $0.firstTabBar() }.first
            ?? presentedViewController?.firstTabBar()
    }
}

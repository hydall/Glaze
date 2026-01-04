import Foundation

@objc public class BackgroundMode: NSObject {
    @objc public func echo(_ value: String) -> String {
        print(value)
        return value
    }
}

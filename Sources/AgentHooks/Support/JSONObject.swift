import Foundation

/// JSON the way this package reads it: a top-level object, or nil.
enum JSONObject {
    static func parse(_ data: Data) -> [String: Any]? { (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] }
}

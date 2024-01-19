import Foundation

struct Metadata: Equatable, Codable {
    let sdkVersion: String?
    let iosVersion: String?
    let macosVersion: String?

    static var current: Metadata = {
        let sdkVersion = SDK.version
        let systemVersion = SystemVersion.version

        #if os(iOS) || os(visionOS)
        return Metadata(sdkVersion: sdkVersion, iosVersion: systemVersion, macosVersion: nil)
        #elseif os(OSX)
        return Metadata(sdkVersion: sdkVersion, iosVersion: nil, macosVersion: systemVersion)
        #endif
    }()
}

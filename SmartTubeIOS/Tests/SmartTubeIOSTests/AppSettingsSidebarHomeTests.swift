import Foundation
import Testing

@testable import SmartTubeIOSCore

// MARK: - AppSettingsSidebarHomeTests
//
// `useSidebarHome` switches tvOS Home between the sidebar layout and the old top tab bar.
// Settings saved before the flag existed must decode with the platform default, and an
// explicit choice must survive an encode/decode round trip.

@Suite("AppSettings.useSidebarHome")
struct AppSettingsSidebarHomeTests {

    @Test("Settings saved before the flag existed decode with the platform default")
    func missingFlagUsesDefault() throws {
        let json = """
            {
                "preferredQuality": "1080p",
                "hideShorts": true
            }
            """
        let decoded = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
        #expect(decoded.useSidebarHome == AppSettings().useSidebarHome)
        #expect(decoded.hideShorts)
    }

    @Test("An explicit false survives an encode/decode round trip")
    func explicitFalseRoundTrips() throws {
        var settings = AppSettings()
        settings.useSidebarHome = false
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
        #expect(decoded.useSidebarHome == false)
    }

    #if os(tvOS)
    @Test("The sidebar layout is the default on tvOS")
    func defaultIsOnForTVOS() {
        #expect(AppSettings().useSidebarHome)
    }
    #endif
}

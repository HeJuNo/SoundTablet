import Testing
@testable import SoundTablet

struct TileViewTests {
    @Test func clockFormatsMinutesAndSeconds() {
        #expect(TileView.clock(0) == "00:00")
        #expect(TileView.clock(83.9) == "01:23")
        #expect(TileView.clock(-5) == "00:00")
    }

    @Test func iconsLightOnlyActiveSettings() {
        var s = TrackSettings.default
        s.loop = true; s.fadeOut = 2
        let on = TileView.icons(s, hasAutomations: false).map(\.on)
        #expect(on == [false, false, true, false, true])
    }
}

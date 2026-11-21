import Testing

@testable import SmartTubeIOSCore

@Suite("FriendlyFileName")
struct FriendlyFileNameTests {
    @Test("strips forbidden characters and collapses spaces")
    func stripsForbidden() {
        #expect(
            FriendlyFileName.make(title: "Open Ocean: 10 Hours | BBC Earth", videoId: "x", fileExtension: "mp4")
                == "Open Ocean 10 Hours BBC Earth.mp4")
        #expect(FriendlyFileName.make(title: "a/b\\c?d*e", videoId: "x", fileExtension: "mp4") == "abcde.mp4")
    }

    @Test("keeps ordinary punctuation and non-Latin text")
    func keepsOrdinaryText() {
        #expect(
            FriendlyFileName.make(title: "Hello, World! (2026) 日本語", videoId: "x", fileExtension: "m4a")
                == "Hello, World! (2026) 日本語.m4a")
    }

    @Test("falls back to the video id when nothing usable is left")
    func fallsBack() {
        #expect(FriendlyFileName.make(title: "  ///  ", videoId: "abc123", fileExtension: "mp4") == "abc123.mp4")
        #expect(FriendlyFileName.make(title: "", videoId: "abc123", fileExtension: "mp4") == "abc123.mp4")
    }

    @Test("long titles are truncated and leading dots dropped")
    func truncates() {
        let long = String(repeating: "A", count: 300)
        let name = FriendlyFileName.make(title: long, videoId: "x", fileExtension: "mp4")
        #expect(name.count == FriendlyFileName.maxBaseLength + 4)
        #expect(!FriendlyFileName.make(title: "...hidden", videoId: "x", fileExtension: "mp4").hasPrefix("."))
    }
}

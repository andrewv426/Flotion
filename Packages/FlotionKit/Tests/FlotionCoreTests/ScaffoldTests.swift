import Testing
import FlotionCore

@Test func defaultDatabaseLivesInApplicationSupport() {
    let path = Flotion.defaultDatabaseURL.path
    #expect(path.hasSuffix("Application Support/Flotion/flotion.sqlite"))
}

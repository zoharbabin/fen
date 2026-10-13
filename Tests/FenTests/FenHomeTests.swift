@testable import FenCore
import Foundation
import Testing

/// Issue #5: on a real iPhone, Fen couldn't create `.fen` at the top of its app container, so adding a
/// folder failed with "You don't have permission to save the file .fen".
struct FenHomeTests {
    private let container = URL(fileURLWithPath: "/var/mobile/Containers/Data/Application/ABC", isDirectory: true)

    @Test
    func onAPhoneTheFolderIsInLibraryNotAtTheTopOfTheContainer() {
        let root = FenHome.root(inContainer: container, onPhone: true)
        #expect(root.path == container.path + "/Library/.fen")
    }

    @Test
    func onAMacTheFolderIsStillDotFenInTheHome() {
        let root = FenHome.root(inContainer: container, onPhone: false)
        #expect(root.path == container.path + "/.fen")
    }
}

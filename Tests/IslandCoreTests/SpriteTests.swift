import Foundation
import Testing

@testable import IslandCore

@Suite("Clawd")
struct ClawdTests {
    /// Renders a frame the way the terminal does, so a failure is readable.
    private func render(_ frame: ClawdFrame) -> String {
        (0..<frame.height).map { y in
            (0..<frame.width).map { x in frame.isSet(x: x, y: y) ? "#" : "." }.joined()
        }.joined(separator: "\n")
    }

    @Test("Block characters expand to the right sub-pixels")
    func decodesQuadrants() {
        // ▛ is every quadrant but the lower right; █ is all four.
        let frame = ClawdSprite.decode(rows: ["\u{259B}\u{2588}"])
        #expect(frame.isSet(x: 0, y: 0))
        #expect(frame.isSet(x: 1, y: 0))
        #expect(frame.isSet(x: 0, y: 1))
        #expect(!frame.isSet(x: 1, y: 1), "the gap is Clawd's eye")
        #expect(frame.isSet(x: 2, y: 0) && frame.isSet(x: 3, y: 1))
    }

    @Test("Every pose fills the 18 x 6 grid and has two eyes")
    func posesDecode() {
        for pose in ClawdPose.allCases {
            let frame = ClawdSprite.frame(pose)
            #expect(frame.width == 18 && frame.height == 6)
            #expect(frame.pixels.contains(true), "\(pose) drew nothing")

            // The eyes are unlit sub-pixels inside the head band.
            let headGaps = (0..<18).filter { x in !frame.isSet(x: x, y: 0) || !frame.isSet(x: x, y: 1) }
            #expect(headGaps.count >= 2, "\(pose) lost its eyes")
        }
    }

    @Test("Looking left and right are different frames")
    func posesDiffer() {
        #expect(ClawdSprite.frame(.lookLeft) != ClawdSprite.frame(.lookRight))
        #expect(ClawdSprite.frame(.standing) != ClawdSprite.frame(.armsUp))
        #expect(render(ClawdSprite.frame(.standing)).contains("#"))
    }

    @Test("Each status gets its own pose loop")
    func animationsPerStatus() {
        let working = ClawdAnimation.animation(for: .working, secondsInStatus: 0)
        #expect(working.poses.contains(.lookLeft) && working.poses.contains(.lookRight))
        #expect(working.pose(at: 0) == .lookLeft)
        #expect(working.pose(at: 0.4) == .standing)

        #expect(ClawdAnimation.animation(for: .question, secondsInStatus: 0).poses.first == .armsUp)
        #expect(ClawdAnimation.animation(for: .complete, secondsInStatus: 0.2).poses == [.armsUp])
        #expect(ClawdAnimation.animation(for: .complete, secondsInStatus: 5).poses == [.standing])
        if case .shake = ClawdAnimation.animation(for: .error, secondsInStatus: 0).motion {} else {
            Issue.record("errors should shake")
        }
    }
}

@Suite("Codex pets")
struct PetTests {
    @Test("Frame timings walk the row and loop")
    func frameSelection() {
        let idle = PetAnimations.idle
        #expect(idle.frameCount == 6)
        #expect(idle.frame(at: 0) == 0)
        #expect(idle.frame(at: 0.30) == 1)
        #expect(idle.frame(at: idle.totalDuration - 0.01) == 5)
        #expect(idle.frame(at: idle.totalDuration + 0.01) == 0, "the loop wraps")
    }

    @Test("Statuses map onto the contract's rows")
    func statusRows() {
        #expect(PetAnimations.animation(for: .working, secondsInStatus: 0).row == 7)
        #expect(PetAnimations.animation(for: .question, secondsInStatus: 0).row == 6)
        #expect(PetAnimations.animation(for: .plan, secondsInStatus: 0).row == 8)
        #expect(PetAnimations.animation(for: .error, secondsInStatus: 0).row == 5)
        #expect(PetAnimations.animation(for: .complete, secondsInStatus: 0.2).row == 4)
        #expect(PetAnimations.animation(for: .complete, secondsInStatus: 9).row == 0)
        #expect(PetAnimations.animation(for: .idle, secondsInStatus: 0).row == 0)
    }

    @Test("The sprite sheet is read out of the installed Codex app")
    func readsInstalledPet() throws {
        try #require(
            FileManager.default.fileExists(atPath: IslandPaths.chatGPTAsar),
            "Codex app not installed; skipping"
        )
        let catalog = PetCatalog(cacheDirectory: NSTemporaryDirectory() + "agent-island-tests")
        let pets = catalog.builtInPetIDs()
        #expect(pets.contains("codex"))

        let path = try #require(catalog.imagePath(for: "codex"))
        let data = try #require(FileManager.default.contents(atPath: path))
        #expect(data.prefix(4) == Data("RIFF".utf8), "expected a webp sheet")
        #expect(data.count > 100_000)
    }

    @Test("The asar index resolves a known path")
    func readsAsarIndex() throws {
        try #require(
            FileManager.default.fileExists(atPath: IslandPaths.chatGPTAsar),
            "Codex app not installed; skipping"
        )
        let reader = try #require(AsarReader(path: IslandPaths.chatGPTAsar))
        let names = reader.names(inDirectory: "webview/assets")
        #expect(!names.isEmpty)

        let sheet = try #require(names.first { $0.hasPrefix("codex-spritesheet-v") })
        let entry = try #require(reader.entry(at: "webview/assets/\(sheet)"))
        #expect(entry.size > 0)
    }
}

@Suite("Pet catalog fallbacks")
struct PetCatalogFallbackTests {
    @Test("A missing app yields no pets rather than a crash")
    func handlesMissingApp() {
        let catalog = PetCatalog(
            asarPath: "/nope/app.asar",
            petsDirectory: "/nope/pets",
            cacheDirectory: NSTemporaryDirectory()
        )
        #expect(catalog.builtInPetIDs().isEmpty)
        #expect(catalog.customPets().isEmpty)
        #expect(catalog.imagePath(for: "codex") == nil)
    }

    @Test("A hatched pet in ~/.codex/pets is found")
    func findsCustomPet() throws {
        let root = NSTemporaryDirectory() + "island-pets-\(UUID().uuidString)"
        let petDirectory = root + "/sparky"
        try FileManager.default.createDirectory(atPath: petDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }

        let manifest = """
            {"id":"sparky","displayName":"Sparky","spriteVersionNumber":2,
             "spritesheetPath":"spritesheet.webp"}
            """
        try Data(manifest.utf8).write(to: URL(fileURLWithPath: petDirectory + "/pet.json"))
        try Data("RIFF".utf8).write(to: URL(fileURLWithPath: petDirectory + "/spritesheet.webp"))

        let catalog = PetCatalog(asarPath: "/nope", petsDirectory: root, cacheDirectory: root)
        let pets = catalog.customPets()
        #expect(pets.count == 1)
        #expect(pets.first?.displayName == "Sparky")
        #expect(catalog.imagePath(for: "sparky") == petDirectory + "/spritesheet.webp")
    }
}

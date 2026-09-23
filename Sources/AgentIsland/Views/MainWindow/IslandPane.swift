import IslandCore
import SwiftUI

/// What the island watches, how the circles behave, and which Codex pet to show.
struct IslandPane: View {
    @Bindable var settings: IslandSettings

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $settings.watchClaude) {
                    Text("Claude Code")
                    Text("The Code tab in Claude.app, and the claude CLI")
                }
                Toggle(isOn: $settings.watchCodex) {
                    Text("Codex")
                    Text("Codex in ChatGPT.app, and the codex CLI")
                }
            } header: {
                Text("Watch")
            } footer: {
                Text("Switching an agent off sends its circles back into the notch straight away.")
            }

            Section {
                Picker("Circles", selection: $settings.visibility) {
                    ForEach(IslandSettings.Visibility.allCases) { option in
                        Text(option.label).tag(option)
                    }
                }
                .pickerStyle(.radioGroup)

                Picker("New circles appear", selection: $settings.newCircleSide) {
                    Text("Left of the notch").tag(IslandSide.left)
                    Text("Right of the notch").tag(IslandSide.right)
                }
                .pickerStyle(.segmented)

                if settings.visibility == .popThenTuck {
                    LabeledContent("Tuck back after") {
                        HStack {
                            Slider(value: $settings.tuckAfter, in: 2...30, step: 1)
                                .frame(maxWidth: 220)
                            Text("\(Int(settings.tuckAfter)) s")
                                .monospacedDigit()
                                .frame(width: 34, alignment: .trailing)
                        }
                    }
                }
            } header: {
                Text("Circles")
            } footer: {
                Text(circlesFooter)
            }

            Section {
                Picker("Return on a card", selection: $settings.pasteSends) {
                    Text("Pastes and sends").tag(true)
                    Text("Only pastes").tag(false)
                }
                .pickerStyle(.segmented)

                LabeledContent("Accessibility") {
                    if isAllowed {
                        Label("Allowed", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(IslandStyle.complete)
                    } else {
                        Button("Allow\u{2026}") {
                            ChatPaster.requestPermission()
                            recheck()
                        }
                    }
                }
            } header: {
                Text("Messages")
            } footer: {
                Text("A message typed on a card goes into that chat's own box in the Claude app, as if you had typed it there. Pasting takes Accessibility permission; without it, the chat opens and the message waits on your clipboard.")
            }

            Section("Codex Pet") {
                PetPicker(selection: $settings.codexPetID)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Island")
        .onAppear(perform: recheck)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in recheck() }
    }

    /// Whether macOS lets the app paste into Claude. Read when the page shows and each
    /// time the app comes back from System Settings.
    @State private var isAllowed = ChatPaster.isAllowed

    private func recheck() {
        isAllowed = ChatPaster.isAllowed
    }

    private var circlesFooter: String {
        switch settings.visibility {
        case .stayWhileWorking:
            "A circle stays beside the notch for as long as its agent works, and for ten minutes after it finishes. Drag a circle to move it to the other side of the notch, or to reorder it."
        case .popThenTuck:
            "A circle pops out with news, then slides back into the notch. Questions, plans, and errors stay out until they are handled. Point at the notch to bring every circle back out. Drag a circle to move it to the other side."
        }
    }
}

// MARK: - Codex pet

/// A grid of the pets the Codex app ships, plus any you hatched yourself.
private struct PetPicker: View {
    @Binding var selection: String
    private let pets = PetSpriteStore.shared.availablePetIDs()

    var body: some View {
        if pets.isEmpty {
            Text("Install ChatGPT.app to use the Codex pets. Until then Codex circles show a plain stand-in.")
                .foregroundStyle(.secondary)
        } else {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 84, maximum: 120), spacing: 12)], spacing: 12) {
                ForEach(pets, id: \.self) { pet in
                    PetTile(pet: pet, isSelected: pet == selection) { selection = pet }
                }
            }
            .padding(.vertical, 4)
        }
    }
}

private struct PetTile: View {
    let pet: String
    let isSelected: Bool
    let select: () -> Void

    @State private var preview: CGImage?
    @State private var loaded = false

    var body: some View {
        Button(action: select) {
            VStack(spacing: 5) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(isSelected ? Color.accentColor.opacity(0.16) : Color.primary.opacity(0.05))
                    if let preview {
                        Image(decorative: preview, scale: 2)
                            .resizable()
                            .interpolation(.high)
                            .aspectRatio(contentMode: .fit)
                            .padding(6)
                    } else if loaded {
                        Image(systemName: "questionmark")
                            .foregroundStyle(.secondary)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                }
                .frame(height: 80)
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 2)
                }

                Text(Self.name(for: pet))
                    .font(.caption)
                    .foregroundStyle(isSelected ? .primary : .secondary)
                    .lineLimit(1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Self.name(for: pet))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .task(id: pet) {
            preview = await PetPreviews.shared.preview(for: pet)
            loaded = true
        }
    }

    /// `null-signal` reads as "Null Signal".
    static func name(for pet: String) -> String {
        pet.split(separator: "-").map { $0.capitalized }.joined(separator: " ")
    }
}

/// One still frame per pet, for the picker.
///
/// Each sprite sheet decodes to about 14 MB, so a preview decodes it off the main
/// thread, copies out a single idle frame, and lets the sheet go.
@MainActor
final class PetPreviews {
    static let shared = PetPreviews()

    private var cache: [String: CGImage] = [:]
    private var missing: Set<String> = []

    func preview(for pet: String) async -> CGImage? {
        if let cached = cache[pet] { return cached }
        if missing.contains(pet) { return nil }

        let rendered = await Task.detached(priority: .userInitiated) {
            PetPreviews.render(pet: pet)
        }.value

        if let image = rendered?.image {
            cache[pet] = image
        } else {
            missing.insert(pet)
        }
        return rendered?.image
    }

    private struct Rendered: @unchecked Sendable {
        let image: CGImage
    }

    private nonisolated static func render(pet: String) -> Rendered? {
        guard
            let path = PetCatalog().imagePath(for: pet),
            let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
            let sheet = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }

        let layout = PetAtlasLayout()
        let width = sheet.width / layout.columns
        let height = sheet.height / layout.rows
        guard
            let cell = sheet.cropping(to: CGRect(x: 0, y: 0, width: width, height: height)),
            let space = CGColorSpace(name: CGColorSpace.sRGB),
            let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else { return nil }

        // A cropped image still holds the whole sheet; drawing it into its own
        // bitmap is what lets the sheet be freed.
        context.draw(cell, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage().map(Rendered.init)
    }
}

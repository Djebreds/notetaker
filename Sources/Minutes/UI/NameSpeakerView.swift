import SwiftUI

/// Popover for naming a voice: Minutes remembers it and recognises the person in later meetings.
struct NameSpeakerView: View {
    let meetingID: UUID
    let speaker: MeetingSpeaker
    let label: String
    let done: () -> Void

    @Environment(AppModel.self) private var model
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Who is \(label)?").font(.headline)
            Text(String(format: "%.0f min of speech in this meeting. Minutes will recognise this voice in later meetings.",
                        max(1, speaker.seconds / 60)))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if speaker.name == nil, let suggestion = speaker.suggestion {
                Button("Sounds like \(suggestion): use it") { save(suggestion) }
            }
            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit { save(name) }
            let known = model.voices.profiles.map(\.name).filter { $0 != speaker.name }.sorted()
            if !known.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        ForEach(known.prefix(10), id: \.self) { person in
                            Button(person) { save(person) }.controlSize(.small)
                        }
                    }
                }
            }
            HStack {
                let me = model.settings.userName.trimmingCharacters(in: .whitespaces)
                if !me.isEmpty, speaker.name != me {
                    Button("That's me") { save(me) }
                        .help("Your voice reached the call through someone else's mic")
                }
                if speaker.confirmed {
                    Button("Forget name", role: .destructive) { save("") }
                }
                Spacer()
                Button("Save") { save(name) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(14)
        .frame(width: 320)
        .onAppear { name = speaker.name ?? "" }
    }

    private func save(_ value: String) {
        model.processing.nameSpeaker(meetingID, speakerID: speaker.id, name: value)
        done()
    }
}

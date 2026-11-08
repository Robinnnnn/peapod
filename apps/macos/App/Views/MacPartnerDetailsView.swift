import SwiftUI
import UniformTypeIdentifiers

struct MacPartnerDetailsView: View {
    let person: Person
    let showInConversation: (UUID) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(MacAppModel.self) private var model
    @Environment(\.colorScheme) private var colorScheme
    @State private var showingNicknameEditor = false
    @State private var editedNickname = ""
    @State private var showingPhotoImporter = false
    @State private var pendingPhoto: MacPartnerPhotoSelection?
    @State private var showingMap = false
    @State private var showingPinnedMessages = false
    @State private var pendingPinnedMessageID: UUID?
    @State private var showingSignOutConfirmation = false
    @State private var photoTarget: SecureConversationResetTarget?
    @State private var errorMessage: String?

    private var displayName: String {
        model.partnerPhotoStore.nickname(accountID: model.currentUser.id, partnerID: person.id) ?? person.displayName
    }

    var body: some View {
        let photo = model.partnerPhotoStore.image(accountID: model.currentUser.id, partnerID: person.id)
        VStack(spacing: 18) {
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            MacAvatar(person: person, size: 104, image: photo)
                .accessibilityLabel("Photo for \(displayName)")
                .accessibilityValue(photo == nil ? "Initials" : "Custom photo")
            Text(displayName)
                .font(.title.bold())
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
                .accessibilityAddTraits(.isHeader)
            TimelineView(.periodic(from: .now, by: 30)) { context in
                if let presentation = model.mutualLocationPresentation(at: context.date) {
                    Button { showingMap = true } label: {
                        Label(presentation.subtitle, systemImage: "map")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(GiftWrapAppearance.accent(colorScheme == .dark))
                    .accessibilityLabel("Show shared phone locations: \(presentation.subtitle)")
                }
            }
            List {
                Button("Edit Nickname", systemImage: "pencil") {
                    editedNickname = model.partnerPhotoStore.nickname(accountID: model.currentUser.id, partnerID: person.id) ?? ""
                    showingNicknameEditor = true
                }
                .accessibilityIdentifier("partner-nickname-edit")
                .listRowSeparator(.hidden)

                Button(photo == nil ? "Choose Photo…" : "Change Photo…", systemImage: "photo") {
                    photoTarget = model.attachmentPreparationTarget
                    showingPhotoImporter = photoTarget != nil
                }
                .accessibilityIdentifier("partner-photo-choose")
                .listRowSeparator(.hidden)

                if photo != nil {
                    Button("Remove Photo", systemImage: "trash", role: .destructive) {
                        do {
                            try model.partnerPhotoStore.removePhoto(accountID: model.currentUser.id, partnerID: person.id)
                            errorMessage = nil
                        } catch { errorMessage = "The photo couldn’t be removed. Try again." }
                    }
                    .accessibilityIdentifier("partner-photo-remove")
                    .listRowSeparator(.hidden)
                }

                Button("Pinned Messages", systemImage: "pin") {
                    showingPinnedMessages = true
                }
                .disabled(model.messagePins == nil)
                .accessibilityIdentifier("profile-pinned-messages")
                .listRowSeparator(.hidden)

                Button("Sign Out", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) {
                    showingSignOutConfirmation = true
                }
                .accessibilityIdentifier("profile-sign-out")
                .listRowSeparator(.hidden)
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
            .scrollDisabled(true)
            .frame(height: photo == nil ? 176 : 220)

            if let errorMessage {
                Text(errorMessage).font(.callout).foregroundStyle(.red).multilineTextAlignment(.center)
            }
        }
        .padding(28)
        .frame(width: 360)
        .background { GiftWrapWallpaper(composition: .tiled).overlay(.regularMaterial) }
        .fileImporter(isPresented: $showingPhotoImporter, allowedContentTypes: [.image]) { result in
            guard let target = photoTarget, model.isCurrentAttachmentPreparation(target), model.partner.id == person.id else {
                photoTarget = nil
                return
            }
            defer { photoTarget = nil }
            do {
                let url = try result.get()
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                guard let count = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize, count <= 20 * 1024 * 1024 else {
                    errorMessage = "Choose a photo up to 20 MiB."; return
                }
                let data = try Data(contentsOf: url, options: .mappedIfSafe)
                guard let image = MacPartnerPhotoCrop.decode(data: data) else {
                    throw PartnerPhotoStore.PhotoError.invalidImage
                }
                pendingPhoto = MacPartnerPhotoSelection(image: image, target: target)
                errorMessage = nil
            } catch CocoaError.userCancelled {
                // Cancel leaves the current local photo untouched.
            } catch { errorMessage = "The photo couldn’t be saved. Choose another photo or try again." }
        }
        .sheet(item: $pendingPhoto) { selection in
            MacPartnerPhotoCropView(image: selection.image, onCancel: {
                pendingPhoto = nil
            }, onSave: { data in
                defer { pendingPhoto = nil }
                guard model.isCurrentAttachmentPreparation(selection.target), model.partner.id == person.id else { return }
                do {
                    try model.partnerPhotoStore.savePhoto(data: data, accountID: selection.target.accountID, partnerID: person.id)
                    errorMessage = nil
                } catch {
                    errorMessage = "The photo couldn’t be saved. Choose another photo or try again."
                }
            })
        }
        .sheet(isPresented: $showingMap) { MacMutualLocationMapView().environment(model) }
        .sheet(isPresented: $showingPinnedMessages, onDismiss: {
            guard let id = pendingPinnedMessageID else { return }
            pendingPinnedMessageID = nil
            showInConversation(id)
        }) {
            if let pins = model.messagePins {
                MacPinnedMessagesView(controller: pins, currentUserID: model.currentUser.id,
                    partnerName: person.displayName, showInConversation: { id in
                        pendingPinnedMessageID = id
                        showingPinnedMessages = false
                    })
                .environment(model)
            }
        }
        .alert("Edit Nickname", isPresented: $showingNicknameEditor) {
            TextField(person.displayName, text: $editedNickname)
                .accessibilityIdentifier("partner-nickname-field")
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                do {
                    try model.partnerPhotoStore.saveNickname(editedNickname, accountID: model.currentUser.id, partnerID: person.id)
                    errorMessage = nil
                } catch {
                    errorMessage = "The nickname couldn’t be saved. Try again."
                }
            }
        } message: {
            Text("Only shown to you on this device. Leave blank to use \(person.displayName).")
        }
        .alert("Sign out of Peapod?", isPresented: $showingSignOutConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Sign Out", role: .destructive) {
                Task { await model.signOut() }
            }
        } message: {
            Text("Signing in again with the same Apple account will reopen "
                + "this conversation. Unsent shared items will be removed.")
        }
        .onChange(of: model.conversationDeletionTarget) { _, _ in
            pendingPinnedMessageID = nil
            showingPinnedMessages = false
            showingSignOutConfirmation = false
            showingNicknameEditor = false
            showingPhotoImporter = false; photoTarget = nil; pendingPhoto = nil; showingMap = false; dismiss()
        }
        .accessibilityIdentifier("partner-details")
    }
}

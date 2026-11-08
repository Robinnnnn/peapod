import PhotosUI
import SwiftUI
import UIKit

struct PartnerPhotoAvatar: View {
    let photo: UIImage?
    let initials: String?
    let size: CGFloat

    var body: some View {
        Group {
            if let photo {
                Image(uiImage: photo)
                    .resizable()
                    .scaledToFill()
            } else {
                Circle()
                    .fill(GiftWrapAppearance.pine.gradient)
                    .overlay {
                        if let initials {
                            Text(initials)
                                .font(.system(size: size * 0.34, weight: .semibold))
                                .foregroundStyle(.white)
                        } else {
                            Image(systemName: "person.fill")
                                .font(.system(size: size * 0.4))
                                .foregroundStyle(.white)
                        }
                    }
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }
}

struct PartnerProfileView: View {
    let accountID: String
    let partnerID: String
    let initials: String
    let name: String
    let store: PartnerPhotoStore
    let searchMessages: () -> Void
    let showMessageInConversation: (UUID) -> Void

    @Environment(AppModel.self) private var model
    @State private var showingPinnedMessages = false
    @State private var pendingPinnedJump: UUID?

    @State private var pendingPhoto: PartnerPhotoSelection?
    @State private var showingNicknameEditor = false
    @State private var editedNickname = ""
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var showingPhotoPicker = false
    @State private var isLoading = false
    @State private var errorMessage: String?

    private var displayName: String {
        store.nickname(accountID: accountID, partnerID: partnerID) ?? name
    }

    var body: some View {
        let photo = store.image(accountID: accountID, partnerID: partnerID)

        ScrollView {
            VStack(spacing: 24) {
                VStack(spacing: 14) {
                    PartnerPhotoAvatar(photo: photo, initials: initials, size: 104)
                        .accessibilityLabel("Photo for \(displayName)")
                        .accessibilityValue(photo == nil ? "Initials" : "Custom photo")
                        .accessibilityIdentifier("partner-photo-preview")

                    Text(displayName)
                        .font(.title.bold())
                        .multilineTextAlignment(.center)
                        .accessibilityAddTraits(.isHeader)
                        .accessibilityIdentifier("partner-profile-name")

                    if isLoading {
                        ProgressView("Loading photo…")
                    }
                    if let errorMessage {
                        Text(errorMessage)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .accessibilityIdentifier("partner-photo-error")
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 8)
                .frame(maxWidth: .infinity)

                VStack(spacing: 0) {
                    profileEditActions(hasPhoto: photo != nil)

                    SessionActionsMenu(
                        hasConversation: true,
                        showsInlineActions: true,
                        searchMessages: searchMessages,
                        pinnedMessages: model.messagePins == nil ? nil : {
                            showingPinnedMessages = true
                        }
                    )
                }
                .padding(.horizontal, 16)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 20))
                .padding(.horizontal, 20)
            }
            .padding(.bottom, 24)
        }
        .background {
            GiftWrapWallpaper()
                .overlay(.regularMaterial)
                .ignoresSafeArea()
        }
        .accessibilityIdentifier("partner-profile-screen")
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarRole(.editor)
        .toolbar(.visible, for: .navigationBar)
        .toolbarBackground(.hidden, for: .navigationBar)
        .sheet(isPresented: $showingPinnedMessages, onDismiss: {
            guard let target = pendingPinnedJump else { return }
            pendingPinnedJump = nil
            showMessageInConversation(target)
        }) {
            if let pins = model.messagePins {
                PinnedMessagesView(controller: pins) { id in
                    pendingPinnedJump = id
                    showingPinnedMessages = false
                }
                .environment(model)
                .environment(\.encryptedAttachmentResolver, model.encryption?.resolver)
            }
        }
        .onChange(of: model.messagePins == nil) { _, unavailable in
            if unavailable {
                showingPinnedMessages = false
                pendingPinnedJump = nil
            }
        }
        .onChange(of: model.attachmentPreparationTarget) {
            showingPinnedMessages = false
            pendingPinnedJump = nil
        }
        .alert("Edit Nickname", isPresented: $showingNicknameEditor) {
            TextField(name, text: $editedNickname)
                .textInputAutocapitalization(.words)
                .accessibilityIdentifier("partner-nickname-field")
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                do {
                    try store.saveNickname(editedNickname, accountID: accountID, partnerID: partnerID)
                    errorMessage = nil
                } catch {
                    errorMessage = "The nickname couldn’t be saved. Try again."
                }
            }
        } message: {
            Text("Only shown to you on this device. Leave blank to use \(name).")
        }
        .fullScreenCover(item: $pendingPhoto) { selection in
            PartnerPhotoCropView(image: selection.image, onCancel: {
                pendingPhoto = nil
            }, onSave: { image in
                do {
                    guard let data = image.jpegData(compressionQuality: 0.9) else {
                        throw PartnerPhotoStore.PhotoError.invalidImage
                    }
                    try store.savePhoto(data: data, accountID: accountID, partnerID: partnerID)
                    errorMessage = nil
                } catch {
                    errorMessage = "The photo couldn’t be saved. Try again."
                }
                pendingPhoto = nil
            })
            .ignoresSafeArea()
        }
        .photosPicker(isPresented: $showingPhotoPicker, selection: $selectedPhoto, matching: .images)
        .task(id: selectedPhoto) {
            guard let item = selectedPhoto else { return }
            isLoading = true
            errorMessage = nil
            defer {
                isLoading = false
                selectedPhoto = nil
            }
            do {
                guard let data = try await item.loadTransferable(type: Data.self) else {
                    throw PartnerPhotoStore.PhotoError.invalidImage
                }
                guard let image = await ImageDecoding.thumbnail(from: data, maximumPixelSize: 2048) else {
                    throw PartnerPhotoStore.PhotoError.invalidImage
                }
                try Task.checkCancellation()
                pendingPhoto = PartnerPhotoSelection(image: image)
            } catch is CancellationError {
                // Leaving the profile must not apply a pending selection.
            } catch {
                errorMessage = "The photo couldn’t be saved. Choose another photo or try again."
            }
        }
    }

    private func profileEditActions(hasPhoto: Bool) -> some View {
        VStack(spacing: 0) {
            profileAction("Edit Nickname", systemImage: "pencil", identifier: "partner-nickname-edit") {
                editedNickname = store.nickname(accountID: accountID, partnerID: partnerID) ?? ""
                showingNicknameEditor = true
            }

            profileAction(hasPhoto ? "Change Photo" : "Choose Photo", systemImage: "photo", identifier: "partner-photo-choose") {
                showingPhotoPicker = true
            }

            if hasPhoto {
                profileAction("Remove Photo", systemImage: "trash", identifier: "partner-photo-remove", role: .destructive) {
                    do {
                        try store.removePhoto(accountID: accountID, partnerID: partnerID)
                        errorMessage = nil
                    } catch {
                        errorMessage = "The photo couldn’t be removed. Try again."
                    }
                }
            }
        }
        .disabled(isLoading)
    }

    private func profileAction(
        _ title: String,
        systemImage: String,
        identifier: String,
        role: ButtonRole? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(role: role, action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                Image(systemName: systemImage).frame(width: 32)
                Text(title).multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }
            .font(.body)
            .foregroundStyle(role == .destructive ? Color.red : Color.primary)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier)
    }
}

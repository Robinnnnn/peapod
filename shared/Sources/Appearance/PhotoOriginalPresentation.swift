import Foundation

/// Per-photo results survive retry; a partial failure never reports the batch as saved.
struct PhotoOriginalBatchResult {
    private(set) var savedIDs: Set<UUID> = []
    private(set) var failedIDs: Set<UUID> = []
    var totalCount: Int { savedIDs.count + failedIDs.count }

    mutating func record(_ id: UUID, succeeded: Bool) {
        if succeeded { savedIDs.insert(id); failedIDs.remove(id) }
        else { failedIDs.insert(id); savedIDs.remove(id) }
    }
}

/// An old original may be retained in memory, but can only display for its photo.
struct PhotoOriginalSelection<Image> {
    private var photoID: UUID?
    private var loaded: Image?

    mutating func store(_ image: Image?, for id: UUID, selectedID: UUID) {
        guard id == selectedID else { return }
        photoID = id
        loaded = image
    }
    mutating func clear() { photoID = nil; loaded = nil }
    func image(for id: UUID) -> Image? { photoID == id ? loaded : nil }
}

struct PhotoOriginalLoadKey: Hashable {
    let photoID: UUID
    let attachment: AttachmentContent?
}

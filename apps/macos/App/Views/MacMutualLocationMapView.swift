import MapKit
import SwiftUI

/// Only the two designated phones' shared points are displayed. No Mac location source.
struct MacMutualLocationMapView: View {
    @Environment(MacAppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Shared phone locations").font(.headline)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding()
            TimelineView(.periodic(from: .now, by: 30)) { context in
                if let presentation = model.mutualLocationPresentation(at: context.date) {
                    Map {
                        Marker("You", coordinate: presentation.currentUserPoint.location.coordinate).tint(GiftWrapAppearance.pine)
                        Marker(model.partner.displayName, coordinate: presentation.partnerPoint.location.coordinate).tint(GiftWrapAppearance.mint)
                    }
                    .mapStyle(.standard(elevation: .flat))
                    Text(presentation.subtitle).font(.callout).foregroundStyle(.secondary).padding()
                } else {
                    ContentUnavailableView("Location unavailable", systemImage: "map", description: Text("Both people need to share their phone’s location."))
                }
            }
        }
        .frame(minWidth: 480, idealWidth: 640, minHeight: 380, idealHeight: 480)
        .onChange(of: model.mutualLocationPresentation() != nil) { _, available in
            if !available { dismiss() }
        }
    }
}

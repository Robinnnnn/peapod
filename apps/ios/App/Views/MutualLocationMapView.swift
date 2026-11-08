import MapKit
import SwiftUI

struct MutualLocationMapView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let presentation: MutualLocationPresentation
    let currentUserName: String
    let partnerName: String
    let onDismiss: () -> Void

    @State private var position: MapCameraPosition

    init(
        presentation: MutualLocationPresentation,
        currentUserName: String,
        partnerName: String,
        onDismiss: @escaping () -> Void
    ) {
        self.presentation = presentation
        self.currentUserName = currentUserName
        self.partnerName = partnerName
        self.onDismiss = onDismiss
        _position = State(
            initialValue: .region(Self.region(for: presentation))
        )
    }

    var body: some View {
        ZStack {
            Map(position: $position) {
                Marker(
                    currentUserName,
                    coordinate:
                        presentation.currentUserPoint.location.coordinate
                )
                .tint(.indigo)

                Marker(
                    partnerName,
                    coordinate:
                        presentation.partnerPoint.location.coordinate
                )
                .tint(.orange)
            }
            .mapStyle(.standard(elevation: .realistic))
            .ignoresSafeArea()
            .accessibilityLabel(
                "Map showing \(currentUserName) and \(partnerName)"
            )
            .accessibilityIdentifier("mutual-location-map")

            VStack {
                HStack {
                    Spacer()
                    closeButton
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)

                Spacer()

                distancePanel
                    .padding(.bottom, 22)
            }
        }
        .onChange(of: presentation) {
            let update = {
                position = .region(Self.region(for: presentation))
            }
            if reduceMotion {
                update()
            } else {
                withAnimation(.easeInOut(duration: 0.35), update)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("mutual-location-modal")
    }

    @ViewBuilder
    private var closeButton: some View {
        let button = Button(action: onDismiss) {
            Image(systemName: "xmark")
                .frame(width: 44, height: 44)
        }
        .frame(width: 44, height: 44)
        .contentShape(.circle)
        .font(.body.weight(.semibold))
        .buttonStyle(.plain)
        .accessibilityLabel("Close locations")
        .accessibilityIdentifier("close-mutual-location")

        if #available(iOS 26.0, *) {
            button
                .padding(2)
                .glassEffect(.regular.interactive(), in: .circle)
        } else {
            button
                .padding(2)
                .background(.ultraThinMaterial, in: .circle)
        }
    }

    @ViewBuilder
    private var distancePanel: some View {
        let content = TimelineView(.periodic(from: .now, by: 30)) { context in
            VStack(spacing: 3) {
                Text(presentation.distanceText)
                    .font(.headline)
                if let ageText = LocationAgeText.string(
                    since: presentation.olderRecordedAt,
                    now: context.date
                ) {
                    Text("Older location updated \(ageText)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Both locations updated recently")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("mutual-location-distance")

        if #available(iOS 26.0, *) {
            content.glassEffect(.regular, in: .capsule)
        } else {
            content.background(.ultraThinMaterial, in: .capsule)
        }
    }

    private static func region(
        for presentation: MutualLocationPresentation
    ) -> MKCoordinateRegion {
        let first = presentation.currentUserPoint.location.coordinate
        let second = presentation.partnerPoint.location.coordinate
        let center = CLLocationCoordinate2D(
            latitude: (first.latitude + second.latitude) / 2,
            longitude: (first.longitude + second.longitude) / 2
        )
        return MKCoordinateRegion(
            center: center,
            span: MKCoordinateSpan(
                latitudeDelta: max(
                    abs(first.latitude - second.latitude) * 1.8,
                    0.01
                ),
                longitudeDelta: max(
                    abs(first.longitude - second.longitude) * 1.8,
                    0.01
                )
            )
        )
    }
}

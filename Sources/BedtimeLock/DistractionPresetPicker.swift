import SwiftUI

struct DistractionPresetPicker: View {
    @ObservedObject var state: AppState

    private let columns = [
        GridItem(
            .adaptive(minimum: 118, maximum: 180),
            spacing: 8
        )
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Quick presets")
                        .font(.headline)
                    Text(
                        "Tap common distractions to add or remove them."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer()
            }

            ForEach(DistractionPresetCatalog.groups) { group in
                VStack(alignment: .leading, spacing: 7) {
                    HStack {
                        Text(group.title)
                            .font(.subheadline.weight(.medium))
                        Spacer()

                        Button(
                            state.isDistractionGroupEnabled(group)
                                ? "Remove all"
                                : "Add all"
                        ) {
                            state.setDistractionGroup(
                                group,
                                enabled:
                                    !state.isDistractionGroupEnabled(
                                        group
                                    )
                            )
                        }
                        .buttonStyle(.plain)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .disabled(
                            !state.status
                                .distractionSettingsEditable
                        )
                    }

                    LazyVGrid(
                        columns: columns,
                        alignment: .leading,
                        spacing: 8
                    ) {
                        ForEach(group.presets) { preset in
                            let enabled =
                                state.isDistractionPresetEnabled(
                                    preset
                                )

                            Button {
                                state.setDistractionPreset(
                                    preset,
                                    enabled: !enabled
                                )
                            } label: {
                                HStack(spacing: 6) {
                                    Image(
                                        systemName: enabled
                                            ? "checkmark.circle.fill"
                                            : "circle"
                                    )
                                    Text(preset.title)
                                        .lineLimit(1)
                                    Spacer(minLength: 0)
                                }
                                .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                            .disabled(
                                !state.status
                                    .distractionSettingsEditable
                            )
                            .contextMenu {
                                if enabled {
                                    Button(
                                        state.isDistractionPresetTemporarilyAllowed(
                                            preset
                                        )
                                        ? "Allowed until midnight"
                                        : "Allow until midnight"
                                    ) {
                                        state.allowDistractionPresetUntilEndOfToday(
                                            preset
                                        )
                                    }
                                    .disabled(
                                        state.isDistractionPresetTemporarilyAllowed(
                                            preset
                                        )
                                    )
                                }
                            }
                        }
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }
}

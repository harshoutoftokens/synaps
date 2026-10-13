import ActivityKit
import SwiftUI
import WidgetKit

@main
struct SynapsWidgetBundle: WidgetBundle {
    var body: some Widget {
        SyncLiveActivityWidget()
    }
}

/// Lock Screen banner and Dynamic Island for a running backup.
struct SyncLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: SyncActivityAttributes.self) { context in
            LockScreenView(state: context.state, nasName: context.attributes.nasName, isStale: context.isStale)
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .activityBackgroundTint(Color.black.opacity(0.85))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            let state = context.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    PhaseIcon(phase: state.phase)
                        .font(.title2)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text("\(state.done) / \(state.total)")
                        .font(.headline.monospacedDigit())
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(title(for: state.phase))
                        .font(.headline)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 6) {
                        ProgressView(value: state.fraction)
                            .tint(.green)
                        Text(context.isStale ? staleText : state.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            } compactLeading: {
                PhaseIcon(phase: state.phase)
            } compactTrailing: {
                Text(state.phase == .syncing ? state.percentText : "\(state.done)")
                    .font(.caption.monospacedDigit())
            } minimal: {
                PhaseIcon(phase: state.phase)
            }
        }
    }
}

private let staleText = "Uploading in the background. Open Synaps for the latest count."

private func title(for phase: SyncActivityAttributes.ContentState.Phase) -> String {
    switch phase {
    case .syncing: return "Backing up to NAS"
    case .finished: return "Backup complete"
    case .stopped: return "Backup paused"
    }
}

private struct PhaseIcon: View {
    let phase: SyncActivityAttributes.ContentState.Phase

    var body: some View {
        switch phase {
        case .syncing:
            Image(systemName: "arrow.up.circle.fill").foregroundStyle(.green)
        case .finished:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .stopped:
            Image(systemName: "pause.circle.fill").foregroundStyle(.orange)
        }
    }
}

/// One compact row, like Instagram's story-upload banner: icon, one line of text, progress ring.
private struct LockScreenView: View {
    let state: SyncActivityAttributes.ContentState
    let nasName: String
    let isStale: Bool
    
    var body: some View {
        HStack(spacing: 14) {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(0.14))
                .frame(width: 44, height: 44)
                .overlay(
                    Image(systemName: "photo.on.rectangle.angled")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(.white)
                )
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 6) {
                    Text(headline)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    if state.phase == .finished {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                }
                HStack(spacing: 10) {
                    ProgressBar(fraction: state.fraction, color: barColor)
                    Text("\(state.done)/\(state.total)")
                        .font(.system(size: 14, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.white)
                        .fixedSize()
                }
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.65))
                    .lineLimit(1)
            }
        }
    }
    
    private var barColor: Color {
        state.phase == .stopped ? .orange : .green
    }
    
    private var headline: String {
        switch state.phase {
        case .syncing:
            return "Backing up to \(nasName)..."
        case .finished:
            return "Your backup is complete"
        case .stopped:
            return "Backup paused"
        }
    }
    
    private var subtitle: String {
        if isStale && state.phase == .syncing {
            return "Uploading in the background"
        }
        switch state.phase {
        case .syncing: return state.detail
        case .finished: return "\(state.done.formatted()) items on \(nasName)"
        case .stopped:
            // The title already says "Backup paused"; keep only the reason
            return state.detail.hasPrefix("Paused: ") ? String(state.detail.dropFirst(8)).capitalizedFirstLetter : state.detail
        }
    }
}

/// A thick rounded bar filled to the share of items handled.
private struct ProgressBar: View {
    let fraction: Double
    let color: Color
    
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.18))
                Capsule()
                    .fill(color)
                    .frame(width: max(8, geo.size.width * fraction))
            }
        }
        .frame(height: 8)
    }
}

private extension String {
    var capitalizedFirstLetter: String { prefix(1).uppercased() + dropFirst() }
}

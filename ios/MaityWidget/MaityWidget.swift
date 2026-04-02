import WidgetKit
import SwiftUI

// MARK: - Timeline Provider
struct MaityProvider: TimelineProvider {
    func placeholder(in context: Context) -> MaityEntry {
        MaityEntry(date: Date(), isRecording: false, isPaused: false, segmentCount: 0)
    }

    func getSnapshot(in context: Context, completion: @escaping (MaityEntry) -> Void) {
        let entry = MaityEntry(date: Date(), isRecording: false, isPaused: false, segmentCount: 0)
        completion(entry)
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<MaityEntry>) -> Void) {
        // Read shared state from UserDefaults (App Group)
        let sharedDefaults = UserDefaults(suiteName: "group.com.maity.app")
        let isRecording = sharedDefaults?.bool(forKey: "isRecording") ?? false
        let isPaused = sharedDefaults?.bool(forKey: "isPaused") ?? false
        let segmentCount = sharedDefaults?.integer(forKey: "segmentCount") ?? 0

        let entry = MaityEntry(
            date: Date(),
            isRecording: isRecording,
            isPaused: isPaused,
            segmentCount: segmentCount
        )

        // Refresh every 15 minutes when idle, every minute when recording
        let refreshInterval: TimeInterval = isRecording ? 60 : 900
        let nextUpdate = Date().addingTimeInterval(refreshInterval)
        let timeline = Timeline(entries: [entry], policy: .after(nextUpdate))
        completion(timeline)
    }
}

// MARK: - Timeline Entry
struct MaityEntry: TimelineEntry {
    let date: Date
    let isRecording: Bool
    let isPaused: Bool
    let segmentCount: Int
}

// MARK: - Widget Views
struct MaityWidgetEntryView: View {
    var entry: MaityProvider.Entry
    @Environment(\.widgetFamily) var family

    var body: some View {
        switch family {
        case .systemSmall:
            smallWidget
        case .systemMedium:
            mediumWidget
        default:
            smallWidget
        }
    }

    // Small widget: Quick record button
    var smallWidget: some View {
        ZStack {
            if entry.isRecording || entry.isPaused {
                // Recording state
                ContainerRelativeShape()
                    .fill(
                        entry.isPaused
                            ? Color(red: 0.17, green: 0.09, blue: 0.0)
                            : Color(red: 0.1, green: 0.04, blue: 0.04)
                    )

                VStack(spacing: 8) {
                    // Status indicator
                    HStack(spacing: 6) {
                        Circle()
                            .fill(entry.isPaused ? Color.orange : Color.red)
                            .frame(width: 8, height: 8)
                        Text(entry.isPaused ? "Pausado" : "Grabando")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(entry.isPaused ? .orange : .red)
                    }

                    // Mic icon
                    Image(systemName: entry.isPaused ? "pause.circle.fill" : "mic.fill")
                        .font(.system(size: 32))
                        .foregroundColor(entry.isPaused ? .orange : .red)

                    if entry.segmentCount > 0 {
                        Text("\(entry.segmentCount) segmentos")
                            .font(.system(size: 10))
                            .foregroundColor(.gray)
                    }
                }
            } else {
                // Idle state - Quick record
                ContainerRelativeShape()
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(red: 0.28, green: 0.36, blue: 0.96),
                                Color(red: 0.42, green: 0.48, blue: 0.97)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )

                VStack(spacing: 8) {
                    Image(systemName: "mic.fill")
                        .font(.system(size: 32))
                        .foregroundColor(.white)

                    Text("Grabar")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.white)

                    Text("Toca para iniciar")
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.7))
                }
            }
        }
        .widgetURL(URL(string: entry.isRecording ? "maity://recording" : "maity://record"))
    }

    // Medium widget: Record + status
    var mediumWidget: some View {
        ZStack {
            if entry.isRecording || entry.isPaused {
                ContainerRelativeShape()
                    .fill(Color(red: 0.07, green: 0.07, blue: 0.09))

                HStack(spacing: 16) {
                    // Left: Status
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(entry.isPaused ? Color.orange : Color.red)
                                .frame(width: 8, height: 8)
                            Text(entry.isPaused ? "En pausa" : "Grabando...")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(entry.isPaused ? .orange : .red)
                        }

                        Text("Maity")
                            .font(.system(size: 20, weight: .bold))
                            .foregroundColor(.white)

                        if entry.segmentCount > 0 {
                            Text("\(entry.segmentCount) segmentos capturados")
                                .font(.system(size: 11))
                                .foregroundColor(.gray)
                        }
                    }

                    Spacer()

                    // Right: Icon
                    Image(systemName: entry.isPaused ? "pause.circle.fill" : "waveform")
                        .font(.system(size: 40))
                        .foregroundColor(entry.isPaused ? .orange : .red)
                }
                .padding(.horizontal, 20)
            } else {
                ContainerRelativeShape()
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(red: 0.28, green: 0.36, blue: 0.96),
                                Color(red: 0.42, green: 0.48, blue: 0.97)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )

                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Maity")
                            .font(.system(size: 20, weight: .bold))
                            .foregroundColor(.white)

                        Text("Transcripcion rapida")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(.white.opacity(0.9))

                        Text("Toca para comenzar a grabar")
                            .font(.system(size: 11))
                            .foregroundColor(.white.opacity(0.7))
                    }

                    Spacer()

                    Image(systemName: "mic.circle.fill")
                        .font(.system(size: 44))
                        .foregroundColor(.white)
                }
                .padding(.horizontal, 20)
            }
        }
        .widgetURL(URL(string: entry.isRecording ? "maity://recording" : "maity://record"))
    }
}

// MARK: - Widget Definition
struct MaityWidget: Widget {
    let kind: String = "MaityWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: MaityProvider()) { entry in
            if #available(iOS 17.0, *) {
                MaityWidgetEntryView(entry: entry)
                    .containerBackground(.fill.tertiary, for: .widget)
            } else {
                MaityWidgetEntryView(entry: entry)
                    .padding()
                    .background()
            }
        }
        .configurationDisplayName("Maity")
        .description("Inicia una transcripcion rapida o ve el estado de tu grabacion.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

// MARK: - Widget Bundle
@main
struct MaityWidgetBundle: WidgetBundle {
    var body: some Widget {
        MaityWidget()
    }
}

// MARK: - Preview
#if DEBUG
struct MaityWidget_Previews: PreviewProvider {
    static var previews: some View {
        Group {
            MaityWidgetEntryView(entry: MaityEntry(date: Date(), isRecording: false, isPaused: false, segmentCount: 0))
                .previewContext(WidgetPreviewContext(family: .systemSmall))
                .previewDisplayName("Small - Idle")

            MaityWidgetEntryView(entry: MaityEntry(date: Date(), isRecording: true, isPaused: false, segmentCount: 5))
                .previewContext(WidgetPreviewContext(family: .systemSmall))
                .previewDisplayName("Small - Recording")

            MaityWidgetEntryView(entry: MaityEntry(date: Date(), isRecording: false, isPaused: false, segmentCount: 0))
                .previewContext(WidgetPreviewContext(family: .systemMedium))
                .previewDisplayName("Medium - Idle")

            MaityWidgetEntryView(entry: MaityEntry(date: Date(), isRecording: true, isPaused: true, segmentCount: 12))
                .previewContext(WidgetPreviewContext(family: .systemMedium))
                .previewDisplayName("Medium - Paused")
        }
    }
}
#endif

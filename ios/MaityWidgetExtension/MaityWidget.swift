import WidgetKit
import SwiftUI

// MARK: - Shared Data
struct MaityProvider: TimelineProvider {
    func placeholder(in context: Context) -> MaityEntry {
        MaityEntry(date: Date(), isRecording: false, isPaused: false, segmentCount: 0)
    }

    func getSnapshot(in context: Context, completion: @escaping (MaityEntry) -> Void) {
        completion(MaityEntry(date: Date(), isRecording: false, isPaused: false, segmentCount: 0))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<MaityEntry>) -> Void) {
        let sharedDefaults = UserDefaults(suiteName: "group.com.maity.app")
        let entry = MaityEntry(
            date: Date(),
            isRecording: sharedDefaults?.bool(forKey: "isRecording") ?? false,
            isPaused: sharedDefaults?.bool(forKey: "isPaused") ?? false,
            segmentCount: sharedDefaults?.integer(forKey: "segmentCount") ?? 0
        )
        let refreshInterval: TimeInterval = entry.isRecording ? 60 : 900
        let timeline = Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(refreshInterval)))
        completion(timeline)
    }
}

struct MaityEntry: TimelineEntry {
    let date: Date
    let isRecording: Bool
    let isPaused: Bool
    let segmentCount: Int
}

// ============================================================
// MARK: - Widget 1: Quick Record (Small)
// ============================================================
struct MaityQuickRecordView: View {
    var entry: MaityEntry

    var body: some View {
        ZStack {
            if entry.isRecording || entry.isPaused {
                ContainerRelativeShape()
                    .fill(entry.isPaused
                        ? Color(red: 0.17, green: 0.09, blue: 0.0)
                        : Color(red: 0.1, green: 0.04, blue: 0.04))

                VStack(spacing: 8) {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(entry.isPaused ? Color.orange : Color.red)
                            .frame(width: 8, height: 8)
                        Text(entry.isPaused ? "Pausado" : "Grabando")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(entry.isPaused ? .orange : .red)
                    }
                    Image(systemName: entry.isPaused ? "pause.circle.fill" : "mic.fill")
                        .font(.system(size: 32))
                        .foregroundColor(entry.isPaused ? .orange : .red)
                    if entry.segmentCount > 0 {
                        Text("\(entry.segmentCount) seg.")
                            .font(.system(size: 10))
                            .foregroundColor(.gray)
                    }
                }
            } else {
                ContainerRelativeShape()
                    .fill(LinearGradient(
                        colors: [Color(red: 0.28, green: 0.36, blue: 0.96), Color(red: 0.42, green: 0.48, blue: 0.97)],
                        startPoint: .topLeading, endPoint: .bottomTrailing))
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
}

struct MaityQuickRecordWidget: Widget {
    let kind = "MaityQuickRecord"
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: MaityProvider()) { entry in
            if #available(iOS 17.0, *) {
                MaityQuickRecordView(entry: entry)
                    .containerBackground(.fill.tertiary, for: .widget)
            } else {
                MaityQuickRecordView(entry: entry).padding().background()
            }
        }
        .configurationDisplayName("Maity - Grabar")
        .description("Toca para iniciar una transcripcion rapida.")
        .supportedFamilies([.systemSmall])
    }
}

// ============================================================
// MARK: - Widget 2: Status (Medium)
// ============================================================
struct MaityStatusView: View {
    var entry: MaityEntry

    var body: some View {
        ZStack {
            if entry.isRecording || entry.isPaused {
                ContainerRelativeShape()
                    .fill(Color(red: 0.07, green: 0.07, blue: 0.09))
                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(entry.isPaused ? Color.orange : Color.red)
                                .frame(width: 8, height: 8)
                            Text(entry.isPaused ? "En pausa" : "Grabando...")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(entry.isPaused ? .orange : .red)
                        }
                        Text("Maity").font(.system(size: 20, weight: .bold)).foregroundColor(.white)
                        if entry.segmentCount > 0 {
                            Text("\(entry.segmentCount) segmentos capturados")
                                .font(.system(size: 11)).foregroundColor(.gray)
                        }
                    }
                    Spacer()
                    Image(systemName: entry.isPaused ? "pause.circle.fill" : "waveform")
                        .font(.system(size: 40))
                        .foregroundColor(entry.isPaused ? .orange : .red)
                }
                .padding(.horizontal, 20)
            } else {
                ContainerRelativeShape()
                    .fill(LinearGradient(
                        colors: [Color(red: 0.28, green: 0.36, blue: 0.96), Color(red: 0.42, green: 0.48, blue: 0.97)],
                        startPoint: .topLeading, endPoint: .bottomTrailing))
                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Maity").font(.system(size: 20, weight: .bold)).foregroundColor(.white)
                        Text("Transcripcion rapida").font(.system(size: 14, weight: .medium)).foregroundColor(.white.opacity(0.9))
                        Text("Toca para comenzar a grabar").font(.system(size: 11)).foregroundColor(.white.opacity(0.7))
                    }
                    Spacer()
                    Image(systemName: "mic.circle.fill").font(.system(size: 44)).foregroundColor(.white)
                }
                .padding(.horizontal, 20)
            }
        }
        .widgetURL(URL(string: entry.isRecording ? "maity://recording" : "maity://record"))
    }
}

struct MaityStatusWidget: Widget {
    let kind = "MaityStatus"
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: MaityProvider()) { entry in
            if #available(iOS 17.0, *) {
                MaityStatusView(entry: entry).containerBackground(.fill.tertiary, for: .widget)
            } else {
                MaityStatusView(entry: entry).padding().background()
            }
        }
        .configurationDisplayName("Maity - Estado")
        .description("Ve el estado de tu grabacion actual.")
        .supportedFamilies([.systemMedium])
    }
}

// ============================================================
// MARK: - Widget 3: Controls (Medium) - With action buttons
// ============================================================
struct MaityControlsView: View {
    var entry: MaityEntry

    var body: some View {
        ZStack {
            ContainerRelativeShape()
                .fill(Color(red: 0.08, green: 0.08, blue: 0.10))

            if entry.isRecording || entry.isPaused {
                // Recording active: show controls
                VStack(spacing: 12) {
                    // Status bar
                    HStack(spacing: 6) {
                        Circle()
                            .fill(entry.isPaused ? Color.orange : Color.red)
                            .frame(width: 8, height: 8)
                        Text(entry.isPaused ? "En pausa" : "Grabando...")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(entry.isPaused ? .orange : .red)
                        Spacer()
                        if entry.segmentCount > 0 {
                            Text("\(entry.segmentCount) seg.")
                                .font(.system(size: 11))
                                .foregroundColor(.gray)
                        }
                    }
                    .padding(.horizontal, 4)

                    // Control buttons
                    HStack(spacing: 12) {
                        // Cancel
                        Link(destination: URL(string: "maity://cancel")!) {
                            VStack(spacing: 4) {
                                ZStack {
                                    Circle().fill(Color(white: 0.2)).frame(width: 44, height: 44)
                                    Image(systemName: "xmark")
                                        .font(.system(size: 16, weight: .semibold))
                                        .foregroundColor(.white.opacity(0.7))
                                }
                                Text("Cancelar").font(.system(size: 9)).foregroundColor(.white.opacity(0.6))
                            }
                        }

                        // Pause / Resume
                        Link(destination: URL(string: entry.isPaused ? "maity://resume" : "maity://pause")!) {
                            VStack(spacing: 4) {
                                ZStack {
                                    Circle()
                                        .fill(entry.isPaused ? Color(red: 0.28, green: 0.36, blue: 0.96) : Color.orange)
                                        .frame(width: 44, height: 44)
                                    Image(systemName: entry.isPaused ? "play.fill" : "pause.fill")
                                        .font(.system(size: 16, weight: .semibold))
                                        .foregroundColor(.white)
                                }
                                Text(entry.isPaused ? "Reanudar" : "Pausar")
                                    .font(.system(size: 9)).foregroundColor(.white.opacity(0.6))
                            }
                        }

                        // Stop
                        Link(destination: URL(string: "maity://stop")!) {
                            VStack(spacing: 4) {
                                ZStack {
                                    Circle().fill(Color.red).frame(width: 44, height: 44)
                                    Image(systemName: "stop.fill")
                                        .font(.system(size: 16, weight: .semibold))
                                        .foregroundColor(.white)
                                }
                                Text("Detener").font(.system(size: 9)).foregroundColor(.white.opacity(0.6))
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            } else {
                // Idle: show record button
                Link(destination: URL(string: "maity://record")!) {
                    HStack(spacing: 16) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Maity").font(.system(size: 18, weight: .bold)).foregroundColor(.white)
                            Text("Controles de grabacion").font(.system(size: 12)).foregroundColor(.white.opacity(0.7))
                        }
                        Spacer()
                        ZStack {
                            Circle()
                                .fill(LinearGradient(
                                    colors: [Color(red: 0.28, green: 0.36, blue: 0.96), Color(red: 0.42, green: 0.48, blue: 0.97)],
                                    startPoint: .top, endPoint: .bottom))
                                .frame(width: 52, height: 52)
                            Image(systemName: "mic.fill")
                                .font(.system(size: 22))
                                .foregroundColor(.white)
                        }
                    }
                    .padding(.horizontal, 20)
                }
            }
        }
    }
}

struct MaityControlsWidget: Widget {
    let kind = "MaityControls"
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: MaityProvider()) { entry in
            if #available(iOS 17.0, *) {
                MaityControlsView(entry: entry).containerBackground(.fill.tertiary, for: .widget)
            } else {
                MaityControlsView(entry: entry).padding().background()
            }
        }
        .configurationDisplayName("Maity - Controles")
        .description("Controla tu grabacion directamente desde el widget.")
        .supportedFamilies([.systemMedium])
    }
}

// ============================================================
// MARK: - Widget Bundle
// ============================================================
@main
struct MaityWidgetBundle: WidgetBundle {
    var body: some Widget {
        MaityQuickRecordWidget()
        MaityStatusWidget()
        MaityControlsWidget()
    }
}

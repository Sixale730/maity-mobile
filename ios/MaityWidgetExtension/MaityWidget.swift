import WidgetKit
import SwiftUI

// MARK: - Localization Helper
struct WidgetStrings {
    let language: String

    var recording: String { language == "en" ? "Recording..." : "Grabando..." }
    var paused: String { language == "en" ? "Paused" : "Pausado" }
    var record: String { language == "en" ? "Record" : "Grabar" }
    var tapToStart: String { language == "en" ? "Tap to start" : "Toca para iniciar" }
    var quickTranscription: String { language == "en" ? "Quick transcription" : "Transcripcion rapida" }
    var tapToRecord: String { language == "en" ? "Tap to start recording" : "Toca para comenzar a grabar" }
    var tapToOpen: String { language == "en" ? "Tap to open" : "Toca para abrir" }
    var cancel: String { language == "en" ? "Cancel" : "Cancelar" }
    var pause: String { language == "en" ? "Pause" : "Pausar" }
    var resume: String { language == "en" ? "Resume" : "Reanudar" }
    var stop: String { language == "en" ? "Stop" : "Detener" }
    var recordingControls: String { language == "en" ? "Recording controls" : "Controles de grabacion" }
    func segmentsCaptured(_ count: Int) -> String {
        language == "en" ? "\(count) segments captured" : "\(count) segmentos capturados"
    }
}

// MARK: - Timeline Provider
struct MaityProvider: TimelineProvider {
    func placeholder(in context: Context) -> MaityEntry {
        MaityEntry(date: Date(), isRecording: false, isPaused: false, segmentCount: 0, language: "es")
    }

    func getSnapshot(in context: Context, completion: @escaping (MaityEntry) -> Void) {
        completion(placeholder(in: context))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<MaityEntry>) -> Void) {
        let sharedDefaults = UserDefaults(suiteName: "group.com.maity.app")
        let entry = MaityEntry(
            date: Date(),
            isRecording: sharedDefaults?.bool(forKey: "isRecording") ?? false,
            isPaused: sharedDefaults?.bool(forKey: "isPaused") ?? false,
            segmentCount: sharedDefaults?.integer(forKey: "segmentCount") ?? 0,
            language: sharedDefaults?.string(forKey: "language") ?? "es"
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
    let language: String

    var strings: WidgetStrings { WidgetStrings(language: language) }
    var isActive: Bool { isRecording || isPaused }
}

// MARK: - Widget 1: Quick Record (Small)
struct MaityQuickRecordView: View {
    var entry: MaityEntry

    var body: some View {
        ZStack {
            if entry.isActive {
                ContainerRelativeShape()
                    .fill(entry.isPaused
                        ? Color(red: 0.17, green: 0.09, blue: 0.0)
                        : Color(red: 0.1, green: 0.04, blue: 0.04))
                VStack(spacing: 8) {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(entry.isPaused ? Color.orange : Color.red)
                            .frame(width: 8, height: 8)
                        Text(entry.isPaused ? entry.strings.paused : entry.strings.recording)
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
                    Text(entry.strings.record)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.white)
                    Text(entry.strings.tapToStart)
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.7))
                }
            }
        }
        .widgetURL(URL(string: entry.isActive ? "maity://widget/recording" : "maity://widget/record"))
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
        .configurationDisplayName("Maity - Record")
        .description("Tap to start a quick transcription.")
        .supportedFamilies([.systemSmall])
    }
}

// MARK: - Widget 2: Status (Medium)
struct MaityStatusView: View {
    var entry: MaityEntry

    var body: some View {
        ZStack {
            if entry.isActive {
                ContainerRelativeShape()
                    .fill(Color(red: 0.07, green: 0.07, blue: 0.09))
                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(entry.isPaused ? Color.orange : Color.red)
                                .frame(width: 8, height: 8)
                            Text(entry.isPaused ? entry.strings.paused : entry.strings.recording)
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(entry.isPaused ? .orange : .red)
                        }
                        Text("Maity")
                            .font(.system(size: 20, weight: .bold))
                            .foregroundColor(.white)
                        if entry.segmentCount > 0 {
                            Text(entry.strings.segmentsCaptured(entry.segmentCount))
                                .font(.system(size: 11))
                                .foregroundColor(.gray)
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
                        Text("Maity")
                            .font(.system(size: 20, weight: .bold))
                            .foregroundColor(.white)
                        Text(entry.strings.quickTranscription)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(.white.opacity(0.9))
                        Text(entry.strings.tapToRecord)
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
        .widgetURL(URL(string: entry.isActive ? "maity://widget/recording" : "maity://widget/record"))
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
        .configurationDisplayName("Maity - Status")
        .description("See your current recording status.")
        .supportedFamilies([.systemMedium])
    }
}

// MARK: - Widget 3: Controls (Medium) - With pause/stop/cancel buttons
struct MaityControlsView: View {
    var entry: MaityEntry

    var body: some View {
        ZStack {
            ContainerRelativeShape()
                .fill(Color(red: 0.08, green: 0.08, blue: 0.10))

            if entry.isActive {
                VStack(spacing: 12) {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(entry.isPaused ? Color.orange : Color.red)
                            .frame(width: 8, height: 8)
                        Text(entry.isPaused ? entry.strings.paused : entry.strings.recording)
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

                    HStack(spacing: 12) {
                        Link(destination: URL(string: "maity://widget/cancel")!) {
                            VStack(spacing: 4) {
                                ZStack {
                                    Circle().fill(Color(white: 0.2)).frame(width: 44, height: 44)
                                    Image(systemName: "xmark")
                                        .font(.system(size: 16, weight: .semibold))
                                        .foregroundColor(.white.opacity(0.7))
                                }
                                Text(entry.strings.cancel).font(.system(size: 9)).foregroundColor(.white.opacity(0.6))
                            }
                        }

                        Link(destination: URL(string: entry.isPaused ? "maity://widget/resume" : "maity://widget/pause")!) {
                            VStack(spacing: 4) {
                                ZStack {
                                    Circle()
                                        .fill(entry.isPaused ? Color(red: 0.28, green: 0.36, blue: 0.96) : Color.orange)
                                        .frame(width: 44, height: 44)
                                    Image(systemName: entry.isPaused ? "play.fill" : "pause.fill")
                                        .font(.system(size: 16, weight: .semibold))
                                        .foregroundColor(.white)
                                }
                                Text(entry.isPaused ? entry.strings.resume : entry.strings.pause)
                                    .font(.system(size: 9)).foregroundColor(.white.opacity(0.6))
                            }
                        }

                        Link(destination: URL(string: "maity://widget/stop")!) {
                            VStack(spacing: 4) {
                                ZStack {
                                    Circle().fill(Color.red).frame(width: 44, height: 44)
                                    Image(systemName: "stop.fill")
                                        .font(.system(size: 16, weight: .semibold))
                                        .foregroundColor(.white)
                                }
                                Text(entry.strings.stop).font(.system(size: 9)).foregroundColor(.white.opacity(0.6))
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            } else {
                Link(destination: URL(string: "maity://widget/record")!) {
                    HStack(spacing: 16) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Maity").font(.system(size: 18, weight: .bold)).foregroundColor(.white)
                            Text(entry.strings.recordingControls).font(.system(size: 12)).foregroundColor(.white.opacity(0.7))
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
        .configurationDisplayName("Maity - Controls")
        .description("Control your recording directly from the widget.")
        .supportedFamilies([.systemMedium])
    }
}

// MARK: - Widget Bundle
@main
struct MaityWidgetBundle: WidgetBundle {
    var body: some Widget {
        MaityQuickRecordWidget()
        MaityStatusWidget()
        MaityControlsWidget()
    }
}

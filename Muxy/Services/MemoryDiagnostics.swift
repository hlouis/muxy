import AppKit
import Darwin
import Foundation
import os

private let logger = Logger(subsystem: "app.muxy", category: "MemoryDiagnostics")

@MainActor
final class MemoryDiagnostics: NSObject {
    static let shared = MemoryDiagnostics()

    nonisolated private static let periodicLoggingDefaultsKey = "MuxyDiagnosticsPeriodicLogging"
    nonisolated private static let maxLogBytes: Int = 512 * 1024
    nonisolated private static let maxSnapshotFiles = 3
    nonisolated private static let samplingInterval: TimeInterval = 60

    nonisolated private static let crumbInterval: TimeInterval = 60

    nonisolated private let writeQueue = DispatchQueue(label: "app.muxy.diagnostics", qos: .utility)
    private var samplingTimer: DispatchSourceTimer?
    private var crumbTimer: DispatchSourceTimer?
    nonisolated private let disabledForSessionLock = OSAllocatedUnfairLock<Bool>(initialState: false)
    nonisolated private var disabledForSession: Bool {
        get { disabledForSessionLock.withLock { $0 } }
        set { disabledForSessionLock.withLock { $0 = newValue } }
    }

    private weak var appState: AppState?
    nonisolated(unsafe) private let isoFormatter = ISO8601DateFormatter()
    nonisolated(unsafe) private let snapshotStampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate, .withTime]
        return formatter
    }()

    func configure(appState: AppState) {
        self.appState = appState
        recoverPreviousSessionIfNeeded()
        startCrumbTimer()
        observeAppLifecycle()
        if UserDefaults.standard.bool(forKey: Self.periodicLoggingDefaultsKey) {
            startPeriodicLogging()
        }
    }

    func markCleanShutdown() {
        guard let url = crumbURL() else { return }
        try? FileManager.default.removeItem(at: url)
    }

    private func observeAppLifecycle() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleWillTerminate),
            name: NSApplication.willTerminateNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleDidResignActive),
            name: NSApplication.didResignActiveNotification,
            object: nil
        )
    }

    @objc
    private func handleWillTerminate() {
        markCleanShutdown()
    }

    @objc
    private func handleDidResignActive() {
        writeCrumbNow()
    }

    private func startCrumbTimer() {
        guard crumbTimer == nil else { return }
        crumbTimer = Self.makeBackgroundTimer(on: writeQueue, interval: Self.crumbInterval) { [weak self] in
            self?.writeCrumbNow()
        }
    }

    nonisolated private func writeCrumbNow() {
        guard !disabledForSession else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            let inputs = self.collectMainActorInputs()
            self.writeQueue.async { [weak self] in
                self?.finishWriteCrumb(with: inputs)
            }
        }
    }

    nonisolated private func finishWriteCrumb(with inputs: MainActorInputs) {
        guard !disabledForSession else { return }
        let line = buildPeriodicLine(with: inputs)
        let pid = getpid()
        let payload = "pid=\(pid) launchedAt=\(isoFormatter.string(from: MuxyApp.launchDate))\n\(line)\n"
        guard let url = crumbURL() else { return }
        do {
            try payload.data(using: .utf8)?.write(to: url, options: .atomic)
        } catch {
            logger.error("Crumb write failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func recoverPreviousSessionIfNeeded() {
        guard let url = crumbURL(),
              let data = try? Data(contentsOf: url),
              let contents = String(data: data, encoding: .utf8)
        else { return }
        let header = "=== PREVIOUS SESSION ENDED UNCLEANLY (recovered \(isoFormatter.string(from: Date()))) ===\n"
        let footer = "=== END PREVIOUS SESSION ===\n"
        let block = header + contents + (contents.hasSuffix("\n") ? "" : "\n") + footer
        writeQueue.async { [weak self] in
            self?.appendRaw(block)
        }
        try? FileManager.default.removeItem(at: url)
    }

    nonisolated private func appendRaw(_ text: String) {
        guard !disabledForSession, let url = logFileURL() else { return }
        do {
            try rotateIfNeeded(at: url)
            let data = text.data(using: .utf8) ?? Data()
            if FileManager.default.fileExists(atPath: url.path) {
                let handle = try FileHandle(forWritingTo: url)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
            } else {
                try data.write(to: url, options: .atomic)
            }
        } catch {
            logger.error("Recovery append failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    nonisolated private func crumbURL() -> URL? {
        ensureLogDirectory()?.appendingPathComponent("last-session.txt")
    }

    var isPeriodicLoggingEnabled: Bool {
        UserDefaults.standard.bool(forKey: Self.periodicLoggingDefaultsKey)
    }

    func setPeriodicLoggingEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: Self.periodicLoggingDefaultsKey)
        if enabled {
            disabledForSession = false
            startPeriodicLogging()
        } else {
            stopPeriodicLogging()
        }
    }

    func exportSnapshot() -> URL? {
        guard let dir = ensureLogDirectory() else { return nil }
        let inputs = collectMainActorInputs()
        let report = buildReport(with: inputs, periodic: false)
        let stamp = snapshotStampFormatter.string(from: Date())
        let url = dir.appendingPathComponent("diagnostics-snapshot-\(stamp).txt")
        do {
            try report.write(to: url, atomically: true, encoding: .utf8)
            pruneOldSnapshots(in: dir)
            return url
        } catch {
            logger.error("Failed to write snapshot: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private func startPeriodicLogging() {
        guard samplingTimer == nil, !disabledForSession else { return }
        samplingTimer = Self.makeBackgroundTimer(on: writeQueue, interval: Self.samplingInterval) { [weak self] in
            self?.captureAndAppendPeriodicLine()
        }
    }

    private func stopPeriodicLogging() {
        samplingTimer?.cancel()
        samplingTimer = nil
    }

    nonisolated private func captureAndAppendPeriodicLine() {
        guard !disabledForSession else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            let inputs = self.collectMainActorInputs()
            self.writeQueue.async { [weak self] in
                guard let self, !self.disabledForSession else { return }
                let line = self.buildPeriodicLine(with: inputs)
                self.appendLine(line)
            }
        }
    }

    nonisolated private func appendLine(_ line: String) {
        guard !disabledForSession else { return }
        guard let url = logFileURL() else { return }
        do {
            try rotateIfNeeded(at: url)
            let data = (line + "\n").data(using: .utf8) ?? Data()
            if FileManager.default.fileExists(atPath: url.path) {
                let handle = try FileHandle(forWritingTo: url)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
            } else {
                try data.write(to: url, options: .atomic)
            }
        } catch {
            logger.error("Diagnostics write failed; disabling for session: \(error.localizedDescription, privacy: .public)")
            disabledForSession = true
            DispatchQueue.main.async { [weak self] in
                self?.stopPeriodicLogging()
            }
        }
    }

    nonisolated private func rotateIfNeeded(at url: URL) throws {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attrs?[.size] as? NSNumber)?.intValue ?? 0
        guard size >= Self.maxLogBytes else { return }
        let rotated = url.deletingLastPathComponent().appendingPathComponent(url.lastPathComponent + ".1")
        if FileManager.default.fileExists(atPath: rotated.path) {
            try FileManager.default.removeItem(at: rotated)
        }
        try FileManager.default.moveItem(at: url, to: rotated)
    }

    private func pruneOldSnapshots(in dir: URL) {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let snapshots = files
            .filter { $0.lastPathComponent.hasPrefix("diagnostics-snapshot-") }
            .sorted {
                let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return a > b
            }
        guard snapshots.count > Self.maxSnapshotFiles else { return }
        for file in snapshots.dropFirst(Self.maxSnapshotFiles) {
            try? FileManager.default.removeItem(at: file)
        }
    }

    nonisolated private func buildPeriodicLine(with inputs: MainActorInputs) -> String {
        let metrics = collectMetrics(with: inputs)
        let timestamp = isoFormatter.string(from: Date())
        var parts: [String] = [timestamp]
        parts.append("footprint=\(metrics.footprintMB)MB")
        parts.append("peak=\(metrics.peakMB)MB")
        parts.append("threads=\(metrics.threadCount)")
        parts.append("fds=\(metrics.fdCount)")
        parts.append("windows=\(metrics.windowCount)")
        parts.append("projects=\(metrics.projectCount)")
        parts.append("tabs=\(metrics.tabCount)")
        parts.append("panes=\(metrics.paneCount)")
        parts.append("surfaces=\(metrics.surfaceCount)")
        parts.append("views=\(metrics.viewCount)")
        parts.append("leak=\(metrics.leak)")
        return parts.joined(separator: " ")
    }

    nonisolated private func buildReport(with inputs: MainActorInputs, periodic: Bool) -> String {
        let metrics = collectMetrics(with: inputs)
        var out = ""
        out += "Muxy Diagnostics Snapshot\n"
        out += "Generated: \(isoFormatter.string(from: Date()))\n"
        out += "App Version: \(Self.appVersion())\n"
        out += "macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)\n"
        out += "Uptime: \(Int(Date().timeIntervalSince(MuxyApp.launchDate)))s\n"
        out += "\n"
        out += "Process\n"
        out += "  Footprint: \(metrics.footprintMB) MB\n"
        out += "  Peak: \(metrics.peakMB) MB\n"
        out += "  Threads: \(metrics.threadCount)\n"
        out += "  File Descriptors: \(metrics.fdCount)\n"
        out += "  Windows: \(metrics.windowCount)\n"
        out += "\n"
        out += "Workspace\n"
        out += "  Projects: \(metrics.projectCount)\n"
        out += "  Tabs: \(metrics.tabCount)\n"
        out += "  Expected Panes: \(metrics.paneCount)\n"
        out += "  Live Surfaces: \(metrics.surfaceCount)\n"
        out += "  Live NSViews: \(metrics.viewCount)\n"
        out += "  Leak Indicator: \(metrics.leak)\n"
        out += "\n"
        out += "Per-Project (anonymized)\n"
        for entry in metrics.perProject {
            out += "  project[\(entry.index)]: tabs=\(entry.tabCount) panes=\(entry.paneCount)\n"
        }
        out += "\n"
        out += "Threads (by name)\n"
        for (name, count) in metrics.threadHistogram.sorted(by: { $0.value > $1.value }) {
            out += "  \(name)=\(count)\n"
        }
        if periodic {
            out += "\n(periodic)\n"
        }
        return out
    }

    @MainActor
    private func collectMainActorInputs() -> MainActorInputs {
        let windows = NSApp?.windows.count ?? 0
        let surfaceCount = TerminalViewRegistry.shared.liveSurfaceCount
        let viewCount = TerminalViewRegistry.shared.liveViewCount

        var projectCount = 0
        var tabCount = 0
        var paneCount = 0
        var perProject: [PerProject] = []

        if let appState {
            let groupedByProject = Dictionary(grouping: appState.workspaceRoots) { $0.key.projectID }
            projectCount = groupedByProject.count
            for (index, (_, entries)) in groupedByProject.enumerated() {
                var pTabs = 0
                var pPanes = 0
                for (_, root) in entries {
                    for area in root.allAreas() {
                        pTabs += area.tabs.count
                        for tab in area.tabs where tab.content.pane != nil {
                            pPanes += 1
                        }
                    }
                }
                tabCount += pTabs
                paneCount += pPanes
                perProject.append(PerProject(index: index, tabCount: pTabs, paneCount: pPanes))
            }
        }

        return MainActorInputs(
            windowCount: windows,
            surfaceCount: surfaceCount,
            viewCount: viewCount,
            projectCount: projectCount,
            tabCount: tabCount,
            paneCount: paneCount,
            perProject: perProject
        )
    }

    nonisolated private func collectMetrics(with inputs: MainActorInputs) -> Metrics {
        let footprint = Self.physFootprintBytes()
        let peak = Self.peakFootprintBytes()
        let threads = Self.threadInfo()
        let fds = Self.fdCount()
        let leak = max(inputs.viewCount - inputs.paneCount, inputs.surfaceCount - inputs.paneCount)

        return Metrics(
            footprintMB: footprint / 1_048_576,
            peakMB: peak / 1_048_576,
            threadCount: threads.count,
            threadHistogram: threads.histogram,
            fdCount: fds,
            windowCount: inputs.windowCount,
            projectCount: inputs.projectCount,
            tabCount: inputs.tabCount,
            paneCount: inputs.paneCount,
            surfaceCount: inputs.surfaceCount,
            viewCount: inputs.viewCount,
            leak: leak,
            perProject: inputs.perProject
        )
    }

    nonisolated private static func appVersion() -> String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }

    nonisolated private func ensureLogDirectory() -> URL? {
        guard let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first else {
            return nil
        }
        let dir = library.appendingPathComponent("Logs/Muxy", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir
        } catch {
            logger.error("Failed to create log dir: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    nonisolated private func logFileURL() -> URL? {
        ensureLogDirectory()?.appendingPathComponent("diagnostics.log")
    }

    private struct Metrics {
        let footprintMB: Int
        let peakMB: Int
        let threadCount: Int
        let threadHistogram: [String: Int]
        let fdCount: Int
        let windowCount: Int
        let projectCount: Int
        let tabCount: Int
        let paneCount: Int
        let surfaceCount: Int
        let viewCount: Int
        let leak: Int
        let perProject: [PerProject]
    }

    private struct MainActorInputs {
        let windowCount: Int
        let surfaceCount: Int
        let viewCount: Int
        let projectCount: Int
        let tabCount: Int
        let paneCount: Int
        let perProject: [PerProject]
    }

    private struct PerProject {
        let index: Int
        let tabCount: Int
        let paneCount: Int
    }

    nonisolated private static func physFootprintBytes() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return Int(info.phys_footprint)
    }

    nonisolated private static func peakFootprintBytes() -> Int {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return 0 }
        return Int(usage.ru_maxrss)
    }

    nonisolated private static func threadInfo() -> (count: Int, histogram: [String: Int]) {
        var threadList: thread_act_array_t?
        var threadCount: mach_msg_type_number_t = 0
        guard task_threads(mach_task_self_, &threadList, &threadCount) == KERN_SUCCESS,
              let list = threadList
        else {
            return (0, [:])
        }
        defer {
            vm_deallocate(
                mach_task_self_,
                vm_address_t(UInt(bitPattern: list)),
                vm_size_t(Int(threadCount) * MemoryLayout<thread_t>.size)
            )
        }
        var histogram: [String: Int] = [:]
        for i in 0 ..< Int(threadCount) {
            let thread = list[i]
            var nameBuf = [CChar](repeating: 0, count: 64)
            if let pthread = pthread_from_mach_thread_np(thread),
               pthread_getname_np(pthread, &nameBuf, nameBuf.count) == 0
            {
                let name = String(cString: nameBuf)
                let key = name.isEmpty ? "(unnamed)" : name
                histogram[key, default: 0] += 1
            } else {
                histogram["(unnamed)", default: 0] += 1
            }
        }
        return (Int(threadCount), histogram)
    }

    nonisolated private static func makeBackgroundTimer(
        on queue: DispatchQueue,
        interval: TimeInterval,
        handler: @escaping @Sendable () -> Void
    ) -> DispatchSourceTimer {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler(handler: handler)
        timer.resume()
        return timer
    }

    nonisolated private static func fdCount() -> Int {
        let pid = getpid()
        let needed = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard needed > 0 else { return 0 }
        return Int(needed) / MemoryLayout<proc_fdinfo>.size
    }
}

import Foundation
import os

private let logger = Logger(subsystem: "app.muxy", category: "WorktreeAutoSync")

@MainActor
@Observable
final class WorktreeAutoSync {
    nonisolated static func isWorktreeRegistrationChange(_ path: String) -> Bool {
        path.contains("/worktrees")
    }

    @ObservationIgnored private let worktreeStore: WorktreeStore
    @ObservationIgnored private weak var appState: AppState?
    @ObservationIgnored private let resolveCommonDirectory: @Sendable (String) async -> String?
    @ObservationIgnored private let isGitRepository: @Sendable (String) async -> Bool

    @ObservationIgnored private var watchers: [UUID: (path: String, watcher: FileSystemWatcher)] = [:]
    @ObservationIgnored private var desired: [UUID: Project] = [:]
    @ObservationIgnored private var installing: Set<UUID> = []
    @ObservationIgnored private var refreshing: Set<UUID> = []
    @ObservationIgnored private var pendingRefresh: Set<UUID> = []

    init(
        worktreeStore: WorktreeStore,
        appState: AppState,
        resolveCommonDirectory: @escaping @Sendable (String) async -> String? = {
            await GitWorktreeService.shared.gitCommonDirectory(repoPath: $0)
        },
        isGitRepository: @escaping @Sendable (String) async -> Bool = {
            await GitWorktreeService.shared.isGitRepository($0)
        }
    ) {
        self.worktreeStore = worktreeStore
        self.appState = appState
        self.resolveCommonDirectory = resolveCommonDirectory
        self.isGitRepository = isGitRepository
    }

    func sync(projects: [Project]) {
        desired = Dictionary(projects.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        for (projectID, entry) in watchers where desired[projectID]?.path != entry.path {
            watchers.removeValue(forKey: projectID)
        }

        for project in projects {
            if watchers[project.id]?.path == project.path { continue }
            if installing.contains(project.id) { continue }
            install(project: project)
        }
    }

    private func install(project: Project) {
        let projectID = project.id
        let path = project.path
        installing.insert(projectID)
        Task { [weak self] in
            guard let self else { return }
            defer { self.installing.remove(projectID) }
            guard await self.isGitRepository(path),
                  let commonDirectory = await self.resolveCommonDirectory(path)
            else { return }
            guard self.desired[projectID]?.path == path else { return }
            guard let watcher = FileSystemWatcher(
                directoryPath: commonDirectory,
                eventFilter: { changedPath, _ in WorktreeAutoSync.isWorktreeRegistrationChange(changedPath) },
                handler: { [weak self] _ in
                    Task { @MainActor in self?.handleChange(projectID: projectID) }
                }
            )
            else {
                logger.error("Failed to watch \(commonDirectory, privacy: .public) for project \(projectID)")
                return
            }
            self.watchers[projectID] = (path, watcher)
        }
    }

    private func handleChange(projectID: UUID) {
        guard refreshing.contains(projectID) == false else {
            pendingRefresh.insert(projectID)
            return
        }
        runRefresh(projectID: projectID)
    }

    private func runRefresh(projectID: UUID) {
        guard let appState, let project = desired[projectID] else { return }
        refreshing.insert(projectID)
        Task { @MainActor [weak self] in
            guard let self else { return }
            await WorktreeRefreshHelper.refresh(
                project: project,
                appState: appState,
                worktreeStore: self.worktreeStore,
                presentErrors: false
            )
            self.refreshing.remove(projectID)
            if self.pendingRefresh.remove(projectID) != nil {
                self.runRefresh(projectID: projectID)
            }
        }
    }
}

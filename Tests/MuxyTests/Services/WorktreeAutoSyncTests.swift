import Foundation
import Testing

@testable import Muxy

@Suite("WorktreeAutoSync")
struct WorktreeAutoSyncTests {
    @Test("Worktree registration directory changes trigger a refresh")
    func registrationChangesTrigger() {
        #expect(WorktreeAutoSync.isWorktreeRegistrationChange("/repo/.git/worktrees/feature-a"))
        #expect(WorktreeAutoSync.isWorktreeRegistrationChange("/repo/.git/worktrees/feature-a/HEAD"))
        #expect(WorktreeAutoSync.isWorktreeRegistrationChange("/repo/.git/worktrees"))
    }

    @Test("Unrelated git internal changes are ignored")
    func unrelatedChangesIgnored() {
        #expect(!WorktreeAutoSync.isWorktreeRegistrationChange("/repo/.git/index"))
        #expect(!WorktreeAutoSync.isWorktreeRegistrationChange("/repo/.git/refs/heads/main"))
        #expect(!WorktreeAutoSync.isWorktreeRegistrationChange("/repo/.git/objects/ab/cdef"))
    }

    @Test("Default file system event filter still drops git internal directories and locks")
    func defaultEventFilterDropsGitInternal() {
        let keep = FileSystemWatcher.keepNonGitInternalEvents
        #expect(!keep("/repo/.git/index.lock", false))
        #expect(!keep("/repo/.git/worktrees/feature-a", true))
        #expect(keep("/repo/src/main.swift", false))
    }
}

import Foundation

/// Persistence for `GitProject` entries using UserDefaults.
///
/// Projects are stored in the shared `group.com.impress.suite` defaults so all
/// apps in the suite can see each other's git projects.
@MainActor
@Observable
public final class GitProjectStore {
    public static let shared = GitProjectStore()

    public private(set) var projects: [GitProject] = []

    private let defaults: UserDefaults
    private let key = "impress.gitProjects"

    private init() {
        self.defaults = UserDefaults(suiteName: "group.com.impress.suite") ?? .standard
        load()
    }

    // MARK: - CRUD

    public func add(_ project: GitProject) {
        projects.append(project)
        save()
    }

    public func update(_ project: GitProject) {
        if let idx = projects.firstIndex(where: { $0.id == project.id }) {
            projects[idx] = project
            save()
        }
    }

    public func remove(id: UUID) {
        projects.removeAll { $0.id == id }
        save()
    }

    public func project(at path: String) -> GitProject? {
        projects.first { $0.localPath == path }
    }

    public func projects(forApp appID: String) -> [GitProject] {
        projects.filter { $0.appID == appID }
    }

    // MARK: - Persistence

    private func save() {
        let data = projects.map { p -> [String: Any] in
            var dict: [String: Any] = [
                "id": p.id.uuidString,
                "repositoryUrl": p.repositoryUrl,
                "localPath": p.localPath,
                "branch": p.branch,
                "autoCommit": p.autoCommit,
                "autoPush": p.autoPush,
                "syncIntervalMinutes": p.syncIntervalMinutes,
            ]
            if let v = p.projectType { dict["projectType"] = v }
            if let v = p.mainFile { dict["mainFile"] = v }
            if let v = p.lastSyncTime { dict["lastSyncTime"] = v.timeIntervalSince1970 }
            if let v = p.lastCommitHash { dict["lastCommitHash"] = v }
            if let v = p.appID { dict["appID"] = v }
            return dict
        }
        defaults.set(data, forKey: key)
    }

    private func load() {
        guard let array = defaults.array(forKey: key) as? [[String: Any]] else { return }
        projects = array.compactMap { dict -> GitProject? in
            guard let idStr = dict["id"] as? String,
                  let id = UUID(uuidString: idStr),
                  let repoUrl = dict["repositoryUrl"] as? String,
                  let localPath = dict["localPath"] as? String,
                  let branch = dict["branch"] as? String
            else { return nil }

            var syncTime: Date?
            if let ts = dict["lastSyncTime"] as? TimeInterval {
                syncTime = Date(timeIntervalSince1970: ts)
            }

            return GitProject(
                id: id,
                repositoryUrl: repoUrl,
                localPath: localPath,
                branch: branch,
                projectType: dict["projectType"] as? String,
                mainFile: dict["mainFile"] as? String,
                lastSyncTime: syncTime,
                lastCommitHash: dict["lastCommitHash"] as? String,
                autoCommit: dict["autoCommit"] as? Bool ?? false,
                autoPush: dict["autoPush"] as? Bool ?? false,
                syncIntervalMinutes: dict["syncIntervalMinutes"] as? Int ?? 0,
                appID: dict["appID"] as? String
            )
        }
    }
}

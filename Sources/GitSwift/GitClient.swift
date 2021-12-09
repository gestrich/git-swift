//
//  GitClient.swift
//  
//
//  Created by Bill Gestrich on 6/6/21.
//

import Foundation
import swift_utilities

public struct GitClient {
    
    public let repoPath: String
    
    public init(repoPath: String) {
        self.repoPath = repoPath
    }
    
    public func repoName() -> String {
        return (repoPath as NSString).lastPathComponent
    }
    
    public func stageAllChanges(){
        let _ = runShellCommand(gitSubcommandArguments: ["add", "-u"], haltOnError: false)
    }
    
    public func commit(message: String){
        let _ = runShellCommand(gitSubcommandArguments: ["commit", "-m", message], haltOnError: false)
    }
    
    public func push(sourceBranch: String, targetBranch: String, remote:String, force: Bool = false){
        if force{
            let _ = runShellCommand(gitSubcommandArguments: ["push", "--force", remote, "\(sourceBranch):refs/heads/\(targetBranch)" ], haltOnError: false)
        } else {
            let _ = runShellCommand(gitSubcommandArguments: ["push", remote, "\(sourceBranch):refs/heads/\(targetBranch)" ], haltOnError: false)
        }
    }
    
    public func fetchedHash(haltOnError: Bool = true) -> String? {
        let response = runShellCommand(gitSubcommandArguments: ["rev-parse", "--verify", "FETCH_HEAD"], haltOnError: haltOnError)
        guard response.error == nil else {
            return nil
        }
        return response.output .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    public func mostRecentAncestorCommit(reference1: String, reference2: String) -> String? {
        let response = runShellCommand(gitSubcommandArguments: ["merge-base", reference1, reference2], haltOnError: false)
        if response.error != nil {
            return nil
        } else {
            return response.output.trimmingCharacters(in: .whitespacesAndNewlines)
        }

    }
    
    public func merge(branch: Branch, message: String) -> Bool{
        guard let commit = fetchCommit(branch: branch) else {
            return false
        }
        
        return merge(commit: commit, message: message)

    }
    
    public func merge(commit: String, message: String) -> Bool {
        let shellResult = runShellCommand(gitSubcommandArguments: ["merge", commit, "-m", message], haltOnError: false)
        return shellResult.error == nil
    }
    
    public func rebaseWithBranch(_ branch: Branch, haltOnError: Bool = true) -> RebaseResponse {
        guard let commit = fetchCommit(branch: branch) else {
            return .error(ShellError(code: "1"))
        }

        return rebase(commit: commit)
    }
    
    public func rebase(commit: String, haltOnError: Bool = true) -> RebaseResponse {
        let rebaseShellResult = runShellCommand(gitSubcommandArguments: ["rebase", commit], haltOnError: haltOnError)
        if rebaseShellResult.output.contains("Resolve all conflicts manually") {
            return .conflicts
        } else if let error = rebaseShellResult.error {
            if rebaseShellResult.output.contains("Applying") {
                return .success
            } else {
                return .error(error)
            }
        } else {
            return .success
        }
    }
    
    public func rebaseContinue(haltOnError: Bool = true){
        let _ = runShellCommand(gitSubcommandArguments: ["rebase", "--continue"], haltOnError: haltOnError)
    }

    public func rebaseAfterCommit(commit: String, message: String) {
        let _ = runShellCommand(gitSubcommandArguments: ["reset", "--soft", commit], haltOnError: true)
        self.stageAllChanges()
        self.commit(message: message)
    }
    
    public func rebaseToBranch(branch: Branch, message: String){
        guard let hash = self.fetchCommit(branch: branch) else {
            return
        }

        rebaseAfterCommit(commit: hash, message: message)
        print("Rebased \(self.repoName()):\(hash)")
    }
    
    public func statusMessage() -> String {
        let fetchResult = runShellCommand(gitSubcommandArguments: ["status", "HEAD"], haltOnError: true)
        return fetchResult.output.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    public func lastCommitMessage() -> String {
        let fetchResult = runShellCommand(gitSubcommandArguments: ["log", "-1"], haltOnError: true)
        return fetchResult.output.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    public func currentDiff() -> String {
        let fetchResult = runShellCommand(gitSubcommandArguments: ["diff", "HEAD"], haltOnError: true)
        return fetchResult.output.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    public func fetchCommit(branch: Branch) -> String? {
        
        if let remote = branch.remote, remote.isEmpty == false {
            let updateResult = runShellCommand(gitSubcommandArguments: ["remote", "update", remote])
            if updateResult.error != nil {
                return nil
            }
        }
        
        let fetchResult = runShellCommand(gitSubcommandArguments: ["rev-parse", branch.remoteQualifiedBranchName()], haltOnError: false)
        // git rev-parse origin/dev
        if fetchResult.error != nil {
            return nil
        } else {
            return fetchResult.output.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
    
    public func addRemote(remoteName: String, remoteURL: String) {
        let _ = runShellCommand(gitSubcommandArguments: ["remote", "set-url", remoteName, remoteURL], haltOnError: false)
        let _ = runShellCommand(gitSubcommandArguments: ["remote", "add", remoteName, remoteURL], haltOnError: false)
    }
    
    public func getSubmoduleStates(branch:Branch) -> [RepoState] {
        
        //Abort submodule rebases:
            //git submodule foreach "git rebase --abort || :"; git submodule update;
        
        guard let commit = fetchCommit(branch: branch) else {
            return []
        }
        
        return getSubmoduleStates(reference: commit)
    }
    
    public func getSubmoduleStates(reference: String) -> [RepoState] {
        
        var toRet = [RepoState]()

        let response = runShellCommand(gitSubcommandArguments: ["ls-tree", reference])
        for line in response.output.split(separator: "\n"){
            let cleanedUpline = line.replacingOccurrences(of: "\t", with: " ")
            let lineSplit = cleanedUpline.split(separator: " ")
            if !lineSplit.contains("commit"){
                continue
            }
            
            guard lineSplit.count == 4 else {continue}
            let repoName = String(lineSplit[3])
            let submodulePath = self.repoPath.appending("/\(repoName)")
            let submoduleClient = GitClient(repoPath: submodulePath)
            let submoduleCommit = String(lineSplit[2])
            toRet.append(RepoState(client: submoduleClient, commit: submoduleCommit))
        }
        
        return toRet
    }
    
    public func performRepoAndSubmoduleAction(_ clientBlock:(GitClient) -> Void) {
        let submodulePairs = getSubmoduleStates(reference: "HEAD")
        for pair in submodulePairs {
            clientBlock(pair.client)
        }
        
        clientBlock(self)
    }
    
    func runShellCommand(gitSubcommandArguments: [String], haltOnError: Bool = true) -> ShellResponse {
        let gitFilePath = repoPath + "/.git"
        let workingDirPath = repoPath
        let allCommandArguments = ["git", "--git-dir", gitFilePath, "--work-tree", workingDirPath] + gitSubcommandArguments
        let (resultStringOptional, code) = shell(arguments: allCommandArguments)
        let resultString = resultStringOptional ?? ""
        var shellError: ShellError?
        if code != 0 {
            shellError = ShellError(code: String(code))
            if haltOnError {
                print("Error Code: \(code). Error:  \(resultString) " +
                        "Command: \(allCommandArguments)")
                assertionFailure()
            }
        }

      return ShellResponse(output: resultString, error: shellError)
    }
}

public struct RepoState {
    
    public let client: GitClient
    public let commit: String
    
    public init(client: GitClient, commit: String) {
        self.client = client
        self.commit = commit
    }
}

public struct Branch {
    
    public let name: String
    public let remote: String?
    
    public init(name: String, remote: String?) {
        self.name = name
        self.remote = remote
    }
    
    public func remoteQualifiedBranchName() -> String {
        if let remote = remote {
            return remote + "/" + name
        } else {
            return name
        }
    }
}

public enum GitErrors: Error {
    case fetchError
}

public enum RebaseResponse {
    case conflicts
    case success
    case error(ShellError)
}

public struct ShellError: Error {
    public let code: String
}

public struct ShellResponse{
    public let output: String
    public let error: ShellError?
    
    public init(output: String, error: ShellError?) {
        self.output = output
        self.error = error
    }
    
    public var description: String {
        var toRet = ""
        if let error = error {
            toRet.append("\(error.code)\n")
        }
        
        toRet.append(output)
        
        return toRet
    }
}

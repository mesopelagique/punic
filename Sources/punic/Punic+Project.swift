//
//   Punic+Project.swift
//  
//
//  Created by phimage on 21/03/2020.
//

import Foundation
import ArgumentParser
import FileKit
import XcodeProjKit

extension Punic {

    struct Project: ParsableCommand {
        @Option(default: "", help: "The project path.")
        var path: String

        @Option(default: false, help: "Print debug information.")
        var debug: Bool

        func validate() throws {
            let path = self.path
            guard Path(path).exists else {
                throw ValidationError("'<path>' \(path) doesn't not exist.")
            }
        }

        func debug(_ message: String) {
            if debug {
                print(message)
            }
        }
        func error(_ message: String) {
            print("error: \(message)") // TODO: output in stderr
        }
        
        var rootPath: Path {
            let parameterPath: Path = Path(self.path)
            if parameterPath.has(extension: .xcodeproj) { // begentle if workspace passed as parameters
                return parameterPath.parent
            } else {
                return parameterPath
            }
        }
        
        var projectPath: Path? {
            let parameterPath: Path = Path(self.path)
            if parameterPath.has(extension: .xcodeproj) {
                return parameterPath
            } else {
                return parameterPath.find(extension: .xcodeproj)
            }
        }
        
        func run() {
            let rootPath = self.rootPath
            guard let projectPath: Path = self.projectPath else {
                error("Cannot find workspace in \(rootPath)") // XXX maybe create an empty one
                return
            }

            let projectDataPath: Path = projectPath + "project.pbxproj"
            let projectDataFile = DataFile(path: projectDataPath)
            guard let projectData = try? projectDataFile.read() else {
                error("Cannot read \(projectPath)")
                return
            }

            guard let xcodeProject = try? XcodeProj(propertyListData: projectData) else {
                error("Cannot read \(projectPath)")
                return
            }

            var hasChange = false

            let project = xcodeProject.project
            for target in project.targets {
                // remove script phrase with file in "Carthage/Build", suppose copy phase
                for buildPhase in target.buildPhases {
                    if let scriptPhase = buildPhase as? PBXShellScriptBuildPhase {
                        if scriptPhase.inputPaths.contains(where: { $0.contains(buildDir)}) {
                            target.remove(object: scriptPhase, forKey: PBXTarget.PBXKeys.buildPhases)
                            scriptPhase.unattach()
                            hasChange = true
                            debug("⚙️ Build script phrase \(scriptPhase.name ?? "") removed")
                        }
                    }
                }
                // Remove from FRAMEWORK_SEARCH_PATHS
                for buildConfiguration in target.buildConfigurationList?.buildConfigurations ?? [] {
                    if var buildSettings = buildConfiguration.buildSettings {
                        if var searchPaths = buildSettings["FRAMEWORK_SEARCH_PATHS"] as? [String] {
                            if searchPaths.contains(where: { $0.hasPrefix("$(PROJECT_DIR)/\(buildDir)") }) {
                                searchPaths = searchPaths.filter({!$0.hasPrefix("$(PROJECT_DIR)/\(buildDir)")})
                                hasChange = true
                                buildSettings["FRAMEWORK_SEARCH_PATHS"]=searchPaths
                                buildConfiguration.set(value: buildSettings, into: PBXBuildStyle.PBXKeys.buildSettings)
                                debug("🔍 FRAMEWORK_SEARCH_PATHS edited for configuration \(buildConfiguration.name ?? buildConfiguration.description)")
                            }
                        }
                    }
                }
            }
            // Change frameworkd file references path
            let buildProductsDir = SourceTreeFolder.buildProductsDir.rawValue
            let fullFileRefs = project.mainGroup?.fullFileRefs ?? []
            for fileRef in fullFileRefs {
                if let path = fileRef.path, path.contains(buildDir) {
                    switch (fileRef.sourceTree ?? SourceTree.group) {
                    case SourceTree.relativeTo(to: SourceTreeFolder.buildProductsDir):
                        break
                    default:
                        fileRef.set(value: buildProductsDir, into: PBXReference.PBXKeys.sourceTree)
                        let name = fileRef.name ?? path
                        fileRef.set(value: name, into: PBXReference.PBXKeys.path)
                        hasChange = true
                        debug("📦 \(String(describing: name)) path changed to \(buildProductsDir)")
                    }
                }
            }
            // Embed frameworkds
            for target in project.targets {
                let buildPhases = target.buildPhases
                let copyFilesBuildPhases = buildPhases.compactMap({$0 as? PBXCopyFilesBuildPhase})
                for copyfilesPhase in copyFilesBuildPhases {
                    if copyfilesPhase.name == "Embed Frameworks" {
                        let files = copyfilesPhase.files
                        let otherBuildPhases = buildPhases.compactMap({$0 as? PBXFrameworksBuildPhase})
                        let otherBuildFiles = otherBuildPhases.flatMap({$0.files})
                        // for each fileRef of framework in build phease
                        for otherBuildFile in otherBuildFiles {
                            guard let fileRef = otherBuildFile.fileRef as? PBXFileReference else {
                                continue
                            }
                            guard fileRef.lastKnownFileType ?? fileRef.explicitFileType == "wrapper.framework" else {
                                continue
                            }
                            guard !files.contains(where: { $0.fileRef as? PBXFileReference == fileRef}) else {
                                continue // already added
                            }
                            let fields: PBXObject.Fields = [
                                PBXBuildFile.PBXKeys.fileRef.rawValue: fileRef.ref,
                                PBXBuildFile.PBXKeys.settings.rawValue: ["ATTRIBUTES": ["CodeSignOnCopy", "RemoveHeadersOnCopy"]] // TODO option sign or not
                            ]
                            var newRef = XcodeUUID.generate()
                            while xcodeProject.objects.object(newRef) != nil {
                                newRef = XcodeUUID.generate()
                            }
                            let embedFile = PBXBuildFile(ref: newRef, fields: fields, objects: xcodeProject.objects)
                            embedFile.attach()
                            copyfilesPhase.add(object: embedFile, into: PBXBuildPhase.PBXKeys.files)
                            debug("🚀 Embed framework \(fileRef.name ?? fileRef.path ?? fileRef.description) with ref \(newRef)")
                            hasChange = true
                        }
                    }
                }
            }

            // If has change, write to file
            if hasChange {
                do {
                    try xcodeProject.write(to: projectDataPath.url, format: .openStep)
                    print("💾 Project saved")
                } catch let ioError {
                    error("Cannot save project \(ioError)")
                }
            } else {
                debug("❄️ Nothing to change")
            }
        }
    }
}

extension XcodeUUID {
    static func generate() -> XcodeUUID {
        return String(format: "%06X%06X%06X%06X", Int(arc4random() % 65535), Int(arc4random() % 65535), Int(arc4random() % 65535), Int(arc4random() % 65535))
    }
}

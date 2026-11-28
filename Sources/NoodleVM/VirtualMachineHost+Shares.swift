import Foundation
import Virtualization
import NoodleCore
import os

extension VirtualMachineHost {
    /// Register only this container's requested directories on the VM queue.
    public func setHostShares(containerID: String, mounts: [GuestMount]) async throws -> [GuestMount] {
        try await withCheckedThrowingContinuation { cont in
            queue.async { [self] in
                do {
                    guard let device = vm?.directorySharingDevices.compactMap({ $0 as? VZVirtioFileSystemDevice }).first(where: { $0.tag == "host" }) else { throw VMError.notRunning }
                    guard containerID.range(of: "^[a-f0-9]+$", options: .regularExpression) != nil else { throw VMError.invalidConfiguration("invalid container ID") }
                    var mapped = mounts
                    var entries: [String: HostShareTable.Entry] = [:]
                    for i in mapped.indices where mapped[i].kind == "bind" {
                        let path = URL(fileURLWithPath: mapped[i].source).standardizedFileURL.resolvingSymlinksInPath()
                        let type = (try? FileManager.default.attributesOfItem(atPath: path.path)[.type]) as? FileAttributeType
                        guard mapped[i].source.hasPrefix("/"), path.path == mapped[i].source,
                              type == .typeDirectory || type == .typeRegular else {
                            throw VMError.invalidConfiguration("bind source must be an existing regular file or directory: \(mapped[i].source)")
                        }
                        let isDirectory = type == .typeDirectory
                        let root = isDirectory ? path : path.deletingLastPathComponent()
                        let inode = HostShareKey.inode(of: root.path) ?? 0
                        let key = HostShareKey.key(directory: root.path, inode: inode, readOnly: mapped[i].readOnly)
                        entries[key] = .init(path: root.path, readOnly: mapped[i].readOnly, inode: inode)
                        mapped[i].source = HostShareKey.guestSource(hostPath: path.path, isDirectory: isDirectory, readOnly: mapped[i].readOnly)
                    }
                    hostShares[containerID] = entries
                    retainedShares.add(entries)
                    let placeholder = config.consoleLog.deletingLastPathComponent().appendingPathComponent("empty-share")
                    try FileManager.default.createDirectory(at: placeholder, withIntermediateDirectories: true)
                    let live = retainedShares.resolved(placeholder: placeholder.path, inodeOf: HostShareKey.inode(of:))
                    for (key, entry) in live where shareObjects[key]?.entry != entry {
                        shareObjects[key] = (entry, VZSharedDirectory(url: URL(fileURLWithPath: entry.path), readOnly: entry.readOnly))
                    }
                    device.share = VZMultipleDirectoryShare(directories: shareObjects.mapValues(\.directory))
                    cont.resume(returning: mapped)
                } catch { cont.resume(throwing: error) }
            }
        }
    }

    /// The container no longer uses its shares. They stay registered until the VM stops (see `retainedShares`);
    /// only containers whose spec names a key can mount it.
    public func removeHostShares(containerID: String) async {
        await withCheckedContinuation { cont in
            queue.async { [self] in
                hostShares[containerID] = nil
                cont.resume()
            }
        }
    }
}

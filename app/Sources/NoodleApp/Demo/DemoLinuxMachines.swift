/// Local, mutable fixtures used by the Machines page in --demo mode. No CLI or VM is started.
enum DemoLinuxMachines {
    static let items: [LinuxMachine] = [
        LinuxMachine(name: "dev", state: "running", distro: "ubuntu", image: "ubuntu:24.04", cpus: 2, memoryMiB: 4096, diskGiB: 40),
        LinuxMachine(name: "alpine-test", state: "stopped", distro: "alpine", image: "alpine:3.22", cpus: 2, memoryMiB: 1024, diskGiB: 20),
        LinuxMachine(name: "unfinished", state: "incomplete", distro: "ubuntu", image: "ubuntu:24.04", cpus: 2, memoryMiB: 2048, diskGiB: 20),
    ]

    /// What `machine status` would add for each demo machine.
    static let info: [String: LinuxMachineInfo] = [
        "dev": LinuxMachineInfo(address: "192.168.64.12", sharedFolder: "/Users/demo/Code", diskUsed: "8.2 GiB"),
        "alpine-test": LinuxMachineInfo(address: nil, sharedFolder: nil, diskUsed: "412 MiB"),
    ]
}

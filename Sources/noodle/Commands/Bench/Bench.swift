import Foundation
import NoodleCore

func percentile(_ xs: [Double], _ p: Double) -> Double {
    let s = xs.sorted()
    return s.isEmpty ? 0 : s[min(s.count - 1, Int(Double(s.count - 1) * p))]
}

func cmdBench(_ args: [String]) {
    guard args.isEmpty || args == ["--run"] ||
        (args.count == 2 && args[0] == "--run" && !args[1].hasPrefix("-")) else {
        die("usage: noodle debug bench [--run [IMAGE]]", code: 2)
    }
    guard ping() else { die("Noodle engine is not running. Start it with `noodle start`.", code: 3) }
    func time(_ n: Int, _ f: () -> Void) -> [Double] {
        (0..<n).map { _ in let t = DispatchTime.now().uptimeNanoseconds; f(); return Double(DispatchTime.now().uptimeNanoseconds - t) / 1e6 }
    }
    let pings = time(200) { _ = httpGet("/_ping") }
    let lists = time(50) { _ = httpGet("/containers/json?all=1") }
    out(String(format: "%-28@ p50 %7.2f ms   p95 %7.2f ms", "GET /_ping (200)" as NSString, percentile(pings, 0.5), percentile(pings, 0.95)))
    out(String(format: "%-28@ p50 %7.2f ms   p95 %7.2f ms", "GET /containers/json (50)" as NSString, percentile(lists, 0.5), percentile(lists, 0.95)))
    if let i = args.firstIndex(of: "--run") {
        let image = i + 1 < args.count ? args[i + 1] : "alpine"
        guard let docker = which("docker") else { err("docker CLI not found, skipping container start benchmark"); return }
        out("docker run --rm \(image) true  (first run may pull the image and is discarded)")
        _ = run(docker, ["run", "--rm", image, "true"], extraEnv: ["DOCKER_HOST": "unix://" + socketPath])
        let runs = time(5) { _ = run(docker, ["run", "--rm", image, "true"], extraEnv: ["DOCKER_HOST": "unix://" + socketPath]) }
        out(String(format: "%-28@ p50 %7.0f ms   p95 %7.0f ms", "docker run --rm (5)" as NSString, percentile(runs, 0.5), percentile(runs, 0.95)))
    } else { out("Add `--run [image]` to time `docker run --rm <image> true`.") }
}

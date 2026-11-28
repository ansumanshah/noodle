import Foundation

extension DemoDocker {
    nonisolated func events() async throws -> AsyncThrowingStream<DockerEvent, Error> {
        let key = UUID()
        return AsyncThrowingStream { cont in
            Task { await self.addSubscriber(key, cont) }
            cont.onTermination = { _ in Task { await self.removeSubscriber(key) } }
        }
    }

    nonisolated func logs(_ id: String, tty: Bool, tail: Int) async throws -> AsyncThrowingStream<LogEntry, Error> {
        AsyncThrowingStream { cont in
            let task = Task {
                let samples = [
                    ("INFO", "GET /api/products 200 12ms"), ("INFO", "GET /api/cart 200 4ms"), ("DEBUG", "cache hit key=product:42"),
                    ("INFO", "POST /api/checkout 201 88ms"), ("WARN", "slow query: SELECT * FROM orders WHERE user_id=$1 (412ms)"),
                    ("INFO", "GET /healthz 200 1ms"),
                    DemoFlags.healthy ? ("INFO", "payment captured order=1042 34ms") : ("ERROR", "payment provider timeout after 3000ms, retrying (1/3)"),
                    ("INFO", "worker: processed 14 jobs"), ("DEBUG", "gc pause 3.2ms"), ("INFO", "GET /api/products/42 200 6ms"),
                ]
                var n = 0
                func line() -> LogEntry {
                    let s = samples[(n * 7 + n / 3) % samples.count]; n += 1
                    let text = "\(s.0) \(s.1)"
                    return LogEntry(stderr: s.0 == "ERROR", time: Date().addingTimeInterval(Double(n - 60)), text: text, level: LogLevel.detect(text, stderr: s.0 == "ERROR"))
                }
                for _ in 0..<60 { cont.yield(line()) }
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(700))
                    cont.yield(line())
                }
                cont.finish()
            }
            cont.onTermination = { _ in task.cancel() }
        }
    }

    nonisolated func stats(_ id: String) async throws -> AsyncThrowingStream<StatsSample, Error> {
        AsyncThrowingStream { cont in
            let task = Task {
                var i = 0
                while !Task.isCancelled {
                    i += 1
                    let t = Double(i)
                    cont.yield(StatsSample(id: i, cpuPercent: max(0.2, 14 + 11 * sin(t / 5) + 3 * sin(t * 1.7)),
                                           memoryBytes: Int(180_000_000 + 24_000_000 * sin(t / 11)), memoryLimit: 4 << 30,
                                           netRx: i * 18_400, netTx: i * 7_900, pids: 12 + (i / 9) % 3))
                    try? await Task.sleep(for: .seconds(1))
                }
                cont.finish()
            }
            cont.onTermination = { _ in task.cancel() }
        }
    }
}

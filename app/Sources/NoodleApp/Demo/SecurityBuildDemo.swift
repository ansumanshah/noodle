import Foundation

/// Local fixtures for the on-demand pages. Demo actions never invoke the CLI or download helpers.
enum SecurityBuildDemo {
    static let scan = Data(#"{"matches":[{"artifact":{"name":"libssl3","version":"3.1.0"},"vulnerability":{"id":"DEMO-2026-0001","severity":"High","fix":{"versions":["3.1.8"]}}},{"artifact":{"name":"busybox","version":"1.36.0"},"vulnerability":{"id":"DEMO-2026-0002","severity":"Low","fix":{"versions":[]}}}]}"#.utf8)
    static var history: Data {
        Data((#"[{"image":"alpine:3.22","imageID":"sha256:8192a3b4c5d6","created":"2026-11-06T09:15:00Z","scanner":"grype","version":"demo","result": "#
              + String(decoding: scan, as: UTF8.self) + "}]").utf8)
    }
    static let sbom = Data(#"{"bomFormat":"CycloneDX","specVersion":"1.6","version":1,"components":[{"type":"library","name":"libssl3","version":"3.1.0","purl":"pkg:apk/alpine/libssl3@3.1.0"},{"type":"application","name":"busybox","version":"1.36.0","purl":"pkg:apk/alpine/busybox@1.36.0"}]}"#.utf8)
    static let builds = Data(#"[{"id":"demo-build-cached","tags":["web:latest"],"startedAt":"2026-11-06T09:00:00Z","endedAt":"2026-11-06T09:00:02Z","status":"success","duration":2.1,"cachedSteps":5,"totalSteps":6,"contextSize":8192},{"id":"demo-build-failed","tags":["worker:dev"],"startedAt":"2026-11-06T08:30:00Z","endedAt":"2026-11-06T08:30:04Z","status":"failed","error":"Build command exited with code 1","duration":4.0,"cachedSteps":1,"totalSteps":3,"contextSize":4096}]"#.utf8)
    static func buildDetail(_ id: String) -> Data {
        // Use the same wire format as builds inspect, which adds the captured log to a list record.
        guard let rows = try? JSONSerialization.jsonObject(with: builds) as? [[String: Any]],
              var row = rows.first(where: { $0["id"] as? String == id }) else { return Data() }
        row["log"] = id == "demo-build-cached"
            ? "Step 1/6: FROM alpine:3.18\nUsing cache\nStep 6/6: COPY . /app\nSuccessfully built web:latest\n"
            : "Step 1/3: FROM alpine:3.18\nUsing cache\nStep 3/3: RUN make test\nBuild command exited with code 1\n"
        return (try? JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])) ?? Data()
    }
}

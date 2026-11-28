import AppKit
import NoodleCore
import SwiftUI

struct ModelEndpointAddress: View {
    let title: String
    let url: URL
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption.weight(.medium)).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Text(url.absoluteString).font(.callout.monospaced()).textSelection(.enabled)
                    .lineLimit(2).truncationMode(.middle).frame(maxWidth: .infinity, alignment: .leading)
                Button(copied ? "Copied" : "Copy URL", systemImage: copied ? "checkmark" : "doc.on.doc") {
                    copyToPasteboard(url.absoluteString)
                    copied = true
                }
                .labelStyle(.iconOnly).buttonStyle(.iconAction)
                .contentTransition(.symbolEffect(.replace))
                .accessibilityLabel(copied ? "\(title) URL copied" : "Copy \(title) URL")
                .help(copied ? "Copied" : "Copy URL")
            }
            .padding(Space.m)
            .background(Color.secondary.opacity(0.08), in: .rect(cornerRadius: Radius.control, style: .continuous))
        }
        .onChange(of: url) { copied = false }
        .autoReset($copied, to: false)
    }
}

struct ModelConnectionMetrics: View {
    let metrics: ModelGenerationMetrics

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Last chat request").font(.headline)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 28) { values }
                VStack(alignment: .leading, spacing: 12) { values }
            }
            Text("Measured from the most recent request in Chat. Token counts appear when supplied by the server.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .cardSurface()
    }

    @ViewBuilder private var values: some View {
        metric("Duration", value: "\(metrics.elapsed.formatted(.number.precision(.fractionLength(2)))) s")
        if let first = metrics.timeToFirstToken {
            metric("First token", value: "\(first.formatted(.number.precision(.fractionLength(2)))) s")
        }
        if let count = metrics.outputTokens { metric("Output", value: "\(count) tokens") }
        if let rate = metrics.tokensPerSecond {
            metric("Request throughput", value: "\(rate.formatted(.number.precision(.fractionLength(1)))) tok/s")
        }
    }

    private func metric(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.monospacedDigit().weight(.semibold))
        }
    }
}

enum ModelRequestExample: String, CaseIterable, Identifiable {
    case curl = "cURL", python = "Python"
    var id: Self { self }

    func code(baseURL: URL, model: String, kind: LocalModelKind = .chat) -> String {
        switch kind {
        case .embeddings: return embeddings(baseURL: baseURL, model: model)
        case .speechToText, .textToSpeech: return speech(baseURL: baseURL, model: model, transcription: kind == .speechToText)
        case .imageGeneration, .videoGeneration: return media(baseURL: baseURL, model: model, video: kind == .videoGeneration)
        case .chat: break
        }
        let endpoint = baseURL.appendingPathComponent("chat/completions").absoluteString
        let body = "{\"model\":\"\(model)\",\"messages\":[{\"role\":\"user\",\"content\":\"Hello!\"}]}"
        switch self {
        case .curl:
            return """
            curl '\(endpoint)' \\
              -H "Authorization: Bearer $NOODLE_API_KEY" \\
              -H 'Content-Type: application/json' \\
              -d '\(body)'
            """
        case .python:
            return """
            import json, os, urllib.request

            request = urllib.request.Request(
                "\(endpoint)",
                data=json.dumps({
                    "model": "\(model)",
                    "messages": [{"role": "user", "content": "Hello!"}],
                }).encode(),
                headers={
                    "Authorization": "Bearer " + os.environ["NOODLE_API_KEY"],
                    "Content-Type": "application/json",
                },
            )
            with urllib.request.urlopen(request) as response:
                print(json.load(response)["choices"][0]["message"]["content"])
            """
        }
    }
}

extension ModelRequestExample {
    fileprivate func embeddings(baseURL: URL, model: String) -> String {
        let endpoint = baseURL.appendingPathComponent("embeddings").absoluteString
        switch self {
        case .curl:
            return """
            curl '\(endpoint)' \\
              -H "Authorization: Bearer $NOODLE_API_KEY" \\
              -H 'Content-Type: application/json' \\
              -d '{"model":"\(model)","input":"Hello!"}'
            """
        case .python:
            return """
            import json, os, urllib.request

            request = urllib.request.Request(
                "\(endpoint)",
                data=json.dumps({"model": "\(model)", "input": "Hello!"}).encode(),
                headers={
                    "Authorization": "Bearer " + os.environ["NOODLE_API_KEY"],
                    "Content-Type": "application/json",
                },
            )
            with urllib.request.urlopen(request) as response:
                print(len(json.load(response)["data"][0]["embedding"]))
            """
        }
    }

    /// Image and video models answer one JSON request; the reply carries base64 PNG or raw frames.
    fileprivate func media(baseURL: URL, model: String, video: Bool) -> String {
        let endpoint = baseURL.appendingPathComponent(video ? "video/generations" : "images/generations").absoluteString
        let body = video ? #"{"model":"\#(model)","prompt":"A paper boat on a pond","num_frames":49}"#
            : #"{"model":"\#(model)","prompt":"A paper boat on a pond","size":"1024x1024","steps":4}"#
        switch self {
        case .curl:
            return """
            curl '\(endpoint)' \\
              -H "Authorization: Bearer $NOODLE_API_KEY" \\
              -H 'Content-Type: application/json' \\
              -d '\(body)'
            """
        case .python:
            return """
            import json, os, urllib.request

            headers = {"Authorization": "Bearer " + os.environ["NOODLE_API_KEY"], "Content-Type": "application/json"}
            request = urllib.request.Request("\(endpoint)", data=json.dumps(\(body)).encode(), headers=headers)
            with urllib.request.urlopen(request) as response:
                print(list(json.load(response)))
            """
        }
    }

    /// Speech models are API only. `/audio/transcriptions` takes a multipart WAV, `/audio/speech` returns a WAV.
    fileprivate func speech(baseURL: URL, model: String, transcription: Bool) -> String {
        let endpoint = baseURL.appendingPathComponent(transcription ? "audio/transcriptions" : "audio/speech").absoluteString
        switch (self, transcription) {
        case (.curl, true):
            return """
            curl '\(endpoint)' \\
              -H "Authorization: Bearer $NOODLE_API_KEY" \\
              -F file=@speech.wav \\
              -F model='\(model)'
            """
        case (.curl, false):
            return """
            curl '\(endpoint)' \\
              -H "Authorization: Bearer $NOODLE_API_KEY" \\
              -H 'Content-Type: application/json' \\
              -d '{"model":"\(model)","input":"Hello from Noodle."}' \\
              -o speech.wav
            """
        case (.python, true):
            return """
            import os
            from openai import OpenAI

            client = OpenAI(base_url="\(baseURL.absoluteString)", api_key=os.environ["NOODLE_API_KEY"])
            with open("speech.wav", "rb") as audio:
                print(client.audio.transcriptions.create(model="\(model)", file=audio).text)
            """
        case (.python, false):
            return """
            import os
            from openai import OpenAI

            client = OpenAI(base_url="\(baseURL.absoluteString)", api_key=os.environ["NOODLE_API_KEY"])
            audio = client.audio.speech.create(model="\(model)", voice="af_heart", input="Hello from Noodle.")
            open("speech.wav", "wb").write(audio.read())
            """
        }
    }
}

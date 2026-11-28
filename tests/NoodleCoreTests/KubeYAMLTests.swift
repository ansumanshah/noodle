import Testing
@testable import NoodleCore

struct KubeYAMLTests {
    @Test func deepNestingIsRejected() {
        let block = (0..<200).map { String(repeating: " ", count: $0) + "k\($0):" }.joined(separator: "\n") + " v"
        #expect(throws: (any Error).self) { _ = try KubeYAML.parse(block) }
        #expect(throws: (any Error).self) { _ = try KubeYAML.parse("a: " + String(repeating: "[", count: 5000) + String(repeating: "]", count: 5000)) }
        #expect(throws: Never.self) { _ = try KubeYAML.parse("a: [[[1]]]") }
    }

    @Test func nestedManifestAndIndentlessLists() throws {
        let docs = try KubeYAML.parse("""
        apiVersion: v1
        kind: Pod
        metadata:
          name: demo # comment
        spec:
          containers:
          - name: web
            image: nginx:alpine
            command: ["sh", '-c']
            args: [echo hello, "a:b"]
            env:
            - name: PORT
              value: "8080"
        """)
        let spec = try #require(docs.first?["spec"] as? [String: Any])
        let containers = try #require(spec["containers"] as? [[String: Any]])
        #expect(containers.count == 1)
        #expect(containers[0]["image"] as? String == "nginx:alpine")
        #expect(containers[0]["command"] as? [String] == ["sh", "-c"])
        #expect((containers[0]["env"] as? [[String: Any]])?.first?["value"] as? String == "8080")
    }

    @Test func documentsFlowAndQuotedValues() throws {
        let docs = try KubeYAML.parse("""
        ---
        kind: ConfigMap
        metadata: {name: demo, labels: {app: 'it''s'}}
        data:
          text: "hash # preserved"
        ---
        kind: Pod
        spec: {containers: [{name: app, image: alpine}]}
        ...
        """)
        #expect(docs.count == 2)
        let metadata = try #require(docs[0]["metadata"] as? [String: Any])
        #expect((metadata["labels"] as? [String: String])?["app"] == "it's")
        #expect((docs[0]["data"] as? [String: String])?["text"] == "hash # preserved")
    }

    @Test func blockScalarsAndQuoting() throws {
        let docs = try KubeYAML.parse("""
        data:
          literal: |-
            first
            ---
            second
          folded: >
            one
            two
        """)
        let data = try #require(docs[0]["data"] as? [String: String])
        #expect(data["literal"] == "first\n---\nsecond")
        #expect(data["folded"] == "one two\n")
        let original = "a: # b\n\"quoted\"\\path"
        #expect(try KubeYAML.parse("value: " + KubeYAML.quote(original))[0]["value"] as? String == original)
    }

    @Test func rejectsUnsupportedOrMalformedInput() {
        for input in ["a: x\na: y", "a: &anchor x", "a: *anchor", "a: !!str x", "a: [x", "a: {x: a, x: b}", "a:\n\tb: x", "a: 'unclosed", "a: x\n  unexpected: y", "- scalar", "a: {<<: x}"] {
            #expect(throws: KubeYAML.ParseError.self) { try KubeYAML.parse(input) }
        }
    }

    @Test func apostropheInsidePlainScalarIsText() throws {
        let docs = try KubeYAML.parse("""
        value: don't
        other: it's # trailing comment
        flow: [don't, "a, b"]
        """)
        #expect(docs[0]["value"] as? String == "don't")
        #expect(docs[0]["other"] as? String == "it's")
        #expect(docs[0]["flow"] as? [String] == ["don't", "a, b"])
        #expect(throws: KubeYAML.ParseError.self) { try KubeYAML.parse("a: 'unclosed") }
    }

    @Test func foldedScalarBlankLineIsOneNewline() throws {
        let docs = try KubeYAML.parse("""
        data:
          one: >-
            a
            b

            c
          two: >-
            a


            c
        """)
        let data = try #require(docs[0]["data"] as? [String: String])
        #expect(data["one"] == "a b\nc")
        #expect(data["two"] == "a\n\nc")
    }
}

import Testing
@testable import NoodleApp

@Suite struct PickerFilterTests {
    private let options = ["Llama 3", "Qwen Café", "Mistral"].map { PickerOption(id: $0, label: $0) }

    @Test func emptyQueryKeepsAll() {
        #expect(PickerFilter.filter(options, query: "  ").count == 3)
    }
    @Test func ignoresCase() {
        #expect(PickerFilter.filter(options, query: "LLAMA").map(\.id) == ["Llama 3"])
    }
    @Test func ignoresDiacritics() {
        #expect(PickerFilter.filter(options, query: "cafe").map(\.id) == ["Qwen Café"])
        #expect(PickerFilter.filter(options, query: "zzz").isEmpty)
    }
    @Test func stepClamps() {
        #expect(PickerFilter.step(0, by: -1, count: 3) == 0)
        #expect(PickerFilter.step(2, by: 1, count: 3) == 2)
        #expect(PickerFilter.step(0, by: 1, count: 0) == 0)
    }
}

import Testing
@testable import noodle

@Suite struct HuggingFaceAuthHostTests {
    @Test func tokenGoesOnlyToHttpsHuggingFace() {
        #expect(ModelStore.isHuggingFace("https://huggingface.co/a/b"))
        #expect(ModelStore.isHuggingFace("HTTPS://HuggingFace.CO/a/b"))
        #expect(!ModelStore.isHuggingFace("http://huggingface.co/a/b"))
        #expect(!ModelStore.isHuggingFace("https://huggingface.co.evil.com/a"))
    }
}

import Testing
@testable import NoodleCore
@testable import NoodleEngine

@Suite struct FilterMatchingTests {
    @Test func nameFilterIsAnUnanchoredRegularExpression() {
        let f = Filters(["name": ["^web$"]])
        #expect(f.nameMatches("web"))
        #expect(!f.nameMatches("web2"))
        #expect(Filters(["name": ["eb"]]).nameMatches("web2"))
    }

    @Test func leadingSlashFormMatches() {
        #expect(Filters(["name": ["^/web$"]]).nameMatches("web"))
    }

    @Test func invalidPatternMatchesNothing() {
        #expect(!Filters(["name": ["("]]).nameMatches("web"))
    }

    @Test func unknownKeysAreReported() {
        let f = Filters(["status": ["running"], "bogus": ["1"], "label!": ["a"]])
        #expect(f.firstUnknownKey(allowed: FilterKeys.containers) == "bogus")
        #expect(Filters(["label!": ["a"]]).firstUnknownKey(allowed: FilterKeys.containers) == nil)
    }
}

@Suite struct LabelFilterTests {
    @Test func emptyKeyIsRejectedAndNeverCrashes() {
        #expect(LabelFilter("") == nil)
        #expect(LabelFilter("=v") == nil)
        #expect(Filters(["label": [""]]).firstInvalidLabel() == "")
        #expect(!Filters(["label": [""]]).matchLabels(["a": "b"]))
    }

    @Test func emptyValueIsAllowedAndExact() {
        #expect(LabelFilter("a=")?.value == "")
        #expect(Filters(["label": ["a="]]).matchLabels(["a": ""]))
        #expect(!Filters(["label": ["a="]]).matchLabels(["a": "b"]))
        #expect(Filters(["label": ["a"]]).matchLabels(["a": "b"]))
        #expect(Filters(["label!": ["a=b"]]).matchLabels(["a": "c"]))
    }
}

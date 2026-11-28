import Foundation
import Testing
@testable import NoodleApp

@MainActor @Suite struct ModelImportTests {
    @Test func pickerFailureIsVisibleAndDismissible() async {
        let store = ModelsPageStore(demo: true)
        let error = NSError(domain: "ModelImportTests", code: 7,
                            userInfo: [NSLocalizedDescriptionKey: "The selected file is unavailable."])
        await store.finishImport(.failure(error))
        #expect(store.problem?.title == "Couldn’t import the model")
        #expect(store.problem?.detail == "The selected file is unavailable.")
        #expect(store.problem?.retry == nil)
        store.dismissProblem()
        #expect(store.problem == nil)
    }

    @Test func cancellingThePickerDoesNotReportAnError() async {
        let store = ModelsPageStore(demo: true)
        await store.finishImport(.failure(CocoaError(.userCancelled)))
        #expect(store.problem == nil)
    }
}

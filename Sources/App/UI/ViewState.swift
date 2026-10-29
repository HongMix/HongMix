import Combine
import SwiftUI

/// Drop-in replacement for SwiftUI's `@State`.
/// In the macOS 27 SDK `@State` is a Swift macro whose implementation ships only with Xcode,
/// so a Command Line Tools build can't expand it. This wrapper is built on `StateObject`
/// (a plain property wrapper) and behaves the same: view-local storage + `$binding`.
final class ViewStateBox<Value>: ObservableObject {
    @Published var value: Value
    init(_ value: Value) { self.value = value }
}

@propertyWrapper
struct ViewState<Value>: DynamicProperty {
    @StateObject private var box: ViewStateBox<Value>

    init(wrappedValue: Value) {
        _box = StateObject(wrappedValue: ViewStateBox(wrappedValue))
    }

    init(initialValue: Value) {
        self.init(wrappedValue: initialValue)
    }

    @MainActor var wrappedValue: Value {
        get { box.value }
        nonmutating set { box.value = newValue }
    }

    @MainActor var projectedValue: Binding<Value> {
        $box.value
    }
}

import SwiftUI

/// Number entry that looks like a normal text box (instead of a Stepper you have to click 9000 times).
struct NumberField: View {
    let title: String
    @Binding var value: Int
    var range: ClosedRange<Int> = 0...Int.max
    var unit: String = ""

    init(_ title: String, value: Binding<Int>, in range: ClosedRange<Int> = 0...Int.max, unit: String = "") {
        self.title = title
        self._value = value
        self.range = range
        self.unit = unit
    }

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 6) {
                TextField("", value: Binding(get: { value }, set: { value = min(range.upperBound, max(range.lowerBound, $0)) }),
                          format: .number.grouping(.never))
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 90)
                if !unit.isEmpty {
                    Text(unit).foregroundColor(.secondary)
                }
            }
        }
    }
}

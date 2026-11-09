import SwiftUI

/// Number entry that looks like a normal text box (instead of a Stepper you have to click 9000 times).
/// Every number row in the app uses this one shape: `Label …… [ 123 ] unit [⌃⌄]` (arrows only when `step` > 0).
struct NumberField: View {
    let title: String
    @Binding var value: Int
    var range: ClosedRange<Int> = 0...Int.max
    var unit: String = ""
    var step: Int = 0
    var width: CGFloat = 90

    init(_ title: String, value: Binding<Int>, in range: ClosedRange<Int> = 0...Int.max, unit: String = "",
         step: Int = 0, width: CGFloat = 90) {
        self.title = title
        self._value = value
        self.range = range
        self.unit = unit
        self.step = step
        self.width = width
    }

    private var clamped: Binding<Int> {
        Binding(get: { value }, set: { value = min(range.upperBound, max(range.lowerBound, $0)) })
    }

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 6) {
                TextField("", value: clamped, format: .number.grouping(.never))
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .frame(width: width)
                if !unit.isEmpty {
                    Text(unit).foregroundColor(.secondary).lineLimit(1).fixedSize()
                }
                if step > 0 {
                    Stepper("", value: clamped, in: range, step: step).labelsHidden()
                }
            }
        }
    }
}

/// Same row shape as `NumberField` for fractional values (seconds etc.).
struct DecimalField: View {
    let title: String
    @Binding var value: Double
    var range: ClosedRange<Double>
    var unit: String = ""
    var step: Double = 0
    var digits: Int = 0
    var width: CGFloat = 90

    init(_ title: String, value: Binding<Double>, in range: ClosedRange<Double>, unit: String = "",
         step: Double = 0, digits: Int = 0, width: CGFloat = 90) {
        self.title = title
        self._value = value
        self.range = range
        self.unit = unit
        self.step = step
        self.digits = digits
        self.width = width
    }

    private var clamped: Binding<Double> {
        Binding(get: { value }, set: { value = min(range.upperBound, max(range.lowerBound, $0)) })
    }

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 6) {
                TextField("", value: clamped, format: .number.grouping(.never).precision(.fractionLength(0...max(0, digits))))
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .frame(width: width)
                if !unit.isEmpty {
                    Text(unit).foregroundColor(.secondary).lineLimit(1).fixedSize()
                }
                if step > 0 {
                    Stepper("", value: clamped, in: range, step: step).labelsHidden()
                }
            }
        }
    }
}

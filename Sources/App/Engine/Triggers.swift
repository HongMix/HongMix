import Foundation

/// vMix-style input triggers: when something happens to an input, run API functions automatically.
enum TriggerEvent: String, Codable, CaseIterable, Identifiable {
    case transitionIn = "OnTransitionIn"
    case transitionOut = "OnTransitionOut"
    case overlayIn = "OnOverlayIn"
    case overlayOut = "OnOverlayOut"
    case completion = "OnCompletion"
    case countdownCompleted = "OnCountdownCompleted"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .transitionIn: return L("Output으로 들어갈 때 (OnTransitionIn)")
        case .transitionOut: return L("Output에서 빠질 때 (OnTransitionOut)")
        case .overlayIn: return L("오버레이로 들어갈 때 (OnOverlayIn)")
        case .overlayOut: return L("오버레이에서 빠질 때 (OnOverlayOut)")
        case .completion: return L("영상 재생이 끝났을 때 (OnCompletion)")
        case .countdownCompleted: return L("카운트다운이 0이 됐을 때 (OnCountdownCompleted)")
        }
    }
}

struct InputTrigger: Codable, Identifiable, Equatable {
    var id = UUID()
    var event: TriggerEvent = .completion
    var delayMs: Int = 0
    var action = RundownAction(function: "Fade")
    var enabled = true

    init(event: TriggerEvent = .completion, action: RundownAction = RundownAction(function: "Fade")) {
        self.event = event
        self.action = action
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.value(.id, UUID())
        event = c.value(.event, TriggerEvent.completion)
        delayMs = c.value(.delayMs, 0)
        action = c.value(.action, RundownAction(function: "Fade"))
        enabled = c.value(.enabled, true)
    }

    /// Placeholder input value meaning "the input that owns this trigger".
    static let selfInput = "self"
}

extension SwitcherEngine {
    /// Runs the triggers of `input` for `event` (main thread). Triggers can fire other triggers, up to a small depth.
    func fireTriggers(_ input: InputSource, _ event: TriggerEvent) {
        let list = input.triggers.filter { $0.enabled && $0.event == event }
        guard !list.isEmpty else { return }
        guard triggerDepth < 4 else {
            lastMessage = Lf("트리거 반복 감지 — %@ 의 %@ 중단", input.name, event.rawValue)
            return
        }
        for t in list {
            let run = { [weak self, weak input] in
                guard let self = self, let input = input else { return }
                var q = t.action.query
                if t.action.input == InputTrigger.selfInput || t.action.input.isEmpty && Self.inputFunctions.contains(t.action.function.lowercased()) {
                    q["input"] = input.id.uuidString
                }
                self.triggerDepth += 1
                if let e = APIProcessor.perform(t.action.function, q, self) {
                    self.lastMessage = Lf("트리거 %@ → %@: %@", input.name, t.action.function, e)
                }
                self.triggerDepth -= 1
            }
            if t.delayMs > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(t.delayMs), execute: run)
            } else {
                run()
            }
        }
    }

    /// Functions that act on an input: an empty Input in a trigger means "this input".
    static let inputFunctions: Set<String> = ["play", "pause", "playpause", "restart", "audioon", "audiooff", "audio",
                                               "setvolume", "startcountdown", "stopcountdown", "pausecountdown",
                                               "nextitem", "previousitem", "selectindex", "loopon", "loopoff",
                                               "settext", "setcountdown"]
}

import Foundation

/// `sniffing <command>` controls the same system setting the menu bar app follows,
/// so the two stay in step.
@MainActor
enum CLI {
    static func run(_ args: [String]) -> Int32 {
        switch args.first {
        case "on":
            return Lid.set(disabled: true, prompt: .terminal) ? report() : 1
        case "off":
            return Lid.set(disabled: false, prompt: .terminal) ? report() : 1
        case "toggle":
            return Lid.set(disabled: !Lid.isDisabled, prompt: .terminal) ? report() : 1
        case "status":
            return report()
        case "-h", "--help", "help":
            print(usage)
            return 0
        default:
            FileHandle.standardError.write(Data("sniffing: unknown command '\(args.joined(separator: " "))'\n\(usage)\n".utf8))
            return 2
        }
    }

    private static func report() -> Int32 {
        let state = State.current
        print(state.summary)
        print("power source: \(state.onCharger ? "charger" : "battery")")
        print("stay awake: \(state.active ? "on" : "off")")
        return 0
    }

    private static let usage = """
    usage: sniffing [on|off|toggle|status]

    With no command, runs as the menu bar app.
      on      keep the Mac awake, lid closed included, while on charger
      off     restore normal sleep
      toggle  flip between the two
      status  show what closing the lid will do right now
    """
}

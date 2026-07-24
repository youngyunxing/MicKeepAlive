import Foundation

do {
    try CLICommands().run(arguments: CommandLine.arguments)
} catch {
    print("Error: \(error.localizedDescription)")
    exit(1)
}

import Foundation

// `ghosthand` developer CLI. Everything lives in GhostHandCLI.swift and the command files.
exit(await GhostHandCLI.main(arguments: Array(CommandLine.arguments.dropFirst())))

import Foundation

// `shebang` developer CLI. Everything lives in ShebangCLI.swift and the command files.
exit(await ShebangCLI.main(arguments: Array(CommandLine.arguments.dropFirst())))

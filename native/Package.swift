// swift-tools-version: 6.0
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import PackageDescription

// CMake writes the discovered header path for both builds and SourceKit-LSP.
let native = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let configuration = native.appendingPathComponent("../build/emacs-include.txt")
guard let emacsInclude = ProcessInfo.processInfo.environment["EMACS_INCLUDE"]
    ?? (try? String(contentsOf: configuration, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)) else {
    fatalError("Run cmake --preset dev or build.sh to locate emacs-module.h")
}
// libghostty-spm at the release libghostty-spm.json pins, with patches/libghostty-spm
// applied: CMake's configure step makes this copy in its build directory and names
// it here; SourceKit-LSP finds it in build/.
let libghosttySPM = ProcessInfo.processInfo.environment["PORTAL_LIBGHOSTTY_SPM"]
    ?? "../build/libghostty-spm"
guard FileManager.default.fileExists(atPath: URL(fileURLWithPath: libghosttySPM, relativeTo: native)
    .appendingPathComponent("Package.swift").path) else {
    fatalError("Run cmake --preset dev or build.sh to fetch and patch libghostty-spm")
}

let package = Package(
    name: "Portal",
    platforms: [.macOS(.v13)],
    products: [.library(name: "portal", type: .dynamic, targets: ["Portal"])],
    dependencies: [
        .package(path: libghosttySPM)
    ],
    targets: [
        // The C core: the Emacs bindings, the view registry, input, terminal and
        // web views' rules, shortcuts, Rex connections, the notification pipe, and portal.h, the
        // interface the Swift backend implements. web.c embeds the shared browser scripts in scripts/. Core/CMakeLists.txt compiles the
        // same sources into the fake-backend tests.
        .target(name: "PortalCore", path: "Core", exclude: ["CMakeLists.txt", "scripts"],
                cSettings: [.unsafeFlags(["-I", emacsInclude, "-Wall", "-Wextra", "-Werror"])]),
        // The macOS backend; all Swift features share one target.
        .target(name: "Portal", dependencies: [
            "PortalCore", .product(name: "GhosttyTerminal", package: "libghostty-spm"),
            .product(name: "GhosttyTheme", package: "libghostty-spm")
        ], path: ".", exclude: ["Core", "Info.plist"],
           sources: ["Backend.swift", "CoreCalls.swift", "NativeHost.swift", "NativeInput.swift",
                     "Views.swift", "WebView.swift", "Terminal.swift", "Launcher.swift",
                     "Hotkeys.swift", "KeyPost.swift",
                     "StatusPanel.swift", "MessageSocket.swift"],
           swiftSettings: [.unsafeFlags(["-warnings-as-errors"])])
    ]
)

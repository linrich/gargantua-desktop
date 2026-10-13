// swift-tools-version: 5.9
// Copyright (C) 2026 linrich
// SPDX-License-Identifier: GPL-3.0-only
import PackageDescription

let package = Package(
    name: "Gargantua",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "Gargantua", targets: ["Gargantua"])],
    targets: [.executableTarget(name: "Gargantua", resources: [.copy("Shaders")])]
)

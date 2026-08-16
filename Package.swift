// swift-tools-version:5.9
// Copyright 2026 EternaxCode. All rights reserved.
// SPDX-License-Identifier: Apache-2.0
import PackageDescription

let package = Package(
    name: "PhotoAgent",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "PhotoAgent",
            path: "Sources/PhotoAgent"
        )
    ]
)

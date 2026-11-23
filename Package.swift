// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "FileButler",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "FileButler", targets: ["FileButler"]),
    ],
    targets: [
        .executableTarget(
            name: "FileButler",
            path: ".",
            exclude: [
                ".github",
                "AppIcon.icns",
                "CHANGELOG.md",
                "Info.plist",
                "LICENSE",
                "README.md",
                "Tests",
                "build.sh",
                "docs",
                "icon.png",
                "icon.swift",
                "release.sh",
                "test.sh",
            ],
            sources: [
                "App.swift",
                "BatchRename.swift",
                "Bench.swift",
                "Browse.swift",
                "Controller.swift",
                "FastSearch.swift",
                "FileOps.swift",
                "FileTable.swift",
                "FolderPeek.swift",
                "IconCollection.swift",
                "Media.swift",
                "Menus.swift",
                "Model.swift",
                "Palette.swift",
                "Progress.swift",
                "Search.swift",
                "SelfTest.swift",
                "SelfTestV06.swift",
                "Settings.swift",
                "Shelf.swift",
                "SizeAnalysis.swift",
                "TabModel.swift",
                "Transfer.swift",
                "UITest.swift",
                "UITestBasics.swift",
                "UITestV06.swift",
                "UITestV061.swift",
                "Views.swift",
            ],
            swiftSettings: [
                .define("FB_TESTING"),
            ]
        ),
    ],
    swiftLanguageVersions: [.v5]
)

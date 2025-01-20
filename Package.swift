// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let name = "Operation-iOS"
let package = Package(
    name: name,
    platforms: [.iOS(.v14)],
    products: [
        // Products define the executables and libraries a package produces, making them visible to other packages.
        .library(
            name: name,
            targets: [name]),
    ],
    targets: [
        .target(
            name: name,
            path: "Operation-iOS/Classes"
        ),
        .testTarget(
            name: "CoreDataTests",
            dependencies: [
                "Operation-iOS",
                "Helpers"
            ],
            path: "Tests/CoreData"
        ),
        .testTarget(
            name: "DataProviderTests",
            dependencies: [
                "Operation-iOS",
                "Helpers"
            ],
            path: "Tests/DataProvider"
        ),
        // Operation-iOS uses FireMock which supports only Cocoapods
        // SPM NetworkTests are disabled for now
//        .testTarget(
//            name: "NetworkTests",
//            dependencies: [
//                "Operation-iOS",
//                "Helpers"
//            ],
//            path: "Tests/Network"
//        ),
        .testTarget(
            name: "OperationTests",
            dependencies: [
                "Operation-iOS",
                "Helpers"
            ],
            path: "Tests/Operation"
        ),
        .target(
            name: "Helpers",
            dependencies: [
                "Operation-iOS"
            ],
            path: "Tests/Helpers",
            exclude: ["Network"],
            resources: [
                .process("CoreData/Model/IEntities.xcdatamodeld"),
                .process("CoreData/Model/Entities.xcdatamodeld")
            ]
        )
    ]
)

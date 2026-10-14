// swift-tools-version:5.9
// Licensed to the Apache Software Foundation (ASF) under one
// or more contributor license agreements.  See the NOTICE file
// distributed with this work for additional information
// regarding copyright ownership.  The ASF licenses this file
// to you under the Apache License, Version 2.0 (the
// "License"); you may not use this file except in compliance
// with the License.  You may obtain a copy of the License at
//
//   http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing,
// software distributed under the License is distributed on an
// "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
// KIND, either express or implied.  See the License for the
// specific language governing permissions and limitations
// under the License.

import PackageDescription

let package = Package(
    name: "apple-container",
    products: [
        .executable(name: "apple-container", targets: ["apple-container"]),
    ],
    targets: [
        .target(name: "AppleContainerCore"),
        .executableTarget(name: "apple-container", dependencies: ["AppleContainerCore"]),
        // A plain executable instead of XCTest or Swift Testing, which the
        // Command Line Tools alone do not provide: swift run apple-container-tests
        .executableTarget(name: "apple-container-tests", dependencies: ["AppleContainerCore"],
                          path: "Tests/apple-container-tests"),
    ]
)

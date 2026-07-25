name: CI

on:
  push:
    branches: [ main ]

jobs:
  build-and-test:
    runs-on: ubuntu-latest
    steps:
      - name: Checkout code
        uses: actions/checkout@v3

      - name: Install dependencies
        run: |
          swift build -c release

      - name: Run tests
        run: |
          swift test

      - name: Update Info.plist
        run: |
          swift path/to/updateInfoPlist.swift

      - name: Build and install app
        run: |
          xcodebuild -project FenUITesting.xcodeproj -scheme FeniOSApp -destination 'platform=iOS Simulator,name=<any booted simulator>' build
          xcrun simctl install <simulator> ./Fen.app
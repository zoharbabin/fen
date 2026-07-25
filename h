xcodegen generate
swift path/to/updateInfoPlist.swift
xcodebuild -project FenUITesting.xcodeproj -scheme FeniOSApp -destination 'platform=iOS Simulator,name=<any booted simulator>' build
xcrun simctl install <simulator> ./Fen.app
# import necessary modules
import Foundation

# define a function to update the Info.plist file
func updateInfoPlist() {
    # load the Info.plist file
    guard let plistPath = Bundle.main.path(forResource: "Info", ofType: "plist") else {
        print("Error: Info.plist file not found")
        return
    }
    
    # load the plist file into a dictionary
    guard let plistData = try? Data(contentsOf: URL(fileURLWithPath: plistPath)),
          let plistDict = try? PropertyListSerialization.propertyList(from: plistData, options: .mutableContainers, format: nil) as? [String: Any] else {
        print("Error: Unable to load plist file")
        return
    }
    
    # update the CFBundleExecutable key
    plistDict["CFBundleExecutable"] = Bundle.main.infoDictionary?["CFBundleExecutable"] as? String
    
    # save the updated plist file
    guard let updatedPlistData = try? PropertyListSerialization.data(fromPropertyList: plistDict, format: .xml, options: 0),
          let updatedPlistPath = URL(fileURLWithPath: plistPath).deletingLastPathComponent().appendingPathComponent("Info.plist") else {
        print("Error: Unable to save updated plist file")
        return
    }
    
    try? updatedPlistData.write(to: updatedPlistPath)
    
    print("Info.plist updated successfully")
}

# call the updateInfoPlist function
updateInfoPlist()
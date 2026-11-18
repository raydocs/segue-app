import Foundation

/// Paths the menu itself may touch. The root helper directory is not one of them.
public enum SeguePaths {
    public static let tokenFileName = "control.json"

    public static func userConfigFolder(
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        home
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("Segue", isDirectory: true)
    }

    /// Helper unix socket from the macOS design. The menu connects; it does
    /// not create the socket and it does not install the helper.
    public static let helperSocketPath = "/var/run/segue/service.sock"

    /// Stage A default for a token file the caller placed in the user config
    /// folder. The production token stays in the helper runtime directory;
    /// this menu does not install a helper and does not look there.
    public static func defaultTokenFile(
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        userConfigFolder(home: home).appendingPathComponent(tokenFileName)
    }
}

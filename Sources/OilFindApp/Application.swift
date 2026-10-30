import AppKit
import OilFindCore

public enum Application {
    public static func run(appExtension: ApplicationExtension? = nil, arguments: [String] = Array(CommandLine.arguments.dropFirst())) {
    if let status = appExtension?.handleLaunch(arguments: arguments) { exit(status) }
#if DEBUG
    var arguments = arguments
    if arguments.contains("--snapshot") {
        let externalDrives = ExternalDriveCatalog()
        do { try externalDrives.prepareArguments(&arguments); try appExtension?.prepareArguments(&arguments) }
        catch { fputs("Oil Find arguments: \(error)\n", stderr); exit(1) }
        appExtension?.attachExternalDrives(externalDrives)
        do { try Snapshot.run(arguments, appExtension: appExtension, externalDrives: externalDrives); exit(0) }
        catch { fputs("Oil Find snapshot: \(error)\n", stderr); exit(1) }
    }
    if UpdateExercise.handles(arguments) {
        do { try UpdateExercise.start(arguments); NSApplication.shared.run(); exit(0) }
        catch { fputs("Oil Find update exercise: \(error)\n", stderr); exit(1) }
    }
    fputs("Oil Find: Debug builds only support --snapshot and controlled test probes; background indexing is disabled.\n", stderr)
    exit(2)
#else
    let externalDrives = ExternalDriveCatalog()
    SystemUpdateFiles().registerLaunch(application: Bundle.main.bundleURL, current: UpdateManager.current)
    let app = NSApplication.shared
    SettingsPreferences.register()
    let delegate = AppDelegate(appExtension: appExtension, externalDrives: externalDrives)
    app.delegate = delegate
    app.run()
#endif
    }
}

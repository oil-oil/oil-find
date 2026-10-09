import AppKit
import OilFindCore

public enum Application {
    public static func run(appExtension: ApplicationExtension? = nil, arguments: [String] = Array(CommandLine.arguments.dropFirst())) {
#if DEBUG
    var arguments = arguments
    do { try appExtension?.prepareArguments(&arguments) }
    catch { fputs("Oil Find arguments: \(error)\n", stderr); exit(1) }
    if arguments.contains("--snapshot") {
        do { try Snapshot.run(arguments, appExtension: appExtension); exit(0) }
        catch { fputs("Oil Find snapshot: \(error)\n", stderr); exit(1) }
    }
    if UpdateExercise.handles(arguments) {
        do { try UpdateExercise.start(arguments); NSApplication.shared.run(); exit(0) }
        catch { fputs("Oil Find update exercise: \(error)\n", stderr); exit(1) }
    }
#endif
    SystemUpdateFiles().registerLaunch(application: Bundle.main.bundleURL, current: UpdateManager.current)
    let app = NSApplication.shared
    SettingsPreferences.register()
    let delegate = AppDelegate(appExtension: appExtension)
    app.delegate = delegate
    app.run()
    }
}

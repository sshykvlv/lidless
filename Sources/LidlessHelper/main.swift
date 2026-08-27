import Foundation
import LidlessCore

private let engine = HelperEngine(
  pmset: FixedPMSetController(runner: ProcessCommandRunner()),
  journal: AtomicJournalStore()
)
guard
  let buildVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
    as? String,
  (try? SemanticVersion(buildVersion)) != nil
else {
  fatalError("Lidless background service has no valid build version")
}
private let runtime = HelperRuntime(engine: engine, buildVersion: buildVersion)
runtime.start()

private let listenerDelegate = HelperListenerDelegate(runtime: runtime)
private let listener = NSXPCListener(machServiceName: "lv.ykv.lidless.helper")
listener.delegate = listenerDelegate
listener.resume()
RunLoop.current.run()

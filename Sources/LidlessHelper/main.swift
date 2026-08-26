import Foundation
import LidlessCore

private let engine = HelperEngine(
  pmset: FixedPMSetController(runner: ProcessCommandRunner()),
  journal: AtomicJournalStore()
)
private let runtime = HelperRuntime(engine: engine)
runtime.start()

private let listenerDelegate = HelperListenerDelegate(runtime: runtime)
private let listener = NSXPCListener(machServiceName: "lv.ykv.lidless.helper")
listener.delegate = listenerDelegate
listener.resume()
RunLoop.current.run()

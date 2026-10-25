import AppKit
import IOKit.pwr_mgt
import IOKit

@MainActor final class PowerCoordinator {
    private weak var library:MonitorLibrary?
    private var port:IONotificationPortRef?
    private var root:io_connect_t = 0
    private var notifier:io_object_t = 0
    private var wakeObserver:NSObjectProtocol?
    init(library:MonitorLibrary) {
        self.library=library
        let context=Unmanaged.passUnretained(self).toOpaque()
        root=IORegisterForSystemPower(context,&port,{ context,_,type,argument in
            guard let context else { return }
            let power=Unmanaged<PowerCoordinator>.fromOpaque(context).takeUnretainedValue()
            let message=Int(bitPattern:argument)
            Task { @MainActor in power.handle(type,message:message) }
        },&notifier)
        if let port,let source=IONotificationPortGetRunLoopSource(port)?.takeUnretainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(),source,.commonModes)
        }
        wakeObserver=NSWorkspace.shared.notificationCenter.addObserver(forName:NSWorkspace.didWakeNotification,object:nil,queue:.main) { [weak self] _ in
            Task { @MainActor in self?.library?.didWake() }
        }
    }
    private func handle(_ type:UInt32,message:Int) {
        if type == BSSystemCanSleepMessage() { IOAllowPowerChange(root,message) }
        else if type == BSSystemWillSleepMessage() {
            let root=root
            Task { @MainActor in
                var acknowledged=false
                func allow() { if !acknowledged { acknowledged=true;IOAllowPowerChange(root,message) } }
                // Never hold up system sleep indefinitely if a device is unreachable.
                Task { @MainActor in try? await Task.sleep(nanoseconds:3_000_000_000);allow() }
                await library?.prepareForSleep()
                allow()
            }
        }
    }
    deinit {
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        if let port {
            if let source=IONotificationPortGetRunLoopSource(port)?.takeUnretainedValue() { CFRunLoopRemoveSource(CFRunLoopGetMain(),source,.commonModes) }
            IODeregisterForSystemPower(&notifier)
            if root != 0 { IOServiceClose(root) }
            IONotificationPortDestroy(port)
        }
    }
}

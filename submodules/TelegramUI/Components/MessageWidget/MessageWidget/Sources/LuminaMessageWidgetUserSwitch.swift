import Foundation

/// LuminaGram: the user's own switch for message widgets (LuminaGram > Privacy > "Turn Off Message Widgets",
/// `LuminaSettings.disableMessageWidgets`). Message widgets run sandboxed JavaScript that a bot puts in a message;
/// upstream renders them for everyone and only the server can switch them off (`MessageWidgetKillSwitch`). This is the
/// client-side "off" next to it: while set, `chatMessageWidgetRenderingEnabled()` answers false, so widget messages
/// show the way they do under the kill switch (unsupported media with its caption) and no widget runtime starts.
///
/// The host app mirrors the setting into it (SharedAccountContext), so bubble layout keeps reading one flag on any
/// thread, as it does for the kill switch. Off until told otherwise = upstream behaviour. A flip posts
/// `MessageWidgetAvailability`'s change, so a widget already running in an open chat stops at once (and comes back
/// when switched on again).
public enum LuminaMessageWidgetUserSwitch {
    private static let lock = NSLock()
    private static var disabled = false

    public static var isDisabled: Bool {
        get {
            self.lock.lock()
            defer {
                self.lock.unlock()
            }
            return self.disabled
        }
        set {
            self.lock.lock()
            let changed = self.disabled != newValue
            self.disabled = newValue
            self.lock.unlock()
            if changed {
                MessageWidgetAvailability.noteChange()
            }
        }
    }
}

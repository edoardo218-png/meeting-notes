import SwiftUI

/// Nell'SDK di macOS 27 `@State` è una macro il cui plugin c'è solo in Xcode completo:
/// con i soli Command Line Tools usiamo direttamente il property wrapper tramite questo alias.
typealias ViewState<Value> = SwiftUI.State<Value>

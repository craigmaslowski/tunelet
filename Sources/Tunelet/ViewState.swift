import SwiftUI

/// SwiftUI's `State` property wrapper, used as `@ViewState` instead of `@State`.
///
/// In the macOS 26 SDK, writing `@State` resolves to a macro whose implementation
/// (SwiftUIMacros) ships only with Xcode. With just the Command Line Tools the build fails with
/// "plugin for module 'SwiftUIMacros' not found". Naming the property wrapper through a
/// typealias skips the macro lookup and uses the wrapper directly.
typealias ViewState = SwiftUI.State

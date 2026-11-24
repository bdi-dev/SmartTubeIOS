import SwiftUI

// MARK: - SettingsPicker
//
// A Picker for the Settings screen. On iOS and macOS it is a plain `Picker`. On tvOS the
// system's navigation-link Picker pushes a page whose list is empty (accessibility shows
// "Empty list") when used inside this Form, so tvOS gets an explicit NavigationLink to a list
// of Buttons with a checkmark on the current value. The row still shows the title and the
// current value, and selecting an option writes the binding and pops back.

struct SettingsPickerOption<Value: Hashable>: Identifiable {
    let title: String
    let value: Value
    var icon: Image? = nil
    /// Draws a divider above this option in the native (iOS/macOS) menu.
    var separatorBefore = false

    var id: Value { value }
}

struct SettingsPicker<Value: Hashable>: View {
    let title: LocalizedStringKey
    @Binding var selection: Value
    let options: [SettingsPickerOption<Value>]

    init(_ title: LocalizedStringKey, selection: Binding<Value>, options: [SettingsPickerOption<Value>]) {
        self.title = title
        self._selection = selection
        self.options = options
    }

    private var currentTitle: String {
        options.first { $0.value == selection }?.title ?? ""
    }

    #if os(tvOS)
    var body: some View {
        NavigationLink {
            SettingsPickerPage(title: title, selection: $selection, options: options)
        } label: {
            LabeledContent(title, value: currentTitle)
        }
    }
    #else
    var body: some View {
        Picker(title, selection: $selection) {
            ForEach(options) { option in
                if option.separatorBefore { Divider() }
                if let icon = option.icon {
                    Label {
                        Text(option.title)
                    } icon: {
                        icon
                    }.tag(option.value)
                } else {
                    Text(option.title).tag(option.value)
                }
            }
        }
    }
    #endif
}

#if os(tvOS)
private struct SettingsPickerPage<Value: Hashable>: View {
    let title: LocalizedStringKey
    @Binding var selection: Value
    let options: [SettingsPickerOption<Value>]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            Section {
                ForEach(options) { option in
                    Button {
                        selection = option.value
                        dismiss()
                    } label: {
                        HStack {
                            if let icon = option.icon { icon }
                            Text(option.title)
                            Spacer()
                            if option.value == selection {
                                Image(systemName: "checkmark")
                                    .accessibilityIdentifier("settings.picker.checkmark")
                            }
                        }
                    }
                    .accessibilityIdentifier("settings.picker.option")
                    .accessibilityLabel(Text(option.title))
                    .accessibilityAddTraits(option.value == selection ? [.isSelected] : [])
                }
            } header: {
                Text(title)
            }
        }
    }
}
#endif

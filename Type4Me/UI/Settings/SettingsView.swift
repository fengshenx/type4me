import SwiftUI
import AppKit

// MARK: - Navigation Item

enum SettingsTab: String, CaseIterable, Identifiable {
    case general
    case vocabulary
    case modes
    case history
    case about

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .general:     return L("通用", "General")
        case .vocabulary:  return L("词汇", "Vocabulary")
        case .modes:       return L("模式", "Modes")
        case .history:     return L("历史", "History")
        case .about:       return L("关于", "About")
        }
    }

    var subtitle: String {
        switch self {
        case .general:    return L("快捷键与接口配置", "Hotkeys & API config")
        case .vocabulary:  return L("热词与片段替换", "Hotwords & snippets")
        case .modes:       return L("推理与默认行为", "Processing & defaults")
        case .history:     return L("会话与日志保留", "Sessions & logs")
        case .about:       return L("版本、许可证与支持", "Version, license & support")
        }
    }
}

// MARK: - Settings View

struct SettingsView: View {

    @Environment(AppState.self) private var appState
    @State private var selectedTab: SettingsTab = .general
    @AppStorage("tf_language") private var language = AppLanguage.systemDefault

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            content
        }
        .id(language)
        .frame(minWidth: 700, minHeight: 480)
        .background(TF.settingsBg)
        .preferredColorScheme(.light)
        .onReceive(NotificationCenter.default.publisher(for: .navigateToMode)) { note in
            selectedTab = .modes
            if let modeId = note.object as? UUID {
                NotificationCenter.default.post(name: .selectMode, object: modeId)
            }
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Brand
            VStack(alignment: .leading, spacing: 2) {
                Text("TYPE4ME")
                    .font(.system(size: 11, weight: .bold))
                    .tracking(2)
                    .foregroundStyle(TF.settingsTextTertiary)
                Text(L("偏好设置", "Preferences"))
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(TF.settingsText)
            }
            .padding(.horizontal, 16)
            .padding(.top, 20)
            .padding(.bottom, 16)

            // Nav items
            VStack(spacing: 2) {
                ForEach(SettingsTab.allCases) { tab in
                    navItem(tab)
                }
            }
            .padding(.horizontal, 10)

            Spacer()
        }
        .frame(width: 180)
        .background(TF.settingsBg)
    }

    private func navItem(_ tab: SettingsTab) -> some View {
        let isActive = selectedTab == tab
        let showBadge = tab == .about && appState.hasUnseenUpdate
        return Button {
            selectedTab = tab
            if tab == .about {
                UpdateChecker.shared.markAsSeen(appState: appState)
            }
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(tab.displayName)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(isActive ? .white : TF.settingsText)
                    Text(tab.subtitle)
                        .font(.system(size: 10))
                        .foregroundStyle(isActive ? .white.opacity(0.7) : TF.settingsTextTertiary)
                }
                Spacer()
                if showBadge {
                    Circle()
                        .fill(.red)
                        .frame(width: 7, height: 7)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isActive ? TF.settingsNavActive : .clear)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Content

    private var content: some View {
        SettingsContentHost(selectedTab: selectedTab)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(TF.settingsCard)
    }
}

private struct SettingsContentHost: NSViewControllerRepresentable {
    let selectedTab: SettingsTab

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSViewController(context: Context) -> NSViewController {
        let controller = NSViewController()
        controller.view = NSView()
        return controller
    }

    func updateNSViewController(_ nsViewController: NSViewController, context: Context) {
        let hostingController = context.coordinator.hostingController(
            for: selectedTab,
            rootView: rootView(for: selectedTab, selectedTab: selectedTab)
        )

        if context.coordinator.activeTab != selectedTab {
            context.coordinator.activeController?.view.removeFromSuperview()

            if hostingController.parent !== nsViewController {
                nsViewController.addChild(hostingController)
            }

            hostingController.view.frame = nsViewController.view.bounds
            hostingController.view.autoresizingMask = [.width, .height]
            nsViewController.view.addSubview(hostingController.view)
            context.coordinator.activeTab = selectedTab
        } else {
            hostingController.view.frame = nsViewController.view.bounds
        }
    }

    private func rootView(for tab: SettingsTab, selectedTab: SettingsTab) -> AnyView {
        switch tab {
        case .general:
            return AnyView(
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        GeneralSettingsTab()
                    }
                    .padding(28)
                }
            )
        case .vocabulary:
            return AnyView(
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        VocabularyTab()
                    }
                    .padding(28)
                }
            )
        case .modes:
            return AnyView(
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ModesSettingsTab()
                    }
                    .padding(28)
                }
            )
        case .history:
            return AnyView(
                VStack(alignment: .leading, spacing: 0) {
                    HistoryTab(isActive: selectedTab == .history)
                }
                .padding(28)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            )
        case .about:
            return AnyView(
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        AboutTab()
                    }
                    .padding(28)
                }
            )
        }
    }

    final class Coordinator {
        private var controllers: [SettingsTab: NSHostingController<AnyView>] = [:]
        var activeTab: SettingsTab?

        var activeController: NSHostingController<AnyView>? {
            guard let activeTab else { return nil }
            return controllers[activeTab]
        }

        func hostingController(for tab: SettingsTab, rootView: AnyView) -> NSHostingController<AnyView> {
            if let controller = controllers[tab] {
                controller.rootView = rootView
                return controller
            }

            let controller = NSHostingController(rootView: rootView)
            controllers[tab] = controller
            return controller
        }
    }
}

// MARK: - Reusable Components

struct SettingsSectionHeader: View {
    let label: String
    let title: String
    let description: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .tracking(1.2)
                .foregroundStyle(TF.settingsTextTertiary)
            Text(title)
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(TF.settingsText)
            Text(description)
                .font(.system(size: 12))
                .foregroundStyle(TF.settingsTextTertiary)
                .lineSpacing(2)
        }
        .padding(.bottom, 16)
    }
}

struct SettingsRow: View {
    let label: String
    let value: String
    var statusColor: Color? = nil

    var body: some View {
        HStack {
            Text(label)
                .font(.system(size: 13))
                .foregroundStyle(TF.settingsText)
            Spacer()
            Text(value)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(statusColor ?? TF.settingsTextSecondary)
        }
        .padding(.vertical, 10)
    }
}

struct SettingsDivider: View {
    var body: some View {
        Divider().padding(.vertical, 2)
    }
}

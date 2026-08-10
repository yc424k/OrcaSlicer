import Foundation

/// The desktop settings-tab layout (pages → groups → option keys), extracted
/// from Tab.cpp by scripts/extract_settings_layout.py so the app shows the
/// same tabs, group titles, icons and ordering as OrcaSlicer.
struct SettingsLayout: Decodable {
    struct Group: Decodable, Identifiable {
        let title: String
        let icon: String
        let keys: [String]
        var id: String { title }
    }

    struct Page: Decodable, Identifiable {
        let title: String
        let groups: [Group]
        var id: String { title }
    }

    /// Pages per config tab ("process" | "filament" | "printer").
    let tabs: [String: [Page]]

    static let shared: SettingsLayout = {
        guard let url = Bundle.main.url(forResource: "settings_layout", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let tabs = try? JSONDecoder().decode([String: [Page]].self, from: data) else {
            return SettingsLayout(tabs: [:])
        }
        return SettingsLayout(tabs: tabs)
    }()

    func pages(for tab: String) -> [Page] { tabs[tab] ?? [] }
}

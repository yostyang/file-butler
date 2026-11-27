import Foundation
import CoreGraphics

/// 集中管理应用的持久化设置（UserDefaults），统一键名与默认值，避免各处散落字符串字面量。
enum Settings {
    private static var ud: UserDefaults { .standard }

    enum Key {
        static let dual = "dual"
        static let showHidden = "showHidden"
        static let showInfo = "showInfo"
        static let showPathBar = "showPathBar"
        static let iconSize = "iconSize"
        static let fdaPromptDismissed = "fdaPromptDismissed"
        static let sortKey = "sortKey"
        static let sortAsc = "sortAsc"
        static let bookmarks = "bookmarks"
        static let recents = "recents"
        static let recentSearches = "recentSearches"
        static let customTags = "customTags"
        static let savedSearches = "savedSearches"
        static let pinnedFolders = "pinnedFolders"
        static let savedLayouts = "savedLayouts"
        static let listColumns = "listColumns"
        static let shelfItems = "shelfItems"
        static func paneTabs(_ i: Int) -> String { "pane\(i)Tabs" }
        static func paneModes(_ i: Int) -> String { "pane\(i)Modes" }
        static func paneCur(_ i: Int) -> String { "pane\(i)Cur" }
        static func listColWidth(_ id: String) -> String { "listColW_\(id)" }
    }

    static var dual: Bool {
        get { ud.object(forKey: Key.dual) as? Bool ?? true }
        set { ud.set(newValue, forKey: Key.dual) }
    }
    static var showHidden: Bool {
        get { ud.bool(forKey: Key.showHidden) }
        set { ud.set(newValue, forKey: Key.showHidden) }
    }
    static var showPreview: Bool {
        get { ud.bool(forKey: Key.showInfo) }
        set { ud.set(newValue, forKey: Key.showInfo) }
    }
    static var showPathBar: Bool {
        get { ud.object(forKey: Key.showPathBar) as? Bool ?? true }
        set { ud.set(newValue, forKey: Key.showPathBar) }
    }
    static var iconSize: Double {
        get { ud.object(forKey: Key.iconSize) as? Double ?? 80 }
        set { ud.set(newValue, forKey: Key.iconSize) }
    }
    static var fdaPromptDismissed: Bool {
        get { ud.bool(forKey: Key.fdaPromptDismissed) }
        set { ud.set(newValue, forKey: Key.fdaPromptDismissed) }
    }
    static var defaultSortKey: SortKey {
        get { SortKey(rawValue: ud.string(forKey: Key.sortKey) ?? "") ?? .name }
        set { ud.set(newValue.rawValue, forKey: Key.sortKey) }
    }
    static var defaultSortAsc: Bool {
        get { ud.object(forKey: Key.sortAsc) as? Bool ?? true }
        set { ud.set(newValue, forKey: Key.sortAsc) }
    }
    static var bookmarks: [URL] {
        get { (ud.stringArray(forKey: Key.bookmarks) ?? []).map { URL(fileURLWithPath: $0) } }
        set { ud.set(newValue.map { $0.path }, forKey: Key.bookmarks) }
    }
    static var recents: [URL] {
        get { (ud.stringArray(forKey: Key.recents) ?? []).map { URL(fileURLWithPath: $0) } }
        set { ud.set(newValue.map { $0.path }, forKey: Key.recents) }
    }
    static var recentSearches: [String] {
        get { ud.stringArray(forKey: Key.recentSearches) ?? [] }
        set {
            if newValue.isEmpty { ud.removeObject(forKey: Key.recentSearches) }
            else { ud.set(newValue, forKey: Key.recentSearches) }
        }
    }
    static var customTags: [String] {
        get { ud.stringArray(forKey: Key.customTags) ?? [] }
        set { ud.set(newValue, forKey: Key.customTags) }
    }
    static var savedSearches: [SavedSearch] {
        get {
            guard let d = ud.data(forKey: Key.savedSearches) else { return [] }
            return (try? JSONDecoder().decode([SavedSearch].self, from: d)) ?? []
        }
        set { ud.set(try? JSONEncoder().encode(newValue), forKey: Key.savedSearches) }
    }
    static var pinnedFolders: [PinnedFolder] {
        get {
            guard let d = ud.data(forKey: Key.pinnedFolders) else { return [] }
            return (try? JSONDecoder().decode([PinnedFolder].self, from: d)) ?? []
        }
        set { ud.set(try? JSONEncoder().encode(newValue), forKey: Key.pinnedFolders) }
    }
    static var savedLayouts: [WorkspaceLayout] {
        get {
            guard let d = ud.data(forKey: Key.savedLayouts) else { return [] }
            return (try? JSONDecoder().decode([WorkspaceLayout].self, from: d)) ?? []
        }
        set { ud.set(try? JSONEncoder().encode(newValue), forKey: Key.savedLayouts) }
    }
    static func loadPane(_ i: Int) -> (paths: [String], modes: [String], current: Int) {
        (ud.stringArray(forKey: Key.paneTabs(i)) ?? [],
         ud.stringArray(forKey: Key.paneModes(i)) ?? [],
         ud.integer(forKey: Key.paneCur(i)))
    }
    static func savePane(_ i: Int, tabs: [TabModel], current: Int) {
        ud.set(tabs.map { $0.path.path }, forKey: Key.paneTabs(i))
        ud.set(tabs.map { $0.viewMode.rawValue }, forKey: Key.paneModes(i))
        ud.set(current, forKey: Key.paneCur(i))
    }
    static var listColumns: Set<String> {
        get { Set(ud.stringArray(forKey: Key.listColumns) ?? ["date", "size", "kind"]) }
        set { ud.set(Array(newValue), forKey: Key.listColumns) }
    }
    static func columnWidth(_ id: String, default def: CGFloat) -> CGFloat {
        let w = ud.double(forKey: Key.listColWidth(id))
        return w > 30 ? CGFloat(w) : def
    }
    static func setColumnWidth(_ id: String, _ w: CGFloat) {
        ud.set(Double(w), forKey: Key.listColWidth(id))
    }
    static func resetColumnWidths(ids: [String]) {
        for id in ids { ud.removeObject(forKey: Key.listColWidth(id)) }
        ud.removeObject(forKey: Key.listColWidth("path"))
    }
    static func stringList(forKey key: String) -> [String] {
        ud.stringArray(forKey: key) ?? []
    }
    static func setStringList(_ list: [String], forKey key: String) {
        ud.set(list, forKey: key)
    }
}

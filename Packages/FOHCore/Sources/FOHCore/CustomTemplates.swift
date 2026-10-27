import Foundation

/// A binding template saved from a hand-tuned strip ("Save as template"). Matches plugins by component first,
/// then by name, and wins over the built-in templates (PLAN.md §5).
public struct CustomTemplate: Codable, Hashable, Sendable, Identifiable {
    public enum Use: String, Codable, Sendable {
        /// Drives EQ / Dynamics / Trim roles.
        case processing
        /// Labels an insert page's macros (rule keys "macro.1"…"macro.8").
        case insert
    }

    public struct Rule: Codable, Hashable, Sendable {
        public var parameterID: String
        public var invert: Bool

        public init(parameterID: String, invert: Bool = false) {
            self.parameterID = parameterID
            self.invert = invert
        }
    }

    public var id: String
    public var name: String
    public var component: AUComponentID?
    public var pluginName: String
    public var use: Use
    /// Processing: role id → rule. Insert: "macro.N" → rule.
    public var rules: [String: Rule]
    /// Roles the plugin doesn't have (hidden on the pages).
    public var hidden: [String]

    public init(id: String = UUID().uuidString, name: String, component: AUComponentID?, pluginName: String, use: Use,
                rules: [String: Rule], hidden: [String] = []) {
        self.id = id
        self.name = name
        self.component = component
        self.pluginName = pluginName
        self.use = use
        self.rules = rules
        self.hidden = hidden
    }

    public func matches(_ plugin: PluginDescription) -> Bool {
        if let component { return component == plugin.component }
        return BindingTemplate.normalize(pluginName) == BindingTemplate.normalize(plugin.name)
    }

    /// Capture a strip's current bindings for the plugin at `position` as a template.
    public static func capture(name: String, strip: Strip, binding: StripBinding, position: Int, use: Use) -> CustomTemplate? {
        guard let plugin = strip.plugin(at: position) else { return nil }
        var rules: [String: Rule] = [:]
        for b in binding.roles.values where b.pluginPosition == position && !b.parameterID.hasPrefix("@") {
            switch use {
            case .processing:
                guard [.mix, .eq, .band, .dyn, .comp, .gate].contains(b.role.group) else { continue }
                rules[b.role.id] = Rule(parameterID: b.parameterID, invert: b.invert)
            case .insert:
                let parts = b.role.id.split(separator: ".")   // ins.<page>.macro.<n>
                guard parts.count == 4, parts[2] == "macro" else { continue }
                rules["macro.\(parts[3])"] = Rule(parameterID: b.parameterID, invert: b.invert)
            }
        }
        guard !rules.isEmpty else { return nil }
        return CustomTemplate(name: name, component: plugin.component, pluginName: plugin.name, use: use, rules: rules,
                              hidden: use == .processing ? binding.notInPlugin : [])
    }

    func binding(_ role: Role, _ rule: Rule, plugin: PluginDescription, position: Int) -> RoleBinding? {
        guard let p = plugin.parameter(id: rule.parameterID) else { return nil }
        var kind = p.kind
        if role.kind == .toggle, case .stepped(2) = kind { kind = .toggle }
        return RoleBinding(role: role, pluginPosition: position, pluginName: plugin.name, parameterID: p.id, parameterName: p.name,
                           unitName: p.unitName, kind: kind, steps: rule.invert ? p.steps.reversed() : p.steps,
                           invert: rule.invert, origin: .auto)
    }

    /// Processing roles in `groups`, plus the template's hidden roles in those groups.
    func bindProcessing(_ plugin: PluginDescription, position: Int, groups: Set<Role.Group>) -> (bound: [RoleBinding], hidden: [String]) {
        var bound: [RoleBinding] = []
        for (roleID, rule) in rules.sorted(by: { $0.key < $1.key }) {
            guard let role = Role.byID[roleID], groups.contains(role.group),
                  let b = binding(role, rule, plugin: plugin, position: position) else { continue }
            bound.append(b)
        }
        let hiddenHere = hidden.filter { Role.byID[$0].map { groups.contains($0.group) } ?? false }
        return (bound, hiddenHere)
    }

    func bindInsert(_ plugin: PluginDescription, position: Int, page: Int) -> [RoleBinding] {
        var out: [RoleBinding] = []
        for (key, rule) in rules.sorted(by: { $0.key < $1.key }) {
            guard key.hasPrefix("macro."), let n = Int(key.dropFirst(6)), let role = Role.insertMacro(page, n),
                  let b = binding(role, rule, plugin: plugin, position: position) else { continue }
            out.append(b)
        }
        if let bypass = Role.insertBypass(page) {
            out.append(ChannelStripParameter.pluginBypass(position).binding(bypass, pluginName: plugin.name, position: position))
        }
        return out
    }
}

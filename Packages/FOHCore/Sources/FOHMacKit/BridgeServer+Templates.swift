#if os(macOS)
import Foundation
import FOHCore

// Custom templates ("Save as template" in Setup › Processing): a hand-tuned strip's bindings for one plugin,
// applied to every strip with that plugin. They beat the built-in templates; manual overrides still win.
extension BridgeServer {
    /// `/foh/template/save`.
    @discardableResult
    public func saveTemplate(strip key: String, name: String, use: CustomTemplate.Use, position: Int) -> BridgeAck {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return .fail("Give the template a name") }
        guard let ref = StripRef(key: key), let strip = show.strip(ref) else { return .fail("Unknown strip \(key)") }
        guard let template = CustomTemplate.capture(name: trimmed, strip: strip, binding: show.binding(ref), position: position, use: use) else {
            return .fail("\(strip.name) has nothing bound to plugin \(position) for the \(use.rawValue) pages")
        }
        let replacing = show.customTemplates.contains { $0.name == trimmed }
        show.customTemplates.removeAll { $0.name == trimmed }
        show.customTemplates.append(template)
        rebuildAllBindings()
        let using = stripsUsing(template)
        log("Template '\(trimmed)' \(replacing ? "replaced" : "saved") from \(strip.name) (\(template.rules.count) rules) — applies to \(using.map(\.name).joined(separator: ", "))")
        commitBindingChange()
        return .ok("Template '\(trimmed)' saved — applied to \(using.count) strip\(using.count == 1 ? "" : "s")")
    }

    /// `/foh/template/delete`.
    @discardableResult
    public func deleteTemplate(id: String) -> BridgeAck {
        guard let template = show.customTemplates.first(where: { $0.id == id }) else { return .fail("No template \(id)") }
        let using = stripsUsing(template)
        show.customTemplates.removeAll { $0.id == id }
        rebuildAllBindings()
        log("Template '\(template.name)' deleted; \(using.count) strip(s) back on the built-in templates")
        commitBindingChange()
        return .ok("Template '\(template.name)' deleted")
    }

    func rebuildAllBindings() {
        for strip in show.strips { rebuildBinding(strip) }
    }

    /// Strips whose discovered plugins this template now drives (processing positions or insert pages).
    public func stripsUsing(_ template: CustomTemplate) -> [Strip] {
        show.strips.filter { strip in
            let found = discovered[strip.ref.key] ?? [:]
            let positions: [Int]
            switch template.use {
            case .processing: positions = [strip.processing.eq, strip.processing.dynamics, strip.processing.trim].compactMap { $0 }
            case .insert: positions = Array(strip.processing.insertPages.values)
            }
            return positions.contains { found[$0].map(template.matches) ?? false }
        }
    }
}
#endif

import Foundation

/// Bounded property selection; no DTD, external entities or arbitrary XML expansion.
final class FinderProperties: NSObject, XMLParserDelegate {
    private struct Property { let namespace: String; let name: String }
    private static let known = ["displayname", "resourcetype", "getcontentlength", "getlastmodified", "getcontenttype", "supportedlock", "lockdiscovery"]
    private var selected: [Property] = []
    private var stack: [String] = []
    private var mode = "allprop"
    private var invalid = false
    private var rootSeen = false
    private var selectionSeen = false
    private var includeSeen = false
    static func parse(_ body: Data) throws -> FinderProperties {
        let result = FinderProperties()
        if body.isEmpty { return result }
        guard let decoded = String(data: body, encoding: .utf8) else { throw FinderFailure(400, "PROPFIND requires UTF-8") }
        let text = decoded.uppercased()
        guard !text.contains("<!DOCTYPE"), !text.contains("<!ENTITY") else { throw FinderFailure(400, "XML declarations refused") }
        let parser = XMLParser(data: body)
        parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = false
        parser.delegate = result
        guard parser.parse(), !result.invalid, result.stack.isEmpty, result.rootSeen, result.selectionSeen else { throw FinderFailure(400, "invalid PROPFIND XML") }
        return result
    }
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String]) {
        stack.append(elementName)
        if stack.count == 1 {
            if rootSeen || elementName != "propfind" || namespaceURI != "DAV:" { invalid = true }
            rootSeen = true
        } else if stack.count == 2 {
            if namespaceURI != "DAV:" || !["prop", "allprop", "propname", "include"].contains(elementName) { invalid = true }
            if elementName == "include" {
                if !selectionSeen || mode != "allprop" || includeSeen { invalid = true }
                includeSeen = true
            } else {
                if selectionSeen { invalid = true }
                selectionSeen = true
                mode = elementName
            }
        } else if stack.count == 3, stack[1] == "prop" || stack[1] == "include" {
            selected.append(Property(namespace: namespaceURI ?? "", name: elementName))
            if selected.count > 64 { invalid = true }
        } else { invalid = true }
        if invalid { parser.abortParsing() }
    }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) { _ = stack.popLast() }
    func response(_ node: FinderNode, path: String) -> String {
        var properties = selected
        if mode != "prop" { properties = Self.known.map { Property(namespace: "DAV:", name: $0) } + selected }
        var good = "", missing = ""
        for property in properties {
            let known = property.namespace == "DAV:" && Self.known.contains(property.name)
            let tag = property.namespace.isEmpty ? property.name : "P:\(property.name)"
            let namespace = property.namespace.isEmpty ? "" : " xmlns:P=\"\(FinderHTTP.escape(property.namespace))\""
            var value = ""
            if mode != "propname", known {
                switch property.name {
                case "displayname": value = FinderHTTP.escape(node.name)
                case "resourcetype": value = node.isDirectory ? "<D:collection/>" : ""
                case "getcontentlength": value = String(node.isDirectory ? 0 : node.size)
                case "getlastmodified": value = FinderHTTP.httpDate(node.mtime)
                case "getcontenttype": value = node.isDirectory ? "httpd/unix-directory" : "application/octet-stream"
                default: break
                }
            }
            let xml = "<\(tag)\(namespace)>\(value)</\(tag)>"
            if known { good += xml } else { missing += xml }
        }
        var xml = "<D:response><D:href>\(FinderHTTP.escape(path))</D:href>"
        if !good.isEmpty { xml += "<D:propstat><D:prop>\(good)</D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat>" }
        if !missing.isEmpty { xml += "<D:propstat><D:prop>\(missing)</D:prop><D:status>HTTP/1.1 404 Not Found</D:status></D:propstat>" }
        return xml + "</D:response>"
    }
}

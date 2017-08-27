/import Stencil
import HTMLEntities

open class AutoescapeNode: NodeType {
    var nodesToEscape: [NodeType]

    public init(nodes: [NodeType]) {
        nodesToEscape = nodes
    }

    open func render(_ context: Context) throws -> String {
        let content = try renderNodes(nodesToEscape, context)
        return content.htmlEscape()
    }

    class func parse(_ parser: TokenParser, token: Token) throws -> NodeType {
        // find all the nodes inside our escape nodes
        let nodes = try parser.parse(until(["endautoescape"]))

        // attempt to read the final token
        guard let _ = parser.nextToken() else {
            // there wasn't one - we reached the end
            throw TemplateSyntaxError("`endautoescape` was not found.")
        }

        return AutoescapeNode(nodes: nodes)
    }
}

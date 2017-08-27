import HeliumLogger
import Kitura
import KituraStencil
import Stencil

HeliumLogger.use()

let router = Router()
let ext = Extension()

ext.registerFilter("autoescape") { (value: Any?) in
    guard let unwrapped = value as? String else { return value }
    return unwrapped
}

ext.registerFilter("reverse") { (value: Any?) in
    guard let unwrapped = value as? String else { return value }
    return String(unwrapped.characters.reversed())
}

ext.registerSimpleTag("debug") { context in
    return String(describing: context.flatten())
}

ext.registerTag("autoescape", parser: AutoescapeNode.parse)

router.setDefault(templateEngine: StencilTemplateEngine(extension: ext))

router.get("/") {
    request, response, next in
    defer { next() }

    let haters = "hating"
    let names = ["Taylor", "Paul", "Justin", "Adele"]
    let hamsters = [String]()
    let quote = "He thrusts his fists against the posts and still insists he sees the ghosts"

    let context: [String: Any] = ["haters": haters, "names": names, "hamsters": hamsters, "quote": quote]
    try response.render("home", context: context)
}

Kitura.addHTTPServer(onPort: 8090, with: router)
Kitura.run()

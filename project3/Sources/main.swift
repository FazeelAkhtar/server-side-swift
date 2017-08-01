import HeliumLogger
import Kitura

HeliumLogger.use()
let router = Router()

router.post("/messages/create", middleware: BodyParser())

router.post("/messages/create") {
  request, response, next in

  guard let values = request.body else {
    try response.status(.badRequest).end()
    return
  }

  guard case .json(let body) = values else {
    try response.status(.badRequest).end()
    return
  }

  if let title = body["title"].string {
    response.send("Adding new message with title \(title)")
  } else {
    response.send("You need to provide a title.")
  }

  next()
}

Kitura.addHTTPServer(onPort: 8090, with: router)
Kitura.run()

import CouchDB
import Credentials
import CredentialsGitHub
import Foundation
import HeliumLogger
import Kitura
import KituraNet
import KituraSession
import KituraStencil
import LoggerAPI
import SwiftyJSON

extension String {
	func removingHTMLEncoding() -> String {
		let result = self.replacingOccurrences(of: "+", with: "")
		return result.removingPercentEncoding ?? result
	}
}

func getPost(for request: RouterRequest, fields: [String]) -> [String: String]? {
	guard let values = request.body else { return nil }
	guard case .urlEncoded(let body) = values else { return nil }
	var result = [String: String]()
	for field in fields {
		if let value = body[field]?.trimmingCharacters(in: .whitespacesAndNewlines) {
			if value.count > 0 { result[field] = value.removingHTMLEncoding()
				continue
			}
		}
		return nil
	}
	return result
}

func send(error: String, code: HTTPStatusCode, to response: RouterResponse) {
	_ = try? response.status(code).send(error).end()
}

HeliumLogger.use()

let router = Router()
router.setDefault(templateEngine: StencilTemplateEngine())
router.all("/static", middleware: StaticFileServer())
router.all(middleware: Session(secret: "He thrusts his fists against the posts and still insists he sees the ghosts"))
router.post("/", middleware: BodyParser())

let credentials = Credentials()
let gitCredentials = CredentialsGitHub(clientId: "54c2a52698ed3c8c7e73", clientSecret: "061ec96cfd3ad7fe3202622a6a251407d19b3567", callbackUrl: "http://localhost:8090/login/github/callback", userAgent: "server-side-swift")
credentials.register(plugin: gitCredentials)

router.get("/login/github", handler: credentials.authenticate(credentialsType: gitCredentials.name))
router.get("/login/github/callback", handler: credentials.authenticate(credentialsType: gitCredentials.name))
credentials.options["failureRedirect"] = "/login/github"

router.all("/projects", middleware: credentials)
router.all("/signup", middleware: credentials)

Kitura.addHTTPServer(onPort: 8090, with: router)
Kitura.run()
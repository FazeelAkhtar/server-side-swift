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

let connectionProperties = ConnectionProperties(host: "localhost", port: 5984, secured: false)
let client = CouchDBClient(connectionProperties: connectionProperties)
let database = client.database("instantcoder")

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

func context(for request: RouterRequest) -> [String: Any] {
	var result = [String: Any]()
	result["username"] = request.userProfile?.displayName
	result["languages"] = ["C", "C++", "C#", "Go", "Java", "JavaScript", "Objective-C", "Perl", "PHP", "Python", "Ruby", "Swift"]

	return result
}

func getUserProfile(for request: RouterRequest, with response: RouterResponse) -> JSON? {
	// if they haven't authenticated using GitHub, bail out
	guard let profileID = request.userProfile?.id else {
		_ = try? response.redirect("/").end()
		return nil
	}

	if let _ = request.session?["gitHubProfile"].dictionaryObject {
		// they are authenticated and logged in; return their profile
		return request.session?["gitHubProfile"]
	} else {
		// they aren't logged in; see if they have an account
		database.retrieve(profileID) { user, error in
			if let _ = error {
				// user wasn't found - they need to sign up
				_ = try? response.redirect("/signup").end()
			} else if let user = user {
				// user was found, so just log them in
				request.session?["gitHubProfile"] = user
			}
		}
	}

	// send back their profile
	return request.session?["gitHubProfile"]
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

router.get("/") {
	request, response, next in
	defer { next() }

	var pageContext = context(for: request)
	pageContext["page_home"] = true

	try response.render("home", context: pageContext)
}

router.get("/signup") {
	request, response, next in
	defer { next() }

	guard let profile = request.userProfile else { return }

	var pageContext = context(for: request)
	try response.render("signup", context: pageContext)
}

router.post("/signup") {
	request, response, next in
	defer { next() }

	// bail out if we're missing GitHub authentication details or a valid form submission
	guard let profile = request.userProfile else { return }
	guard let fields = getPost(for: request, fields: ["language"]) else { return }

	// check if the user ID already has an account
	database.retrieve(profile.id) { user, error in 
		if let error = error {
			// user wasn't found!

			// fetch their full profile from GitHub
			let gitHubURL = URL(string: "http://api.github.com/user/\(profile.id)")!
			guard var gitHubProfile = try? Data(contentsOf: gitHubURL) else { return }

			// adjust it to fit the format we want: "_id" rather than "id", plus "type" and "language"
			var gitHubJSON = JSON(data: gitHubProfile)
			gitHubJSON["_id"].stringValue = gitHubJSON["id"].stringValue
			_ = gitHubJSON.dictionaryObject?.removeValue(forKey: "id")
			gitHubJSON["type"].stringValue = "coder"
			gitHubJSON["language"].stringValue = fields["language"]!

			// save the document in CouchDB
			database.create(gitHubJSON) { id, rev, doc, error in
				if let doc = doc {
					// it worked! Activate their profile
					request.session?["gitHubProfile"] = gitHubJSON
				}
			}
		} else if let user = user {
			// user was found, so just log them in
			request.session?["gitHubProfile"] = user
		}
	}

	// redirect them to the logged-in homepage
	_ = try? response.redirect("/projects/mine").end()
}

router.get("/projects/mine") {
	request, response, next in
	defer { next() }

	// make sure they are fully authenticated and logged in
	guard let profile = getUserProfile(for: request, with: response) else { return }
	guard let gitHubID = profile["login"].string else { return }

	// put together basic page context
	var pageContext = context(for: request)

	// attempt to find all our projects
	database.queryByView("projects_by_owner", ofDesign: "instantcoder", usingParameters: [.keys([gitHubID as Database.KeyType])]) { projects, error in
		if let error = error {
			// this ought never to happen, but just in case...
			send(error: error.localizedDescription, code: .internalServerError, to: response)
		} else if let projects = projects {
			// store our projects in the context ready for Stencil
			pageContext["projects"] = projects["rows"].arrayObject
		}
	}

	// activate the "My Projects tab"
	pageContext["page_projects_mine"] = true

	// render the context using projects_mine.stencil
	try response.render("projects_mine", context: pageContext)
}

router.get("/projects/delete/:id/:rev") {
	request, response, next in
	defer { next() }

	guard let profile = getUserProfile(for: request, with: response) else { return }

	guard let id = request.parameters["id"] else { return }
	guard let rev = request.parameters["rev"] else { return }

	database.delete(id, rev: rev) { error in 
		_ = try? response.redirect("/projects/mine")
	}
}

router.get("/projects/new") {
	request, response, next in
	defer { next() }

	guard let profile = getUserProfile(for: request, with: response) else { return }

	var pageContext = context(for: request)
	pageContext["page_projects_new"] = true

	try response.render("projects_new", context: pageContext)
}

router.post("/projects/new") {
	request, response, next in

	// 1: check we have a fully authenticated user
	guard let profile = getUserProfile(for: request, with: response) else { return }

	// 2: make sure all three fields are present
	guard let fields = getPost(for: request, fields: ["name", "description", "language"]) else {
		send(error: "Missing required fields", code: .badRequest, to: response)
		return
	}

	// 3: base our new document on their submitted fields
	var newProject = fields

	// 4: add "type" and "owner" so we can create CouchDB views, the convert to JSON
	newProject["type"] = "project"
	newProject["owner"] = profile["login"].stringValue
	let newDocument = JSON(newProject)

	// 5: send the document to CouchDB
	database.create(newDocument) { id, revision, doc, error in
		// 6: show an error or redirect depending on the result
		if let error = error {
			send(error: error.localizedDescription, code: .internalServerError, to: response)
			return
		}

		_ = try? response.redirect("/projects/mine")
		next()
	}
}

router.get("/projects/all") {
	request, response, next in
	defer { next() }

	guard let profile = getUserProfile(for: request, with: response) else { return }
	var pageContext = context(for: request)

	// attempt to find all projects
	database.queryByView("projects", ofDesign: "instantcoder", usingParameters: []) { projects, error in
		if let error = error {
			// this ought never to happen, but just in case...
			send(error: error.localizedDescription, code: .internalServerError, to: response)
		} else if let projects = projects {
			// store projects in the context ready for Stencil
			pageContext["projects"] = projects["rows"].arrayObject
		}
	}

	// activate the "My Projects tab"
	pageContext["page_projects_all"] = true

	// render the context using projects_mine.stencil
	try response.render("projects_all", context: pageContext)
}

Kitura.addHTTPServer(onPort: 8090, with: router)
Kitura.run()
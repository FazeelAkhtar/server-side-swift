import CouchDB
import Cryptor
import Foundation
import HeliumLogger
import Kitura
import KituraNet
import KituraSession
import KituraStencil
import LoggerAPI
import SwiftyJSON
import Stencil

func send(error: String, code: HTTPStatusCode, to response: RouterResponse) {

  var pageContext = [String: String]()
  pageContext["error"] = error

  _ = try? response.status(code).render("error", context: pageContext).end()
}

func context(for request: RouterRequest) -> [String: Any] {
  var result = [String: String]()
  result["username"] = request.session?["username"].string
  return result
}

func password(from str: String, salt: String) -> String {
  let key = PBKDF.deriveKey(fromPassword: str, salt: salt, prf: .sha512, rounds: 250_000, derivedKeyLength: 64)
  return CryptoUtils.hexString(from: key)
}

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
      if value.characters.count > 0 {
        result[field] = value.removingHTMLEncoding()
        continue
      }
    }

    return nil
  }

  return result
}

HeliumLogger.use()

let connectionProperties = ConnectionProperties(host: "localhost", port: 5984, secured: false)
let client = CouchDBClient(connectionProperties: connectionProperties)
let database = client.database("forum")

let router = Router()
let ext = Extension()

ext.registerFilter("format_date") { (value: Any?) in
  if let value = value as? String {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZ"

    if let date = formatter.date(from: value) {
      formatter.dateStyle = .long
      formatter.timeStyle = .medium
      return formatter.string(from: date)
    }
  }

  return value
}

router.setDefault(templateEngine: StencilTemplateEngine(extension: ext))
router.post("/", middleware: BodyParser())
router.all("/static", middleware: StaticFileServer())
router.all(middleware: Session(secret: "The rain in Spain mainly falls on the Spaniards"))

router.get("/") {
  request, response, next in

  database.queryByView("forums", ofDesign: "forum", usingParameters: []) { forums, error in
    defer { next() }

    if let error = error {
      send(error: error.localizedDescription, code: .internalServerError, to: response)
    } else if let forums = forums {
      var forumContext = context(for: request)
      forumContext["forums"] = forums["rows"].arrayObject

      _ = try? response.render("home", context: forumContext)
    }
  }
}

router.get("/forum/create") {
    request, response, next in
    defer { next() }

    try response.render("forum-create", context: [:]).end()
}

router.post("/forum/create") {
    request, response, next in
    defer { next() }

    guard let fields = getPost(for: request, fields: ["forum_id"]) else {
        send(error: "Missing required fields", code: .badRequest, to: response)
        return
    }

    guard let username = request.session?["username"].string else {
        send(error: "You are not logged in", code: .forbidden, to: response)
        return
    }

    guard fields["forum_id"]! != "create" else {
        send(error: "Invalid forum name: create is reserved", code: .badRequest, to: response)
        return
    }

    // "_id": "videos",
    // "type": "forum",
    // "name": "Taylor's videos"

    database.retrieve(fields["forum_id"]!) { doc, error in
      if let error = error {
        // forum doesn't exist
        var newForum = [String: String]()
        newForum["type"] = "forum"
        newForum["_id"] = fields["forum_id"]!
        newForum["name"] = "Taylor's " + newForum["_id"]!

        let newForumJSON = JSON(newForum)

        // send it off to CouchDB
        database.create(newForumJSON) { id, revision, doc, error in
            defer { next() }

            if let error = error {
                send(error: "Forum could not be created", code: .internalServerError, to: response)
            } else if let id = id {
                // the new document was created successfully!
                _ = try? response.redirect("/forum/\(fields["forum_id"]!)/")
            }
        }
        } else {
            //forum exists already
            send(error: "Forum already exists", code: .badRequest, to: response)
        }
    }
}

router.get("/forum/:forumid") {
  request, response, next in

  guard let forumID = request.parameters["forumid"] else {
    send(error: "Missing forum ID", code: .badRequest, to: response)
    return
  }

  database.retrieve(forumID) { forum, error in
    if let error = error {
      send(error:error.localizedDescription, code: .notFound, to: response)
    } else if let forum = forum {
      database.queryByView("forum_posts", ofDesign: "forum", usingParameters: [.keys([forumID as Database.KeyType]), .descending(true)]) { messages, error in
        defer { next() }

        if let error = error {
          send(error: error.localizedDescription, code: .internalServerError, to: response)
        } else if let messages = messages {
          var pageContext = context(for: request)
          pageContext["forum_id"] = forum["_id"].stringValue
          pageContext["forum_name"] = forum["name"].stringValue
          pageContext["messages"] = messages["rows"].arrayObject

          _ = try? response.render("forum", context: pageContext)
        }
      }
    }
  }
}

router.get("/forum/:forumid/:messageid") {
  request, response, next in

  guard let forumID = request.parameters["forumid"], let messageID = request.parameters["messageid"] else {
    try response.status(.badRequest).end()
    return
  }

  database.retrieve(forumID) { forum, error in
    if let error = error {
      send(error: error.localizedDescription, code: .notFound, to: response)
    } else if let forum = forum {
      database.retrieve(messageID) { message, error in
        if let error = error {
          send(error: error.localizedDescription, code: .notFound, to: response)
        } else if let message = message {
          database.queryByView("forum_replies", ofDesign: "forum", usingParameters: [.keys([messageID as Database.KeyType])]) {
            replies, errors in
            defer { next() }

            if let error = error {
              send(error: error.localizedDescription, code: .internalServerError, to: response)
            } else if let replies = replies {
              var pageContext = context(for: request)
              pageContext["forum_id"] = forum["_id"].stringValue
              pageContext["forum_name"] = forum["name"].stringValue
              pageContext["forum_name"] = forum["name"].stringValue
              pageContext["message"] = message.dictionaryObject!
              pageContext["replies"] = replies["rows"].arrayObject

              _ = try? response.render("messages", context: pageContext)
            }
          }
        }
      }
    }
  }
}

router.get("/users/login") {
  request, response, next in
  defer { next() }

  try response.render("users-login", context: [:])
}

router.post("/users/login") {
  request, response, next in

  // ensure all the correct fields are present
  if let fields = getPost(for: request, fields: ["username", "password"]) {
    // load the user from CouchDB
    database.retrieve(fields["username"]!) { doc, error in
      defer { next() }

      if let error = error {
        // the user doesn't exist
        send(error: "Unable to load user.", code: .badRequest, to: response)
      } else if let doc = doc {
        // load the salt and password from the document
        let savedSalt = doc["salt"].stringValue
        let savedPassword = doc["password"].stringValue

        // hash the user's input password with the saved salf; this should produce the same password we have saved
        let testPassword = password(from: fields["password"]!, salt: savedSalt)

        if testPassword == savedPassword {
          // the password was correct - save the username in the session and redirect to the homepage
          request.session!["username"].string = doc["_id"].string
          _ = try? response.redirect("/")
        } else {
          // wrong password!
          send(error: "Wrong combination of username and password. Or is there even a user at all? Hmmm...", code: .badRequest, to: response)
        }
      }
    }
  } else {
    // the form was not filled in fully
    send(error: "Missing required fields", code: .badRequest, to: response)
  }
}

router.get("/users/create") {
  request, response, next in
  defer { next() }

  try response.render("users-create", context: [:])
}

router.post("/users/create") {
  request, response, next in
  defer { next() }

  guard let fields = getPost(for: request, fields: ["username", "password"]) else {
    send(error: "Missing required fields", code: .badRequest, to: response)
    return
  }

  database.retrieve(fields["username"]!) { doc, error in
    if let error = error {
      // username doesn't exist
      var newUser = [String: String]()

      // force couchdb id to be the username
      newUser["_id"] = fields["username"]!

      // add a "type" property so our views can filter correctly
      newUser["type"] = "user"

      let saltString: String

      // create a salt using one of two methods
      if let salt = try? Random.generate(byteCount: 64) {
        saltString = CryptoUtils.hexString(from: salt)
      } else {
        // this in theory should never be used, it's an emergency fallback
        saltString = (fields["username"]! + fields["password"]! + "project4").digest(using: .sha512)
      }

      // we need to store the salt in the database so we can re-hash the password at login time
      newUser["salt"] = saltString

      // calculate the password hash for this user
      newUser["password"] = password(from: fields["password"]!, salt: saltString)

      let newUserJSON = JSON(newUser)

      // send it off to CouchDB
      database.create(newUserJSON) { id, revision, doc, error in
        defer { next() }

        if let doc = doc {
          // set session username to newly created one, and redirect to home
          request.session!["username"].string = fields["username"]!
          _ = try? response.redirect("/")
        } else {
          // error
          send(error: "User could not be created", code: .internalServerError, to: response)
        }
      }
    } else {
      //username exists already
      send(error: "User already exists", code: .badRequest, to: response)
    }
  }
}

router.post("/forum/:forumid/:messageid?") {
  request, response, next in

  guard let forumID = request.parameters["forumid"] else {
    try response.status(.badRequest).end()
    return
  }

  guard let username = request.session?["username"].string else {
    send(error: "You are not logged in", code: .forbidden, to: response)
    return
  }

  guard let fields = getPost(for: request, fields: ["title", "body"]) else {
    send(error: "Missing required fields", code: .badRequest, to: response)
    return
  }

  // OK to proceed!
  var newMessage = [String: String]()
  newMessage["body"] = fields["body"]!

  // add the current date in the correct format
  let formatter = DateFormatter()
  formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZ"
  newMessage["date"] = formatter.string(from: Date())

  // mark the message as belonging to the current forum
  newMessage["forum"] = forumID

  // if we are replying to a message, use its ID as our parent
  if let messageID = request.parameters["messageid"] {
    newMessage["parent"] = messageID
  } else {
    // this is a top-level post, so it has no parent
    newMessage["parent"] = ""
  }

  newMessage["title"] = fields["title"]!

  // mark the username value we unwrapped from the session
  newMessage["user"] = username

  // use the username value as a message so our views work
  newMessage["type"] = "message"

  // convert the dictionary to JSON and send it off to CouchDB
  let newMessageJSON = JSON(newMessage)

  database.create(newMessageJSON) { id, revision, doc, error in
    defer { next() }

    if let error = error {
      send(error: "Message could not be created", code: .internalServerError, to: response)
    } else if let id = id {
      // the new document was created successfully!
      if newMessage["parent"]! == "" {
        // this is a top-level post -- load it now
        _ = try? response.redirect("/forum/\(forumID)/\(id)")
      } else {
        // this was a reply -- load the parent post
        _ = try? response.redirect("/forum/\(forumID)/\(newMessage["parent"]!)")
      }
    }
  }
}

Kitura.addHTTPServer(onPort: 8090, with: router)
Kitura.run()

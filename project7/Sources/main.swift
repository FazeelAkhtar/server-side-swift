import Cryptor
import Foundation
import Kitura
import KituraNet
import HeliumLogger
import LoggerAPI
import MySQL
import SwiftyJSON

func connectToDatabase() throws -> (Database, Connection) {
    let mysql = try Database(
        host: "localhost",
        user: "swift",
        password: "swift",
        database: "swift"
    )

    let connection = try mysql.makeConnection()
    return (mysql, connection)
}

func send(error: String, code: HTTPStatusCode, to response: RouterResponse) {
    _ = try? response.status(code).send(error).end()
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
let router = Router()
router.post("/", middleware: BodyParser())

router.get("/:user/posts") {
    request, response, next in
    defer { next() }

    // 1. Figure out which user to load
    guard let user = request.parameters["user"] else { return }

    // 2. Connect to MySQL
    let (db, connection) = try connectToDatabase()

    // 3. Create a query string with gaps in
    let query = "SELECT `id`, `user`, `message`, `date` FROM `posts` WHERE `user` = ? ORDER BY `date` DESC;"

    // 4. Merge the query string with our parameter
    let posts = try db.execute(query, [user], connection)

    // 5. Convert the result into dictionaries
    var parsedPosts = [[String: Any]]()

    for post in posts {
        var postDictionary = [String: Any]()
        postDictionary["id"] = post["id"]?.int
        postDictionary["user"] = post["user"]?.string
        postDictionary["message"] = post["message"]?.string
        postDictionary["date"] = post["date"]?.string
        parsedPosts.append(postDictionary)
    }

    var result = [String: Any]()
    result["status"] = "ok"
    result["posts"] = parsedPosts

    // 6. Convert the response to JSON and send it out
    let json = JSON(result)

    do {
        try response.status(.OK).send(json: json).end()
    } catch {
        Log.warning("Failed to send /:user/posts for \(user): \(error.localizedDescription)")
    }
}

router.post("/login") {
    request, response, next in
    defer { next() }

    // make sure our two required fields exist
    guard let fields = getPost(for: request, fields: ["username", "password"]) else {
        send(error: "Missing required fields", code: .badRequest, to: response)
        return
    }

    // connect to MySQL
    let (db, connection) = try connectToDatabase()

    // pull out the password and salt for the user
    let query = "SELECT `password`, `salt` FROM `users` WHERE `id` = ?;"
    let users = try db.execute(query, [fields["username"]!], connection)

    // ensure we got a row back
    guard let user = users.first else { return }

    // pull both values out from the MySQL result
    guard let savedPassword = user["password"]?.string else { return }
    guard let savedSalt = user["salt"]?.string else { return }

    // use the saved salt to create a hash from the password that was submitted
    let testPassword = password(from: fields["password"]!, salt: savedSalt)

    // compare the new hash against the existing one
    if savedPassword == testPassword {
        // success - clear out any expired tokens
        try db.execute("DELETE FROM `tokens` WHERE `expiry` < NOW()", [], connection)

        // generate a new random string for this token
        let token = UUID().uuidString

        // add it to our database, alongside the username and a fresh expiry date
        try db.execute("INSERT INTO `tokens` VALUES (?, ?, DATE_ADD(NOW(), INTERVAL 1 DAY));", [token, fields["username"]!], connection)

        // send the token back to the user
        var result = [String: Any]()
        result["status"] = "ok"
        result["token"] = token

        let json = JSON(result)

        do {
            try response.status(.OK).send(json: json).end()
        } catch {
            Log.warning("Failed to send /login for \(user): \(error.localizedDescription)")
        }
    }
}



Kitura.addHTTPServer(onPort: 8090, with: router)
Kitura.run()

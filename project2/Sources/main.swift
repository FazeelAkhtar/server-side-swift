import Kitura
import HeliumLogger
import LoggerAPI
import SwiftyJSON
import CouchDB

HeliumLogger.use()

let connectionProperties = ConnectionProperties(host: "localhost", port: 5984, secured: false)
let client = CouchDBClient(connectionProperties: connectionProperties)
let database = client.database("polls")

let router = Router()

router.get("/polls/list") {
  request, response, next in

  database.retrieveAll(includeDocuments: true) { docs, error in
    defer { next() }
    if let error = error {
      let errorMessage = error.localizedDescription
      let status = ["status": "error", "message": errorMessage]
      let result = ["result": status]
      let json = JSON(result)

      response.status(.OK).send(json: json)
    } else {
      let status = ["status": "ok"]
      var polls = [[String: Any]]()

      if let docs = docs {
        for document in docs["rows"].arrayValue {
          var poll = [String: Any]()
          poll["id"] = document["id"].stringValue
          poll["title"] = document["doc"]["title"].stringValue
          poll["option1"] = document["doc"]["option1"].stringValue
          poll["option2"] = document["doc"]["option2"].stringValue
          poll["votes1"] = document["doc"]["votes1"].intValue
          poll["votes2"] = document["doc"]["votes2"].intValue
          polls.append(poll)
        }
      }

      let result: [String: Any] = ["result": status, "polls": polls]
      let json = JSON(result)

      response.status(.OK).send(json: json)
    }
  }
}

extension String {
  func removingHTMLEncoding() -> String {
    let result = self.replacingOccurrences(of: "+", with: " ")
    return result.removingPercentEncoding ?? result
  }
}

router.post("/polls/create", middleware: BodyParser())

router.post("/polls/create") {
  request, response, next in

  // 2. check we have some data submitted
  guard let values = request.body else {
    try response.status(.badRequest).end()
    return
  }

  // 3. attempt to pull out URL-encoded values from the submission
  guard case .urlEncoded(let body) = values else {
    try response.status(.badRequest).end()
    return
  }
  // 4. create an array of fields to check
  let fields = ["title", "option1", "option2"]

  // this is where we'll store our trimmed values
  var poll = [String: Any]()

  for field in fields {
    // check that this field exists, and if it does, remove any whitespace
    if let value = body[field]?.trimmingCharacters(in: .whitespacesAndNewlines) {
      // make sure it has at least 1 character
      if value.characters.count > 0 {
        // add it to our list of parsed values
        poll[field] = value.removingHTMLEncoding()

        // important: this value exists, so go on to the next one
        continue
      }
    }

    // this value does not exist, so send back an error and exit
    try response.status(.badRequest).end()
    return
  }
    // fill in default values for the vote counts
    poll["votes1"] = 0
    poll["votes2"] = 0

    // convert it to JSON, which is what CouchDB ingests
    let json = JSON(poll)

    database.create(json) { id, revision, doc, error in
      defer { next() }

      if let id = id {
        // document was created successfully; return it back to the user
        let status = ["status": "ok", "id": id]
        let result = ["result": status]
        let json = JSON(result)

        response.status(.OK).send(json: json)
      } else {
        // something went wrong - attempt to find out what
        let errorMessage = error?.localizedDescription ?? "Unknown error"
        let status = ["status": "error", "message": errorMessage]
        let result = ["result": status]
        let json = JSON(result)

        // mark that this is a problem on our side, not the client's
        response.status(.internalServerError).send(json: json)
      }
    }
}

router.post("/polls/vote/:pollid/:option") {
  request, response, next in

  // ensure both parameters have values
  guard let poll = request.parameters["pollid"], let option = request.parameters["option"] else {
    try response.status(.badRequest).end()
    return
  }

  // attempt to pull out the poll the user requested
  database.retrieve(poll) { doc, error in
    if let error = error {
      // something went wrong!
      let errorMessage = error.localizedDescription
      let status = ["status": "error", "message": errorMessage]
      let result = ["result": status]
      let json = JSON(result)

      response.status(.notFound).send(json: json)
    } else if let doc = doc {
      var newDocument = doc
      let id = doc["_id"].stringValue
      let rev = doc["_rev"].stringValue

      if option == "1" {
        newDocument["votes1"].intValue += 1
      } else if option == "2" {
        newDocument["votes2"].intValue += 1
      }

      database.update(id, rev: rev, document: newDocument) { rev, doc, error in
        defer { next() }
        if let error = error {
          let status = ["status": "error"]
          let result = ["result": status]
          let json = JSON(result)

          response.status(.conflict).send(json: json)
        } else {
          let status = ["status": "ok"]
          let result = ["result": status]
          let json = JSON(result)

          response.status(.OK).send(json: json)
        }
      }
    }
  }
}

Kitura.addHTTPServer(onPort: 8090, with: router)
Kitura.run()

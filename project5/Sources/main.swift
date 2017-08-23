import Foundation
import HeliumLogger
import Kitura
import KituraStencil
import LoggerAPI
import SwiftGD

HeliumLogger.use()

let router = Router()

router.setDefault(templateEngine: StencilTemplateEngine())
router.post("/", middleware: BodyParser())
router.all("/static", middleware: StaticFileServer())

let rootDirectory = URL(fileURLWithPath: "\(FileManager().currentDirectoryPath)/public/uploads")
let originalsDirectory = rootDirectory.appendingPathComponent("originals")
let thumbsDirectory = rootDirectory.appendingPathComponent("thumbs")

router.get("/") {
    request, response, next in
    defer { next() }

    let fm = FileManager()
    guard let files = try? fm.contentsOfDirectory(at: originalsDirectory, includingPropertiesForKeys: nil) else { return }
    let allFilenames = files.map { $0.lastPathComponent }
    let visibleFilenames = allFilenames.filter { !$0.hasPrefix(".") }

    try response.render("home", context: ["files": visibleFilenames])
}

router.post("/upload") {
    request, response, next in
    defer { next() }

    // pull out the multi-part encoded form data
    guard let values = request.body else { return }
    guard case .multipart(let parts) = values else { return }

    // create an array of the file types we're willing to accept
    let acceptableTypes = ["image/png", "image/jpeg"]

    for part in parts {
        // ensure this image is one of the valid types
        guard acceptableTypes.contains(part.type) else { continue }

        // attempt to extract its data; move onto the next part if it fails
        guard case .raw(let data) = part.body else { continue }
        
        // replace any spaces in filenames with a dash
        let cleanedFilename = part.filename.replacingOccurrences(of: " ", with: "-")

        // convert that into a URL we can write to
        let newURL = originalsDirectory.appendingPathComponent(cleanedFilename)

        // write the full-size original image
        _ = try? data.write(to: newURL)

        // create a matching URL in the thumbnails directory
        let thumbURL = thumbsDirectory.appendingPathComponent(cleanedFilename)

        // attempt to load the original into a SwiftGD image
        if let image = Image(url: newURL) {
            // attempt to resize that down to a thumbnail
            if let resized = image.resizedTo(width: 300) {
                // it worked -- save it!
                resized.write(to: thumbURL)
            }
        }
    }

    // reload the homepage
    try response.redirect("/")
}



Kitura.addHTTPServer(onPort: 8090, with: router)
Kitura.run()

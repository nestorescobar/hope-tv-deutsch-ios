// cspell:ignore Regie
import XCTest
@testable import HopeTViOS

/// The person name a tile draws (awe#7035): a port of the DEFAULT format of `getPersonName`
/// (`packages/utils/src/persons.ts`). The server enforces `initialsOnly` (ADR-0008,
/// `toPublicPerson`), so the port reads the served parts only.
final class PersonNameTests: XCTestCase {

    private func name(_ json: String) throws -> String {
        PersonName.display(try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8)))
    }

    func testTheNameJoinsTheFirstNameTheMiddleInitialAndTheLastName() throws {
        XCTAssertEqual(try name(#"{ "firstName": "John", "middleName": "quincy", "lastName": "Adams" }"#), "John Q. Adams")
        XCTAssertEqual(try name(#"{ "firstName": "John", "lastName": "Adams" }"#), "John Adams")
        XCTAssertEqual(try name(#"{ "lastName": "Adams" }"#), "Adams")
    }

    func testThePrefixAndTheSuffixWrapTheComposedName() throws {
        XCTAssertEqual(try name(#"{ "prefix": "Dr.", "firstName": "Jane", "lastName": "Doe", "suffix": "PhD" }"#),
                       "Dr. Jane Doe, PhD")
    }

    /// A stored `fullName` wins, and it takes no prefix or suffix (`person.fullName || affix(…)`).
    func testAStoredFullNameWinsWithNoAffix() throws {
        XCTAssertEqual(try name(#"{ "fullName": "Pastor Mark", "prefix": "Dr.", "firstName": "Mark", "lastName": "Finley" }"#),
                       "Pastor Mark")
    }

    /// An `initialsOnly` person arrives with initials in its parts, and its `fullName` is the
    /// initials or absent (`toPublicPerson`). The tile draws them as served.
    func testInitialsOnlyServedPartsDrawAsServed() throws {
        XCTAssertEqual(try name(#"{ "firstName": "J.", "lastName": "K." }"#), "J. K.")
        XCTAssertEqual(try name(#"{ "firstName": "J.", "lastName": "K.", "fullName": "J. K." }"#), "J. K.")
    }

    /// The flag never ships. If it did, the renderer would still not read it: the server owns it.
    func testTheRendererDoesNotReadInitialsOnly() throws {
        XCTAssertEqual(try name(#"{ "firstName": "John", "lastName": "Doe", "initialsOnly": true }"#), "John Doe")
    }

    func testNoNamePartGivesAnEmptyName() throws {
        XCTAssertEqual(try name(#"{ "prefix": "Dr.", "suffix": "Jr." }"#), "")
        XCTAssertEqual(try name(#"{ "_id": "p1", "avatar": null }"#), "")
        XCTAssertEqual(try name("null"), "")
        XCTAssertEqual(try name(#""John""#), "")
    }

    /// An empty part is left out, and a blank middle name gives no initial (`initial` trims).
    func testEmptyPartsAreLeftOut() throws {
        XCTAssertEqual(try name(#"{ "firstName": "", "lastName": "Doe", "fullName": "" }"#), "Doe")
        XCTAssertEqual(try name(#"{ "firstName": "Ann", "middleName": "  ", "lastName": "Lee" }"#), "Ann Lee")
        XCTAssertEqual(try name(#"{ "firstName": "Ann", "middleName": " beth ", "lastName": "Lee" }"#), "Ann B. Lee")
    }
}

/// `MovieCast` and `MovieCrew` (awe#7035): the Frontend API shapes of `toMovieCast` and
/// `toMovieCrew` (`apis/frontend/modules/media-library/services/movie/helpers.js`), filtered as the
/// web blocks filter them (`apps/hope-frontend/.../media-library/MovieCast.js`, `MovieCrew.js`).
final class MovieCastCrewTests: XCTestCase {

    private let photo = #"{ "containerId": "c1", "name": "jane.jpg" }"#

    override func setUp() {
        super.setUp()
        ChromeText.served.strings = [:]
    }

    override func tearDown() {
        ChromeText.served.strings = [:]
        super.tearDown()
    }

    private func person(_ id: String, _ first: String?, _ last: String? = nil) -> String {
        let parts = [first.map { #""firstName": "\#($0)""# }, last.map { #""lastName": "\#($0)""# }].compactMap { $0 }
        return "{ " + ([#""_id": "\#(id)""#] + parts).joined(separator: ", ") + " }"
    }

    private func value(_ json: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
    }

    /// One block on a screen, with its resource. `resource: nil` leaves the resource key out.
    private func evaluate(_ blockName: String, resourceName: String, resource: String?, props: String = "{}") throws -> EvaluatedNode {
        let resources = resource.map { #"{ "people": { "\#(resourceName)": \#($0) } }"# } ?? "{}"
        let document = try JSONDecoder().decode(CraftDocument.self, from: Data("""
        {
          "ROOT": { "type": { "resolvedName": "Root" }, "nodes": ["people"] },
          "people": { "type": { "resolvedName": "\(blockName)" }, "props": \(props), "parent": "ROOT", "nodes": [] }
        }
        """.utf8))
        let blockResources = try JSONDecoder().decode([String: [String: JSONValue]].self, from: Data(resources.utf8))
        return try XCTUnwrap(BlockRegistry.evaluate(nodeId: CraftDocument.rootId, document: document,
                                                    context: TestRender.context(blockResources: blockResources)))
    }

    private func row(_ blockName: String, resourceName: String, resource: String?, props: String = "{}") throws -> PeopleRowModel? {
        let node = try evaluate(blockName, resourceName: resourceName, resource: resource, props: props)
        guard case let .people(model)? = node.first(where: { $0.id == "people" })?.content else { return nil }
        return model
    }

    private func cast(_ resource: String?) throws -> PeopleRowModel? {
        try row("MovieCast", resourceName: "movieCast", resource: resource)
    }

    private func crew(_ resource: String?, props: String = "{}") throws -> PeopleRowModel? {
        try row("MovieCrew", resourceName: "movieCrew", resource: resource, props: props)
    }

    private var photoURL: URL? {
        TestRender.context().images.url(ImageFile(try! value(photo)), width: PersonTileMetrics.photoWidth)
    }

    func testTheKeysAreInTheRegistry() {
        XCTAssertEqual(BlockKey(resolvedName: "MovieCast"), .movieCast)
        XCTAssertEqual(BlockKey(resolvedName: "MovieCrew"), .movieCrew)
        XCTAssertTrue(BlockRegistry.keys.contains("MovieCast"))
        XCTAssertTrue(BlockRegistry.keys.contains("MovieCrew"))
    }

    // MARK: MovieCast

    /// One tile per member, in served order: the name, the role, and the photo when served.
    func testCastDrawsOneTilePerMemberWithItsRoleAndPhoto() throws {
        let model = try XCTUnwrap(try cast("""
        { "id": "m1", "cast": [
          { "person": \(person("p1", "Jane", "Doe")), "role": "Mary", "image": \(photo) },
          { "person": \(person("p2", "John", "Roe")), "role": "Joseph", "image": null }
        ] }
        """))

        XCTAssertEqual(model.heading, "Cast")
        XCTAssertEqual(model.tiles.map(\.name), ["Jane Doe", "John Roe"])
        XCTAssertEqual(model.tiles.map(\.role), ["Mary", "Joseph"])
        XCTAssertEqual(model.tiles[0].imageURL, photoURL)
        XCTAssertNotNil(photoURL)
        XCTAssertNil(model.tiles[1].imageURL, "a null image draws the neutral circle")
    }

    /// One person can play two roles: each role is its own tile, with its own id.
    func testOnePersonInTwoRolesKeepsTwoDistinctTiles() throws {
        let model = try XCTUnwrap(try cast("""
        { "id": "m1", "cast": [
          { "person": \(person("p1", "Jane", "Doe")), "role": "Mary", "image": null },
          { "person": \(person("p1", "Jane", "Doe")), "role": "Narrator", "image": null }
        ] }
        """))

        XCTAssertEqual(model.tiles.count, 2)
        XCTAssertEqual(Set(model.tiles.map(\.id)).count, 2)
    }

    /// A member whose person has no name draws no tile. A blank role draws no role line.
    func testCastDropsANamelessMemberAndABlankRole() throws {
        let model = try XCTUnwrap(try cast("""
        { "id": "m1", "cast": [
          { "person": { "_id": "p0", "avatar": null }, "role": "Ghost", "image": null },
          { "person": \(person("p1", "Jane")), "role": " ", "image": null },
          { "person": null, "role": "Nobody", "image": null }
        ] }
        """))

        XCTAssertEqual(model.tiles.map(\.name), ["Jane"])
        XCTAssertEqual(model.tiles.map(\.role), [nil])
    }

    /// "A movie with no cast or crew draws no section": null, absent, empty or all nameless.
    func testCastWithNothingToDrawRendersNull() throws {
        XCTAssertNil(try cast(nil))
        XCTAssertNil(try cast("null"))
        XCTAssertNil(try cast(#"{ "id": "m1", "cast": [] }"#))
        XCTAssertNil(try cast(#"{ "id": "m1", "cast": [{ "person": { "_id": "p0" }, "role": "X", "image": null }] }"#))

        let node = try evaluate("MovieCast", resourceName: "movieCast", resource: #"{ "id": "m1", "cast": [] }"#)
        XCTAssertNil(node.first { $0.id == "people" }?.content, "the block renders null")
        XCTAssertNil(node.firstFocusNodeId)
    }

    // MARK: MovieCrew

    /// Groups in served order. A fixed job draws its translated label, `custom` its served label.
    /// An unknown job and a `custom` group with no label are dropped. One tile per member, across
    /// the groups; the role line is the group label. The note is not drawn.
    func testCrewDrawsOneTilePerMemberWithTheJobLabel() throws {
        let model = try XCTUnwrap(try crew("""
        { "id": "m1", "crew": [
          { "job": "director", "members": [{ "person": \(person("p1", "Ann", "Lee")), "note": "", "image": \(photo) }] },
          { "job": "writer", "members": [{ "person": \(person("p2", "Bo", "Kim")), "note": "story", "image": null }] },
          { "job": "gaffer", "members": [{ "person": \(person("p3", "Cy")), "note": "", "image": null }] },
          { "job": "custom", "members": [{ "person": \(person("p4", "Di")), "note": "", "image": null }] },
          { "job": "custom", "label": "Narrator", "members": [{ "person": \(person("p5", "Ed")), "note": "", "image": null }] }
        ] }
        """))

        XCTAssertEqual(model.heading, "Crew")
        XCTAssertEqual(model.tiles.map(\.name), ["Ann Lee", "Bo Kim", "Ed"])
        XCTAssertEqual(model.tiles.map(\.role), ["Director", "Screenplay", "Narrator"])
        XCTAssertEqual(model.tiles[0].imageURL, photoURL)
        XCTAssertNil(model.tiles[1].imageURL)
    }

    /// Every fixed job of `MOVIE_CREW_JOBS` draws its English label (`media-library.json`).
    func testEveryFixedJobHasItsLabel() throws {
        let jobs = ["director", "writer", "author", "producer", "executiveProducer", "cinematography", "editing",
                    "music", "editorial", "casting", "productionDesign", "costumeDesign", "sound", "visualEffects"]
        let groups = jobs.enumerated().map { index, job in
            #"{ "job": "\#(job)", "members": [{ "person": \#(person("p\(index)", "N\(index)")), "note": "", "image": null }] }"#
        }
        let model = try XCTUnwrap(try crew(#"{ "id": "m1", "crew": [\#(groups.joined(separator: ", "))] }"#))

        XCTAssertEqual(model.tiles.map(\.role), [
            "Director", "Screenplay", "Author", "Producer", "Executive producer", "Cinematography", "Editing",
            "Music", "Editorial", "Casting", "Production design", "Costume design", "Sound", "Visual effects",
        ])
    }

    /// The job label is chrome: a served translation wins.
    func testTheJobLabelReadsTheServedTranslation() throws {
        ChromeText.served.strings = ["tvCrewJobDirector": "Regie", "tvCrew": "Stab"]
        let model = try XCTUnwrap(try crew("""
        { "id": "m1", "crew": [{ "job": "director", "members": [{ "person": \(person("p1", "Ann")), "note": "", "image": null }] }] }
        """))

        XCTAssertEqual(model.heading, "Stab")
        XCTAssertEqual(model.tiles.map(\.role), ["Regie"])
    }

    /// A nameless member draws no tile, and a group left empty draws nothing. One person in two
    /// groups keeps two distinct tiles.
    func testCrewDropsNamelessMembersAndKeepsDistinctIds() throws {
        let model = try XCTUnwrap(try crew("""
        { "id": "m1", "crew": [
          { "job": "director", "members": [{ "person": \(person("p1", "Ann")), "note": "", "image": null },
                                           { "person": { "_id": "p0" }, "note": "", "image": null }] },
          { "job": "producer", "members": [{ "person": { "_id": "p0" }, "note": "", "image": null }] },
          { "job": "writer", "members": [{ "person": \(person("p1", "Ann")), "note": "", "image": null }] }
        ] }
        """))

        XCTAssertEqual(model.tiles.map(\.name), ["Ann", "Ann"])
        XCTAssertEqual(model.tiles.map(\.role), ["Director", "Screenplay"])
        XCTAssertEqual(Set(model.tiles.map(\.id)).count, 2)
    }

    /// tvOS always draws tiles: the web `credits` table is not drawn, whatever `displayMode` says.
    func testCrewIgnoresDisplayMode() throws {
        let resource = """
        { "id": "m1", "crew": [{ "job": "director", "members": [{ "person": \(person("p1", "Ann")), "note": "", "image": null }] }] }
        """
        XCTAssertEqual(try crew(resource, props: #"{ "displayMode": "credits" }"#), try crew(resource))
        XCTAssertEqual(try crew(resource, props: #"{ "displayMode": "credits" }"#)?.tiles.count, 1)
    }

    func testCrewWithNothingToDrawRendersNull() throws {
        XCTAssertNil(try crew(nil))
        XCTAssertNil(try crew("null"))
        XCTAssertNil(try crew(#"{ "id": "m1", "crew": [] }"#))
        XCTAssertNil(try crew(#"{ "id": "m1", "crew": [{ "job": "gaffer", "members": [{ "person": { "_id": "p1", "firstName": "A" } }] }] }"#))
        XCTAssertNil(try crew(#"{ "id": "m1", "crew": [{ "job": "director", "members": [{ "person": { "_id": "p0" } }] }] }"#))
    }

    // MARK: Focus

    /// A focusable tile row behaves like a card row: first on a pushed screen, it takes the
    /// default focus.
    func testARowFirstOnTheScreenAsksForTheDefaultFocus() throws {
        let node = try evaluate("MovieCast", resourceName: "movieCast", resource: """
        { "id": "m1", "cast": [{ "person": \(person("p1", "Jane")), "role": "Mary", "image": null }] }
        """)

        XCTAssertEqual(node.firstFocusNodeId, "people")
    }
}

import Foundation

/// The document types Fen ships with (issue #7). Descriptions are plain words because
/// classification (#11) reads them.
public enum SchemaStarters {
    public struct Pack: Sendable, Identifiable {
        public let id: String
        public let title: String
        public let types: [DocumentType]
    }

    public static let universal: [DocumentType] = [
        DocumentType("Person", description: "A person you know or work with.", fields: [
            SchemaField("organization"), SchemaField("role"), SchemaField("email"),
            SchemaField("last_contact", .date),
        ]),
        DocumentType("Project", description: "Work with a goal and an end.", fields: [
            SchemaField("status", .choice, values: ["planned", "active", "paused", "done"]),
            SchemaField("owner"), SchemaField("due", .date),
        ]),
        DocumentType("Meeting", description: "Notes from a meeting or call.", fields: [
            SchemaField("date", .date, required: true), SchemaField("attendees", .list),
            SchemaField("project"),
        ]),
        DocumentType("Task", description: "One thing to do.", fields: [
            SchemaField("status", .choice, values: ["todo", "doing", "done"]),
            SchemaField("due", .date), SchemaField("priority", .choice, values: ["low", "medium", "high"]),
        ]),
        DocumentType("Journal", description: "A daily note or journal entry.", fields: [
            SchemaField("date", .date, required: true), SchemaField("mood"),
        ]),
        DocumentType("Reference", description: "A source or fact to look up later.", fields: [
            SchemaField("source"), SchemaField("author"), SchemaField("url"),
        ]),
    ]

    public static let packs: [Pack] = [
        Pack(id: "sales", title: "Sales", types: [
            DocumentType("Deal", description: "A sales opportunity.", fields: [
                SchemaField("account"),
                SchemaField("stage", .choice, values: ["lead", "qualified", "proposal", "won", "lost"]),
                SchemaField("value", .number), SchemaField("close_date", .date),
            ]),
            DocumentType("Account", description: "A customer or company you sell to.", fields: [
                SchemaField("industry"), SchemaField("owner"), SchemaField("website"),
            ]),
        ]),
        Pack(id: "engineering", title: "Engineering", types: [
            DocumentType("ADR", description: "A record of one design decision.", fields: [
                SchemaField("status", .choice, values: ["proposed", "accepted", "superseded"]),
                SchemaField("date", .date), SchemaField("supersedes"),
            ]),
            DocumentType("Bug", description: "A defect report.", fields: [
                SchemaField("severity", .choice, values: ["low", "medium", "high", "critical"]),
                SchemaField("status", .choice, values: ["open", "fixing", "fixed", "wontfix"]),
                SchemaField("reporter"),
            ]),
        ]),
        Pack(id: "writer", title: "Writer", types: [
            DocumentType("Character", description: "A person in a story.", fields: [
                SchemaField("role"), SchemaField("first_appears"), SchemaField("aliases", .list),
            ]),
            DocumentType("Scene", description: "One scene of a story.", fields: [
                SchemaField("chapter", .number), SchemaField("characters", .list), SchemaField("setting"),
            ]),
        ]),
        Pack(id: "student", title: "Student", types: [
            DocumentType("Course", description: "A class you take.", fields: [
                SchemaField("instructor"), SchemaField("term"), SchemaField("credits", .number),
            ]),
            DocumentType("Concept", description: "An idea you are learning.", fields: [
                SchemaField("course"), SchemaField("confidence", .choice, values: ["new", "shaky", "solid"]),
            ]),
        ]),
    ]

    /// What a workspace uses until you create a schema file.
    public static var defaultSchema: DocumentSchema {
        DocumentSchema(version: SchemaVersion(1), types: universal)
    }
}

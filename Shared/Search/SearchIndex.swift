import Foundation
import Synchronization

/// What the index remembers about a file, so the indexer can skip the ones that did not change.
struct KnownDocument: Equatable, Sendable {
    let hash: String
    let size: Int
    let modified: Double
}

struct IndexSummary: Equatable, Sendable {
    var documents = 0
    var chunks = 0
    /// Chunks that have a vector. Fewer than `chunks` when the embedder was unavailable for some text.
    var embeddedChunks = 0
}

/// One chunk matched by words. `score` is higher for a better match.
struct TextCandidate: Sendable, Equatable {
    let chunkID: Int64
    let path: String
    let title: String
    let heading: String
    let startLine: Int
    let snippet: String
    let inbound: Int
    let score: Double
}

/// One chunk matched by meaning. `score` is the cosine similarity.
struct VectorCandidate: Sendable, Equatable {
    let chunkID: Int64
    let path: String
    let title: String
    let heading: String
    let startLine: Int
    let snippet: String
    let inbound: Int
    let score: Double
}

enum SearchIndexError: Error, LocalizedError {
    case closed

    var errorDescription: String? {
        "This workspace's search index was closed."
    }
}

/// Which embedding model made the vectors in an index. A different model means different
/// vectors, so the index starts over.
struct EmbedderIdentity: Equatable, Sendable {
    let id: String
    let dimension: Int
}

/// One workspace's search index: SQLite with full-text search (FTS5) and one quantized vector per
/// chunk (issue #35). It lives in `~/.fen` and is a cache: deleting the file is always safe.
actor SearchIndex {
    static let schemaVersion = "1"
    static let fileName = "search.sqlite"

    private let url: URL
    private let embedder: EmbedderIdentity?
    private let closedFlag = Mutex(false)
    private var database: SQLiteDatabase?
    private var matrix: VectorMatrix?

    init(directory: URL, embedder: EmbedderIdentity?) {
        url = directory.appendingPathComponent(Self.fileName)
        self.embedder = embedder
    }

    /// Stops all further work, even from jobs that already hold this index. Call before deleting
    /// the folder, so nothing recreates it. Safe to call from any thread.
    nonisolated func markClosed() {
        closedFlag.withLock { $0 = true }
    }

    func close() {
        markClosed()
        database?.close()
        database = nil
        matrix = nil
    }

    // MARK: - Writing

    func knownDocuments() throws -> [String: KnownDocument] {
        let statement = try open().prepare("SELECT path, hash, size, mtime FROM docs")
        var known: [String: KnownDocument] = [:]
        while try statement.step() {
            known[statement.string(0)] = KnownDocument(
                hash: statement.string(1),
                size: statement.int(2),
                modified: statement.double(3)
            )
        }
        return known
    }

    func remove(paths: [String]) throws {
        guard !paths.isEmpty else { return }
        let database = try open()
        try database.transaction {
            for path in paths {
                try database.deleteContent(ofPath: path)
                let statement = try database.prepare("DELETE FROM docs WHERE path = ?1")
                statement.bind(1, path)
                try statement.step()
            }
        }
        matrix = nil
    }

    /// The file's bytes are unchanged, only its time stamp moved.
    func touch(path: String, modified: Double) throws {
        let statement = try open().prepare("UPDATE docs SET mtime = ?2 WHERE path = ?1")
        statement.bind(1, path)
        statement.bind(2, modified)
        try statement.step()
    }

    /// Replaces everything stored for `path`. `vectors` lines up with `document.chunks`.
    func replace(
        path: String,
        hash: String,
        size: Int,
        modified: Double,
        document: ParsedDocument,
        vectors: [Data?]
    ) throws {
        let database = try open()
        try database.transaction {
            try database.deleteContent(ofPath: path)
            let doc = try database.prepare(
                "INSERT OR REPLACE INTO docs (path, hash, size, mtime, title, stem, pathkey, inbound) "
                    + "VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, 0)"
            )
            doc.bind(1, path)
            doc.bind(2, hash)
            doc.bind(3, size)
            doc.bind(4, modified)
            doc.bind(5, document.title)
            doc.bind(6, MarkdownChunker.wikiKey((path as NSString).lastPathComponent))
            doc.bind(7, MarkdownChunker.wikiKey(path))
            try doc.step()

            let chunk = try database.prepare(
                "INSERT INTO chunks (path, ord, heading, start_line, text, vector) VALUES (?1, ?2, ?3, ?4, ?5, ?6)"
            )
            for (order, piece) in document.chunks.enumerated() {
                chunk.reset()
                chunk.bind(1, path)
                chunk.bind(2, order)
                chunk.bind(3, piece.heading)
                chunk.bind(4, piece.startLine)
                chunk.bind(5, piece.text)
                chunk.bind(6, order < vectors.count ? vectors[order] : nil)
                try chunk.step()
            }
            let link = try database.prepare("INSERT INTO links (source, kind, target) VALUES (?1, ?2, ?3)")
            for target in Set(document.links.map { $0.kind.rawValue + "\u{0}" + $0.target }) {
                let parts = target.split(separator: "\u{0}", maxSplits: 1).map(String.init)
                link.reset()
                link.bind(1, path)
                link.bind(2, parts[0])
                link.bind(3, parts[1])
                try link.step()
            }
        }
        matrix = nil
    }

    /// Counts the documents that link to each document. Run after a batch of changes.
    func refreshInbound() throws {
        try open().execute("""
        UPDATE docs SET inbound = (
            SELECT COUNT(DISTINCT l.source) FROM links l
            WHERE l.source != docs.path AND (
                (l.kind = 'path' AND l.target = docs.path)
                OR (l.kind = 'wiki' AND (l.target = docs.stem OR l.target = docs.pathkey))
            )
        )
        """)
    }

    // MARK: - Reading

    /// Files `path` links to, and files that link to it, as paths in this index.
    func linkedPaths(of path: String) throws -> (outgoing: Set<String>, incoming: Set<String>) {
        let database = try open()
        let match = "(l.kind = 'path' AND l.target = d.path) OR (l.kind = 'wiki' AND (l.target = d.stem OR l.target = d.pathkey))"
        let out = try database.prepare("""
        SELECT DISTINCT d.path FROM links l JOIN docs d ON \(match) WHERE l.source = ?1 AND d.path != ?1
        """)
        out.bind(1, path)
        var outgoing: Set<String> = []
        while try out.step() {
            outgoing.insert(out.string(0))
        }
        let into = try database.prepare("""
        SELECT DISTINCT l.source FROM links l JOIN docs d ON d.path = ?1 WHERE l.source != ?1 AND (\(match))
        """)
        into.bind(1, path)
        var incoming: Set<String> = []
        while try into.step() {
            incoming.insert(into.string(0))
        }
        return (outgoing, incoming)
    }

    func summary() throws -> IndexSummary {
        let statement = try open().prepare(
            "SELECT (SELECT COUNT(*) FROM docs), COUNT(*), COUNT(vector) FROM chunks"
        )
        try statement.step()
        return IndexSummary(documents: statement.int(0), chunks: statement.int(1), embeddedChunks: statement.int(2))
    }

    func textCandidates(matching query: String, anyWord: Bool = false, limit: Int) throws -> [TextCandidate] {
        let database = try open()
        for expression in FTSQuery.expressions(for: query, anyWord: anyWord) {
            let statement = try database.prepare("""
            SELECT c.id, c.path, d.title, c.heading, c.start_line, d.inbound,
                   snippet(chunks_fts, 0, '', '', '…', 20), bm25(chunks_fts, 1.0, 2.0, 3.0)
            FROM chunks_fts
            JOIN chunks c ON c.id = chunks_fts.rowid
            JOIN docs d ON d.path = c.path
            WHERE chunks_fts MATCH ?1
            ORDER BY bm25(chunks_fts, 1.0, 2.0, 3.0)
            LIMIT ?2
            """)
            statement.bind(1, expression)
            statement.bind(2, limit)
            var found: [TextCandidate] = []
            while try statement.step() {
                found.append(TextCandidate(
                    chunkID: Int64(statement.int(0)),
                    path: statement.string(1),
                    title: statement.string(2),
                    heading: statement.string(3),
                    startLine: statement.int(4),
                    snippet: statement.string(6),
                    inbound: statement.int(5),
                    score: -statement.double(7)
                ))
            }
            if !found.isEmpty {
                return found
            }
        }
        return []
    }

    func vectorCandidates(for query: [Float], limit: Int) throws -> [VectorCandidate] {
        guard let embedder, query.count == embedder.dimension,
              let unit = VectorCodec.normalized(query) else { return [] }
        let matches = try loadedMatrix(dimension: embedder.dimension).top(limit, for: unit)
        let statement = try open().prepare("""
        SELECT c.path, d.title, c.heading, c.start_line, d.inbound, substr(c.text, 1, 240)
        FROM chunks c JOIN docs d ON d.path = c.path WHERE c.id = ?1
        """)
        var found: [VectorCandidate] = []
        for match in matches {
            statement.reset()
            statement.bind(1, Int(match.id))
            guard try statement.step() else { continue }
            found.append(VectorCandidate(
                chunkID: match.id,
                path: statement.string(0),
                title: statement.string(1),
                heading: statement.string(2),
                startLine: statement.int(3),
                snippet: statement.string(5),
                inbound: statement.int(4),
                score: Double(match.score)
            ))
        }
        return found
    }

    // MARK: - Private

    private func loadedMatrix(dimension: Int) throws -> VectorMatrix {
        if let matrix {
            return matrix
        }
        let statement = try open().prepare("SELECT id, vector FROM chunks WHERE vector IS NOT NULL")
        var loaded = VectorMatrix(dimension: dimension)
        while try statement.step() {
            if let data = statement.data(1) {
                loaded.append(id: Int64(statement.int(0)), encoded: data)
            }
        }
        matrix = loaded
        return loaded
    }

    private func open() throws -> SQLiteDatabase {
        if closedFlag.withLock({ $0 }) {
            throw SearchIndexError.closed
        }
        if let database {
            return database
        }
        do {
            let opened = try openAndMigrate()
            database = opened
            return opened
        } catch let error as SQLiteError where error.code == 26 || error.code == 11 {
            // Not a database, or damaged. It is a cache, so start over.
            try? FileManager.default.removeItem(at: url)
            let opened = try openAndMigrate()
            database = opened
            return opened
        }
    }

    private func openAndMigrate() throws -> SQLiteDatabase {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let database = try SQLiteDatabase(url: url)
        try database.execute("PRAGMA journal_mode = WAL")
        try database.execute("PRAGMA synchronous = NORMAL")
        let expected = "\(Self.schemaVersion)|\(embedder?.id ?? "none")|\(embedder?.dimension ?? 0)"
        if try storedSignature(database) != expected {
            try database.execute("""
            DROP TABLE IF EXISTS chunks_fts; DROP TABLE IF EXISTS chunks; DROP TABLE IF EXISTS links;
            DROP TABLE IF EXISTS docs; DROP TABLE IF EXISTS meta;
            """)
            try database.execute(Self.schema)
            let statement = try database.prepare("INSERT INTO meta (key, value) VALUES ('signature', ?1)")
            statement.bind(1, expected)
            try statement.step()
        }
        return database
    }

    private func storedSignature(_ database: SQLiteDatabase) throws -> String? {
        try database.execute("CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT)")
        let statement = try database.prepare("SELECT value FROM meta WHERE key = 'signature'")
        return try statement.step() ? statement.string(0) : nil
    }

    private static let schema = """
    CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT);
    CREATE TABLE docs (
        path TEXT PRIMARY KEY, hash TEXT NOT NULL, size INTEGER NOT NULL, mtime REAL NOT NULL,
        title TEXT NOT NULL, stem TEXT NOT NULL, pathkey TEXT NOT NULL, inbound INTEGER NOT NULL DEFAULT 0
    );
    CREATE TABLE chunks (
        id INTEGER PRIMARY KEY, path TEXT NOT NULL, ord INTEGER NOT NULL, heading TEXT NOT NULL,
        start_line INTEGER NOT NULL, text TEXT NOT NULL, vector BLOB
    );
    CREATE INDEX chunks_path ON chunks(path);
    CREATE TABLE links (source TEXT NOT NULL, kind TEXT NOT NULL, target TEXT NOT NULL);
    CREATE INDEX links_source ON links(source);
    CREATE INDEX links_target ON links(target);
    CREATE VIRTUAL TABLE chunks_fts USING fts5(
        text, heading, path, content = 'chunks', content_rowid = 'id',
        tokenize = 'porter unicode61 remove_diacritics 2'
    );
    CREATE TRIGGER chunks_ai AFTER INSERT ON chunks BEGIN
        INSERT INTO chunks_fts(rowid, text, heading, path) VALUES (new.id, new.text, new.heading, new.path);
    END;
    CREATE TRIGGER chunks_ad AFTER DELETE ON chunks BEGIN
        INSERT INTO chunks_fts(chunks_fts, rowid, text, heading, path)
        VALUES ('delete', old.id, old.text, old.heading, old.path);
    END;
    """
}

/// Turns what you typed into an FTS5 expression. Punctuation never reaches the query parser, so
/// no input can be a syntax error or an operator.
enum FTSQuery {
    private static let stopWords: Set<String> = [
        "a", "an", "the", "of", "to", "in", "on", "at", "is", "are", "do", "does", "how", "what",
        "where", "which", "who", "i", "my", "and", "or", "for", "with", "about", "can", "we", "it",
    ]

    /// Strict first (every word must match, the last one as a prefix), then loose (any word).
    /// With `anyWord` the words are a bag, not a phrase: one loose expression, no prefix.
    static func expressions(for raw: String, anyWord: Bool = false) -> [String] {
        let all = raw.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        guard !all.isEmpty else { return [] }
        let meaningful = all.filter { !stopWords.contains($0) }
        let words = Array((meaningful.isEmpty ? all : meaningful).prefix(12))
        if anyWord {
            return [words.map { "\"\($0)\"" }.joined(separator: " OR ")]
        }
        let quoted = words.enumerated().map { index, word in
            "\"\(word)\"" + (index == words.count - 1 ? "*" : "")
        }
        var expressions = [quoted.joined(separator: " AND ")]
        if words.count > 1 {
            expressions.append(quoted.joined(separator: " OR "))
        }
        return expressions
    }
}

extension SQLiteDatabase {
    /// Removes a file's chunks and links. A method here, not on the actor, so the database never
    /// crosses an isolation boundary inside a transaction.
    func deleteContent(ofPath path: String) throws {
        for table in ["chunks", "links"] {
            let column = table == "chunks" ? "path" : "source"
            let statement = try prepare("DELETE FROM \(table) WHERE \(column) = ?1")
            statement.bind(1, path)
            try statement.step()
        }
    }
}

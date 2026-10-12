@testable import FenCore
import Testing

struct GitIgnoreTests {
    private func ignored(_ rules: String, _ path: String, isDirectory: Bool = false, base: String = "") -> Bool {
        GitIgnoreStack().adding(GitIgnoreRules(base: base, contents: rules)).isIgnored(path, isDirectory: isDirectory)
    }

    @Test func aPatternWithoutASlashMatchesAtAnyDepth() {
        #expect(ignored("*.log", "debug.log"))
        #expect(ignored("*.log", "a/b/debug.log"))
        #expect(!ignored("*.log", "debug.logs"))
    }

    @Test func aPatternWithASlashIsAnchored() {
        #expect(ignored("docs/draft.md", "docs/draft.md"))
        #expect(!ignored("docs/draft.md", "other/docs/draft.md"))
        #expect(ignored("/todo.md", "todo.md"))
        #expect(!ignored("/todo.md", "sub/todo.md"))
    }

    @Test func aTrailingSlashMatchesFoldersOnly() {
        #expect(ignored("build/", "build", isDirectory: true))
        #expect(!ignored("build/", "build", isDirectory: false))
        #expect(ignored("build/", "src/build", isDirectory: true))
    }

    @Test func negationReincludesAndTheLastMatchWins() {
        let rules = "*.md\n!keep.md"
        #expect(ignored(rules, "a.md"))
        #expect(!ignored(rules, "keep.md"))
        #expect(!ignored(rules, "sub/keep.md"))
        #expect(ignored("!keep.md\n*.md", "keep.md"))
    }

    @Test func doubleStarCrossesFolders() {
        #expect(ignored("**/cache/*.tmp", "cache/a.tmp"))
        #expect(ignored("**/cache/*.tmp", "x/y/cache/a.tmp"))
        #expect(ignored("a/**/z.md", "a/z.md"))
        #expect(ignored("a/**/z.md", "a/b/c/z.md"))
        #expect(ignored("logs/**", "logs/2026/jan.md"))
        #expect(!ignored("a/*.md", "a/b/c.md"))
    }

    @Test func questionMarkAndClassesStayInOneSegment() {
        #expect(ignored("note?.md", "note1.md"))
        #expect(!ignored("note?.md", "note12.md"))
        #expect(ignored("[ab].md", "a.md"))
        #expect(!ignored("[ab].md", "c.md"))
        #expect(ignored("[!ab].md", "c.md"))
    }

    @Test func commentsBlankLinesAndEscapesAreHandled() {
        #expect(!ignored("# *.md\n\n", "a.md"))
        #expect(ignored("\\#notes.md", "#notes.md"))
        #expect(ignored("\\!bang.md", "!bang.md"))
    }

    @Test func aNestedFileAppliesOnlyBelowItsFolder() {
        let nested = "*.md"
        #expect(ignored(nested, "docs/a.md", base: "docs"))
        #expect(!ignored(nested, "other/a.md", base: "docs"))
        #expect(!ignored(nested, "docs-2/a.md", base: "docs"))
    }

    @Test func aDeeperFileOverridesAShallowerOne() {
        let stack = GitIgnoreStack()
            .adding(GitIgnoreRules(base: "", contents: "*.md"))
            .adding(GitIgnoreRules(base: "docs", contents: "!*.md"))
        #expect(stack.isIgnored("a.md", isDirectory: false))
        #expect(!stack.isIgnored("docs/a.md", isDirectory: false))
    }

    @Test func globSetFollowsTheSameSyntaxAndCoversFilesInAMatchingFolder() {
        let set = GlobSet(["drafts/", "*.private.md", "!ignored-negation"])
        #expect(set.matches("drafts/a.md"))
        #expect(set.matches("deep/drafts/a.md"))
        #expect(set.matches("x/notes.private.md"))
        #expect(!set.matches("notes.md"))
        #expect(!GlobSet([]).matches("a.md"))
    }
}

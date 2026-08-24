import CoreGraphics
import Testing

@testable import CodeCopilot

@Suite("Parsing a repository reference")
struct RefTests {

    @Test("accepts what someone would actually paste")
    func acceptsRealInput() {
        let expected = GitHub.Ref(owner: "sindresorhus", repo: "slugify")
        let inputs = [
            "https://github.com/sindresorhus/slugify",
            "github.com/sindresorhus/slugify",
            "https://github.com/sindresorhus/slugify/",
            "https://github.com/sindresorhus/slugify.git",
            "git@github.com:sindresorhus/slugify.git",
            "sindresorhus/slugify",
            "  sindresorhus/slugify  ",
        ]
        for input in inputs {
            #expect(GitHub.parseRef(input) == expected, "failed on: \(input)")
        }
    }

    @Test("a link to a single file keeps just the repository")
    func deepLink() {
        // `/blob/` addresses one file. Scoping the walk to it would leave
        // nothing to walk, so it is treated as the repository root.
        let ref = GitHub.parseRef("https://github.com/socratic-ai/cosmo-ai/blob/main/README.md")
        #expect(ref?.owner == "socratic-ai")
        #expect(ref?.repo == "cosmo-ai")
        #expect(ref?.subpath == nil)
    }

    @Test("a link to a folder scopes the walk to it")
    func folderLink() {
        let ref = GitHub.parseRef("https://github.com/socratic-ai/cosmo/tree/main/sdks/cosmo-realtime")
        #expect(ref?.subpath == "sdks/cosmo-realtime")
    }

    @Test("refuses what isn't a repository")
    func refusesNonsense() {
        for input in ["", "   ", "hello", "https://example.com", "/", "one/two/three/four"] {
            #expect(GitHub.parseRef(input) == nil, "should have refused: \(input)")
        }
    }
}

@Suite("Noise and source filtering")
struct FilterTests {

    @Test("vendored and build directories are noise")
    func noise() {
        for path in [
            "node_modules/react/index.js", "dist/bundle.js", ".git/config",
            "coverage/lcov.info", "__pycache__/x.pyc", "target/debug/app",
        ] {
            #expect(GitHub.isNoise(path), "should be noise: \(path)")
        }
    }

    @Test("real source is not noise")
    func notNoise() {
        for path in ["src/index.ts", "app/models/user.rb", "distribution/README.md"] {
            #expect(!GitHub.isNoise(path), "should not be noise: \(path)")
        }
    }

    @Test("source files are recognised across languages")
    func source() {
        for path in ["a.ts", "b.py", "c.swift", "d.go", "e.rs", "f.YAML", "g.tsx"] {
            #expect(GitHub.isSource(path), "should be source: \(path)")
        }
        for path in ["logo.png", "font.woff2", "notes.txt", "Makefile"] {
            #expect(!GitHub.isSource(path), "should not be source: \(path)")
        }
    }
}

@Suite("Building the brief")
struct BriefTests {

    func entry(_ path: String, _ size: Int = 100) -> GitHub.TreeEntry {
        GitHub.TreeEntry(path: path, isFile: true, size: size)
    }

    @Test("folders are grouped and ordered by file count, noise excluded")
    func layout() {
        let files = [
            entry("src/a.ts"), entry("src/b.ts"), entry("src/c.ts"),
            entry("tests/a.test.ts"),
            entry("node_modules/dep/index.js"),
            entry("README.md"),
        ].filter { !GitHub.isNoise($0.path) }

        let (groups, loose) = Brief.topLevel(files)
        #expect(groups.map(\.name) == ["src", "tests"])
        #expect(groups.first?.files == 3)
        #expect(loose == ["README.md"])
    }

    @Test("entry points favour shallow, conventionally named files")
    func entryPoints() {
        let files = [
            entry("deep/nested/very/far/index.ts"),
            entry("main.py"),
            entry("src/server.ts"),
            entry("src/helpers.ts"),
        ]
        let found = Brief.entryPoints(files)
        #expect(found.first == "main.py")
        #expect(found.contains("src/server.ts"))
        #expect(!found.contains("src/helpers.ts"))
    }

    @Test("dependencies come out of package.json, runtime and dev together")
    func dependencies() {
        let manifest = """
            {"dependencies":{"react":"^18","zod":"^3"},"devDependencies":{"vitest":"^2"}}
            """
        let deps = Brief.dependencies(["package.json": manifest]).sorted()
        #expect(deps == ["react", "vitest", "zod"])
    }

    @Test("a requirements.txt is parsed down to bare names")
    func pythonDependencies() {
        let manifest = "requests==2.31.0\n# a comment\nflask>=2\n\nnumpy[extra]~=1.26\n"
        #expect(Brief.dependencies(["requirements.txt": manifest]) == ["requests", "flask", "numpy"])
    }

    @Test("a malformed manifest yields nothing rather than throwing")
    func brokenManifest() {
        #expect(Brief.dependencies(["package.json": "{not json"]).isEmpty)
    }
}

@Suite("Accessibility element filtering")
struct AXFilterTests {

    @Test("pointable roles are kept, scaffolding is dropped")
    func roles() {
        let frame = CGRect(x: 0, y: 0, width: 200, height: 20)
        #expect(AXFilter.isWorthKeeping(role: "AXLink", frame: frame))
        #expect(AXFilter.isWorthKeeping(role: "AXStaticText", frame: frame))
        #expect(!AXFilter.isWorthKeeping(role: "AXSplitter", frame: frame))
        #expect(!AXFilter.isWorthKeeping(role: "AXUnknown", frame: frame))
    }

    @Test("collapsed elements are dropped even when the role is right")
    func collapsed() {
        #expect(
            !AXFilter.isWorthKeeping(
                role: "AXLink", frame: CGRect(x: 10, y: 10, width: 0, height: 0)))
    }

    @Test("descriptors are clamped to the wire budgets")
    func clamping() {
        let long = String(repeating: "x", count: 5000)
        let out = AXFilter.clamp(role: long, title: long, label: long, value: long)
        #expect(out.role.count == AXFilter.roleMaxChars)
        #expect(out.title?.count == AXFilter.labelMaxChars)
        #expect(out.value?.count == AXFilter.valueMaxChars)
    }

    @Test("blank descriptors become nil, so 'absent' and 'empty' stay distinct")
    func blanksBecomeNil() {
        let out = AXFilter.clamp(role: "AXLink", title: "   ", label: "\n", value: nil)
        #expect(out.title == nil)
        #expect(out.label == nil)
        #expect(out.value == nil)
    }

    @Test("surrounding whitespace is trimmed from real descriptors")
    func trims() {
        let out = AXFilter.clamp(role: "AXLink", title: "  index.js\n", label: nil, value: nil)
        #expect(out.title == "index.js")
    }
}

@Suite("Usage example extraction")
struct UsageTests {

    @Test("a real README yields its usage block, not its install commands")
    func extractsUsage() throws {
        let readme = """
            # Thing

            Install it:

            ```bash
            npm install thing
            ```

            Use it:

            ```ts
            import { Client } from 'thing';
            const client = new Client({ token: 'x' });
            const session = await client.start();
            for await (const event of session) {}
            ```
            """
        let usage = try #require(Brief.usageExample(readme))
        #expect(usage.contains("import { Client }"))
        #expect(!usage.contains("npm install"))
    }

    @Test("a README with only shell blocks yields nothing rather than noise")
    func skipsShellOnly() {
        let readme = "# Thing\n\n```bash\nbrew install thing\ncd thing\nnpm i\nnpm run dev\n```"
        #expect(Brief.usageExample(readme) == nil)
    }

    @Test("a one-liner is not a usage example")
    func skipsShortBlocks() {
        #expect(Brief.usageExample("# T\n\n```ts\nconst x = 1;\n```") == nil)
    }
}

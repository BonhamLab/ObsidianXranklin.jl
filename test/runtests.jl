using Test
using ObsidianXranklin
using Dates

const FIXTURE_VAULT = joinpath(@__DIR__, "fixtures", "vault")

# ─── Frontmatter ──────────────────────────────────────────────────────────────

@testset "frontmatter" begin
    @testset "parse_frontmatter" begin
        content = "---\ntitle: Hello\npublish: true\n---\n\nBody text.\n"
        fm, body = ObsidianXranklin.parse_frontmatter(content)
        @test fm["title"] == "Hello"
        @test fm["publish"] == true
        @test strip(body) == "Body text."
    end

    @testset "no frontmatter passthrough" begin
        content = "# Just a heading\n\nNo frontmatter here.\n"
        fm, body = ObsidianXranklin.parse_frontmatter(content)
        @test isempty(fm)
        @test body == content
    end

    @testset "yaml_to_toml - basic types" begin
        @test ObsidianXranklin.toml_value("title", "Hello") == "title = \"Hello\""
        @test ObsidianXranklin.toml_value("count", 42) == "count = 42"
        @test ObsidianXranklin.toml_value("flag", true) == "flag = true"
        @test ObsidianXranklin.toml_value("tags", ["a", "b"]) == "tags = [\"a\", \"b\"]"
    end

    @testset "yaml_to_toml - date string" begin
        result = ObsidianXranklin.toml_value("date", "2024-03-15")
        @test result == "date = Date(2024, 3, 15)"
    end

    @testset "convert_frontmatter" begin
        content = "---\ntitle: Test\npublish: true\ndate: 2024-01-01\n---\n\nBody.\n"
        converted, fm = ObsidianXranklin.convert_frontmatter(content)
        @test startswith(converted, "+++\n")
        @test occursin("title = \"Test\"", converted)
        @test occursin("using Dates", converted)
        @test occursin("date = Date(2024, 1, 1)", converted)
        # publish key is in OBSIDIAN_INTERNAL_KEYS? No — it's only cssclasses, aliases etc.
        # publish key IS included in TOML (filtering happens before conversion)
        @test fm["publish"] == true
    end
end

# ─── Callouts ─────────────────────────────────────────────────────────────────

@testset "callouts" begin
    @testset "basic NOTE callout" begin
        content = "> [!NOTE]\n> This is the content.\n"
        result = ObsidianXranklin.transform_callouts(content)
        @test occursin("callout-note", result)
        @test occursin("callout-title", result)
        @test occursin("This is the content.", result)
        @test occursin("~~~", result)
    end

    @testset "callout with custom title" begin
        content = "> [!WARNING] Watch out!\n> Danger ahead.\n"
        result = ObsidianXranklin.transform_callouts(content)
        @test occursin("callout-warning", result)
        @test occursin("Watch out!", result)
        @test occursin("Danger ahead.", result)
    end

    @testset "multi-line callout" begin
        content = "> [!TIP]\n> Line one.\n> Line two.\n"
        result = ObsidianXranklin.transform_callouts(content)
        @test occursin("Line one.", result)
        @test occursin("Line two.", result)
    end

    @testset "non-callout blockquote is unchanged" begin
        content = "> This is a plain blockquote.\n"
        result = ObsidianXranklin.transform_callouts(content)
        @test result == content
    end
end

# ─── Wiki-links ───────────────────────────────────────────────────────────────

@testset "wikilinks" begin
    note_index = Dict(
        "published-note" => "/notes/published-note/",
        "another note"   => "/notes/another-note/",
    )

    @testset "simple wiki-link" begin
        content = "See [[published-note]] for details."
        result, edges = ObsidianXranklin.transform_wikilinks(content, note_index, "notes")
        @test occursin("[published-note](/notes/published-note/)", result)
        @test "published-note" in edges
    end

    @testset "aliased wiki-link" begin
        content = "See [[published-note|the note]] here."
        result, edges = ObsidianXranklin.transform_wikilinks(content, note_index, "notes")
        @test occursin("[the note](/notes/published-note/)", result)
    end

    @testset "section wiki-link" begin
        content = "See [[published-note#section]] here."
        result, edges = ObsidianXranklin.transform_wikilinks(content, note_index, "notes")
        @test occursin("/notes/published-note/#section", result)
    end

    @testset "anchor-only wiki-link" begin
        content = "See [[#Tags and other metadata]] here."
        result, edges = ObsidianXranklin.transform_wikilinks(content, note_index, "notes")
        @test occursin("[Tags and other metadata](#tags-and-other-metadata)", result)
        @test isempty(edges)
    end

    @testset "unresolved link becomes plain text" begin
        content = "This [[does-not-exist]] link."
        result, edges = @test_logs (:warn, r"Unresolved") ObsidianXranklin.transform_wikilinks(content, note_index, "notes")
        @test !occursin("[[", result)
        @test isempty(edges)
    end

    @testset "image embed" begin
        content = "![[photo.png]]"
        result, _ = ObsidianXranklin.transform_wikilinks(content, note_index, "notes")
        @test occursin("![photo.png](/assets/photo.png)", result)
    end

    @testset "image embed with spaces in filename" begin
        content = "![[Pasted image 20251022161331.png]]"
        result, _ = ObsidianXranklin.transform_wikilinks(content, note_index, "notes")
        @test occursin("![Pasted image 20251022161331.png](/assets/Pasted-image-20251022161331.png)", result)
    end
end

# ─── Vault discovery ──────────────────────────────────────────────────────────

@testset "vault" begin
    @testset "should_publish - explicit true" begin
        @test ObsidianXranklin.should_publish(Dict("publish" => true), "note.md", String[])
    end

    @testset "should_publish - explicit false" begin
        @test !ObsidianXranklin.should_publish(Dict("publish" => false), "note.md", String[])
    end

    @testset "should_publish - folder match" begin
        @test ObsidianXranklin.should_publish(Dict(), "public/note.md", ["public/"])
    end

    @testset "should_publish - no match → false" begin
        @test !ObsidianXranklin.should_publish(Dict(), "private/note.md", ["public/"])
    end

    @testset "note_slug" begin
        @test ObsidianXranklin.note_slug("My Note.md") == "my-note"
        @test ObsidianXranklin.note_slug("hello world.md") == "hello-world"
        @test ObsidianXranklin.note_slug("note--name.md") == "note-name"
    end

    @testset "discover_notes from fixtures" begin
        notes = ObsidianXranklin.discover_notes(FIXTURE_VAULT, String[])
        titles = [n.title for n in notes]
        @test "My Published Note" in titles
        @test "Another Note" in titles
        @test !("Private Note" in titles)
    end

    @testset "discover_notes with publish_folder" begin
        # folder-published.md has no frontmatter publish key
        notes = ObsidianXranklin.discover_notes(FIXTURE_VAULT, [""]) # all notes
        @test length(notes) >= 3
    end
end

# ─── Bases ────────────────────────────────────────────────────────────────────

@testset "bases" begin
    @testset "render_base_file" begin
        base_path = joinpath(FIXTURE_VAULT, "sample.base")
        notes = ObsidianXranklin.discover_notes(FIXTURE_VAULT, String[])
        html = ObsidianXranklin.render_base_file(base_path, notes)
        @test occursin("<table", html)
        # Real format uses file.* column names → headers are "Name" and "Tags"
        @test occursin("<th>Name</th>", html)
        @test occursin("<th>Tags</th>", html)
        # Notes matching type == "note" filter should appear
        @test occursin("My Published Note", html)
    end

    @testset "filter - tag contains" begin
        notes = ObsidianXranklin.discover_notes(FIXTURE_VAULT, String[])
        expr = Dict("and" => ["file.tags.contains(\"research\")"])
        filtered = ObsidianXranklin.filter_notes_for_base(notes, expr)
        titles = [n.title for n in filtered]
        @test "My Published Note" in titles
    end
end

# ─── End-to-end sync ──────────────────────────────────────────────────────────

@testset "sync_vault end-to-end" begin
    mktempdir() do site_dir
        notes = sync_vault(FIXTURE_VAULT, site_dir; publish_folders=String[])

        # Published notes exist (slugs derived from filenames)
        @test isdir(joinpath(site_dir, "notes", "published-note"))
        @test isfile(joinpath(site_dir, "notes", "published-note", "index.md"))
        @test isdir(joinpath(site_dir, "notes", "another-note"))

        # Private note was not published
        @test !isdir(joinpath(site_dir, "notes", "private-note"))

        # Graph data was written
        @test isfile(joinpath(site_dir, "_assets", "graph_data.json"))

        # Transformed content has TOML frontmatter
        content = read(joinpath(site_dir, "notes", "published-note", "index.md"), String)
        @test startswith(content, "+++\n")
        @test !occursin("---", content[1:20])

        # Callouts were converted
        @test occursin("callout-note", content)

        # Wiki-links were resolved
        @test occursin("[another note]", content)
        @test !occursin("[[", content)
    end

    # index_note writes the home note to notes/index.md
    mktempdir() do site_dir
        sync_vault(FIXTURE_VAULT, site_dir;
                   publish_folders=String[], index_note="published-note")
        @test isfile(joinpath(site_dir, "notes", "index.md"))
        index_content = read(joinpath(site_dir, "notes", "index.md"), String)
        slug_content   = read(joinpath(site_dir, "notes", "published-note", "index.md"), String)
        @test index_content == slug_content
    end

    # unknown index_note warns but doesn't error
    mktempdir() do site_dir
        @test_logs (:warn, r"index_note") match_mode=:any sync_vault(
            FIXTURE_VAULT, site_dir; publish_folders=String[], index_note="no-such-note")
        @test !isfile(joinpath(site_dir, "notes", "index.md"))
    end
end

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
        @test occursin("{{callout note Note}}", result)
        @test occursin("This is the content.", result)
        @test occursin("{{end_callout}}", result)
    end

    @testset "callout with custom title" begin
        content = "> [!WARNING] Watch out!\n> Danger ahead.\n"
        result = ObsidianXranklin.transform_callouts(content)
        @test occursin("{{callout warning Watch out!}}", result)
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

    @testset "hfun_callout with explicit title" begin
        html = ObsidianXranklin.hfun_callout(["warning", "Watch", "out!"])
        @test occursin("callout-warning", html)
        @test occursin("Watch out", html)  # ! is HTML-escaped by Hyperscript
        @test occursin("callout-title", html)
        @test occursin("callout-content", html)
    end

    @testset "hfun_callout default title" begin
        html = ObsidianXranklin.hfun_callout(["note"])
        @test occursin("callout-note", html)
        @test occursin("Note", html)
    end

    @testset "hfun_end_callout" begin
        @test ObsidianXranklin.hfun_end_callout() == "</div></div>"
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
        @test occursin("![photo.png](/assets/vault/photo.png)", result)
    end

    @testset "image embed with spaces in filename" begin
        content = "![[Pasted image 20251022161331.png]]"
        result, _ = ObsidianXranklin.transform_wikilinks(content, note_index, "notes")
        @test occursin("![Pasted image 20251022161331.png](/assets/vault/Pasted-image-20251022161331.png)", result)
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
        # All notes are indexed regardless of publish status
        @test "My Published Note" in titles
        @test "Another Note" in titles
        @test "Private Note" in titles
        # Templates/ is skipped by default — template note absent
        @test !("Sample Template" in titles)
        # published flag is set correctly
        @test filter(n -> n.title == "My Published Note", notes)[1].published
        @test !filter(n -> n.title == "Private Note", notes)[1].published
    end

    @testset "discover_notes with publish_folder" begin
        # [""] matches all paths; publish: false in frontmatter still overrides
        notes = ObsidianXranklin.discover_notes(FIXTURE_VAULT, [""])
        @test count(n -> n.published, notes) == length(notes) - 1  # all except private-note
        @test !filter(n -> n.title == "Private Note", notes)[1].published
    end

    @testset "raw note: discover_notes finds template with raw=true" begin
        # Skip nothing so Templates/ is included; YAML parse fails on Templater syntax
        notes = ObsidianXranklin.discover_notes(FIXTURE_VAULT, String[];
                                                skip_folders=String[])
        template_notes = filter(n -> n.title == "Sample Template", notes)
        @test length(template_notes) == 1
        t = template_notes[1]
        @test t.published == true
        @test t.raw == true
        @test isempty(t.frontmatter)
    end
end

# ─── read_site_config ─────────────────────────────────────────────────────────

@testset "read_site_config" begin
    mktempdir() do dir
        @testset "reads defined variable" begin
            write(joinpath(dir, "config.jl"), "my_var = [\"Templates/\", \"Drafts/\"]\n")
            result = ObsidianXranklin.read_site_config(dir, "my_var", String[])
            @test result == ["Templates/", "Drafts/"]
        end

        @testset "returns fallback when variable not defined" begin
            write(joinpath(dir, "config.jl"), "other_var = 42\n")
            result = ObsidianXranklin.read_site_config(dir, "my_var", ["default/"])
            @test result == ["default/"]
        end

        @testset "returns fallback when config.jl missing" begin
            result = ObsidianXranklin.read_site_config(joinpath(dir, "no-such-dir"),
                                                        "my_var", ["fallback/"])
            @test result == ["fallback/"]
        end

        @testset "returns fallback and warns when include errors" begin
            write(joinpath(dir, "config.jl"), "syntax error !!! @@\n")
            result = @test_logs (:warn, r"config\.jl") match_mode=:any begin
                ObsidianXranklin.read_site_config(dir, "my_var", ["default/"])
            end
            @test result == ["default/"]
        end
    end

    @testset "sync_vault reads vault_skip_folders from config.jl" begin
        mktempdir() do site_dir
            # Write a config.jl that skips nothing (empty list)
            write(joinpath(site_dir, "config.jl"), "vault_skip_folders = String[]\n")
            # With no skip_folders, the template note should be published as raw
            notes = sync_vault(FIXTURE_VAULT, site_dir; publish_folders=String[])
            template_found = any(n -> n.title == "Sample Template", notes)
            @test template_found
            slug = ObsidianXranklin.note_slug("sample-template.md")
            @test isfile(joinpath(site_dir, "notes", slug, "index.md"))
        end
    end
end

# ─── raw_publish_flag ─────────────────────────────────────────────────────────

@testset "raw_publish_flag" begin
    @testset "detects publish: true in valid YAML block" begin
        content = "---\ntitle: Test\npublish: true\n---\nBody.\n"
        @test ObsidianXranklin.raw_publish_flag(content)
    end

    @testset "returns false when publish: false" begin
        content = "---\ntitle: Test\npublish: false\n---\nBody.\n"
        @test !ObsidianXranklin.raw_publish_flag(content)
    end

    @testset "returns false when publish key absent" begin
        content = "---\ntitle: Test\n---\nBody.\n"
        @test !ObsidianXranklin.raw_publish_flag(content)
    end

    @testset "returns false when no frontmatter" begin
        content = "# Just a heading\n\nNo frontmatter.\n"
        @test !ObsidianXranklin.raw_publish_flag(content)
    end

    @testset "detects publish: true despite invalid YAML elsewhere in block" begin
        # Unquoted colon in value makes this unparseable by YAML but raw_publish_flag
        # should still find publish: true via regex
        content = "---\ntitle: Sample\npublish: true\ncreated_by: <user: kevin>\n---\nBody.\n"
        @test ObsidianXranklin.raw_publish_flag(content)
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

# ─── vault_mtimes and watch_vault ─────────────────────────────────────────────

@testset "vault_mtimes" begin
    @testset "returns non-empty dict for fixture vault" begin
        mtimes = ObsidianXranklin.vault_mtimes(FIXTURE_VAULT)
        @test !isempty(mtimes)
        # All values are positive floats (Unix timestamps)
        @test all(v > 0.0 for v in values(mtimes))
    end

    @testset "includes .md files" begin
        mtimes = ObsidianXranklin.vault_mtimes(FIXTURE_VAULT)
        keys_set = Set(keys(mtimes))
        @test any(endswith(k, ".md") for k in keys_set)
    end

    @testset "includes media assets" begin
        mtimes = ObsidianXranklin.vault_mtimes(FIXTURE_VAULT)
        @test any(endswith(k, ".png") for k in keys(mtimes))
    end

    @testset "skips hidden directories" begin
        mktempdir() do vault_dir
            hidden = joinpath(vault_dir, ".obsidian")
            mkpath(hidden)
            write(joinpath(hidden, "config.md"), "# hidden\n")
            write(joinpath(vault_dir, "visible.md"), "# visible\n")
            mtimes = ObsidianXranklin.vault_mtimes(vault_dir)
            @test haskey(mtimes, "visible.md")
            @test !any(startswith(k, ".obsidian") for k in keys(mtimes))
        end
    end

    @testset "respects skip_folders" begin
        mtimes = ObsidianXranklin.vault_mtimes(FIXTURE_VAULT; skip_folders=["Templates/"])
        @test !any(startswith(k, "Templates") for k in keys(mtimes))
    end
end

@testset "watch_vault" begin
    @testset "returns a Task" begin
        mktempdir() do site_dir
            task = watch_vault(FIXTURE_VAULT, site_dir;
                               interval=60,
                               publish_folders=String[])
            @test task isa Task
            # Stop the watcher via the cooperative stop flag
            ObsidianXranklin.stop_watcher()
            yield()
        end
    end

    @testset "initial sync runs before returning" begin
        mktempdir() do site_dir
            task = watch_vault(FIXTURE_VAULT, site_dir;
                               interval=60,
                               publish_folders=String[])
            ObsidianXranklin.stop_watcher()
            yield()
            # The initial sync must have created output before watch_vault returned
            @test isfile(joinpath(site_dir, "notes", "published-note", "index.md"))
        end
    end

    @testset "detects new file and re-syncs" begin
        mktempdir() do vault_dir
            mktempdir() do site_dir
                # Populate vault with a published note
                write(joinpath(vault_dir, "note-one.md"),
                      "---\ntitle: Note One\npublish: true\n---\n\nFirst note.\n")

                task = watch_vault(vault_dir, site_dir;
                                   interval=0.1,
                                   publish_folders=String[],
                                   skip_folders=String[])

                # Verify initial sync produced output
                @test isfile(joinpath(site_dir, "notes", "note-one", "index.md"))

                # Add a second note to the vault
                write(joinpath(vault_dir, "note-two.md"),
                      "---\ntitle: Note Two\npublish: true\n---\n\nSecond note.\n")

                # Wait long enough for at least two poll cycles (interval=0.1 s).
                # We yield here to let the @async task actually run; sleep yields
                # control to the Julia scheduler automatically.
                sleep(0.5)

                ObsidianXranklin.stop_watcher()
                yield()

                # The watcher must have picked up note-two and re-synced
                @test isfile(joinpath(site_dir, "notes", "note-two", "index.md"))
            end
        end
    end

    @testset "second call stops old task" begin
        mktempdir() do site_dir
            task1 = watch_vault(FIXTURE_VAULT, site_dir;
                                interval=60,
                                publish_folders=String[])
            # Second call sets task1's stop flag and starts a new task
            task2 = watch_vault(FIXTURE_VAULT, site_dir;
                                interval=60,
                                publish_folders=String[])
            # Yield so task1 can observe its stop flag and exit
            yield()
            sleep(0.05)
            @test istaskdone(task1)
            # task2 is still running (stop flag belongs to task2 now)
            @test !istaskdone(task2)
            ObsidianXranklin.stop_watcher()
            yield()
        end
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

        # Callouts were converted to hfun syntax
        @test occursin("{{callout", content)
        @test occursin("{{end_callout}}", content)
        @test !occursin("> [!", content)

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

    # raw note: published as plaintext fenced code block
    mktempdir() do site_dir
        notes = sync_vault(FIXTURE_VAULT, site_dir;
                           publish_folders=String[], skip_folders=String[])
        slug = ObsidianXranklin.note_slug("sample-template.md")
        out_path = joinpath(site_dir, "notes", slug, "index.md")
        @test isfile(out_path)
        content = read(out_path, String)
        @test startswith(content, "+++\n")
        @test occursin("title = \"Sample Template\"", content)
        @test occursin("~~~plaintext", content)
        # Raw body content is present verbatim
        @test occursin("Template body content goes here.", content)
        # Closing fence is present
        @test occursin("~~~\n", content)
    end
end

# Emoji icon for each callout type
const CALLOUT_ICONS = Dict(
    "note"       => "📝",
    "abstract"   => "📋",
    "summary"    => "📋",
    "tldr"       => "📋",
    "info"       => "ℹ️",
    "todo"       => "☑️",
    "tip"        => "💡",
    "hint"       => "💡",
    "important"  => "❗",
    "success"    => "✅",
    "check"      => "✅",
    "done"       => "✅",
    "question"   => "❓",
    "help"       => "❓",
    "faq"        => "❓",
    "warning"    => "⚠️",
    "caution"    => "⚠️",
    "attention"  => "⚠️",
    "failure"    => "❌",
    "fail"       => "❌",
    "missing"    => "❌",
    "danger"     => "⚡",
    "error"      => "⚡",
    "bug"        => "🐛",
    "example"    => "📌",
    "quote"      => "💬",
    "cite"       => "💬",
)

# Obsidian callout type display names
const CALLOUT_DISPLAY_NAMES = Dict(
    "note"       => "Note",
    "abstract"   => "Abstract",
    "summary"    => "Summary",
    "tldr"       => "TL;DR",
    "info"       => "Info",
    "todo"       => "To-Do",
    "tip"        => "Tip",
    "hint"       => "Hint",
    "important"  => "Important",
    "success"    => "Success",
    "check"      => "Check",
    "done"       => "Done",
    "question"   => "Question",
    "help"       => "Help",
    "faq"        => "FAQ",
    "warning"    => "Warning",
    "caution"    => "Caution",
    "attention"  => "Attention",
    "failure"    => "Failure",
    "fail"       => "Fail",
    "missing"    => "Missing",
    "danger"     => "Danger",
    "error"      => "Error",
    "bug"        => "Bug",
    "example"    => "Example",
    "quote"      => "Quote",
    "cite"       => "Cite",
)

"""
    transform_callouts(content::String) -> String

Transform Obsidian callout blocks (`> [!TYPE]`) into Xranklin `~~~` raw HTML
blocks. The opening and closing div tags are emitted as raw HTML; the body
content sits between them and is processed as normal Markdown by Xranklin.

Example:
    > [!WARNING] Be careful
    > This is the content.

becomes:

    ~~~
    <div class="callout callout-warning"><div class="callout-title">Be careful</div><div class="callout-content">
    ~~~
    This is the content.
    ~~~
    </div></div>
    ~~~
"""
function transform_callouts(content::String)
    lines = split(content, "\n")
    result = IOBuffer()
    i = 1

    while i <= length(lines)
        line = lines[i]

        # Detect callout opener: > [!TYPE] or > [!TYPE]+ / > [!TYPE]-
        m = match(r"^> \[!([A-Za-z-]+)\][-+]?\s*(.*)", line)
        if m !== nothing
            callout_type = lowercase(m.captures[1])
            title_override = strip(m.captures[2])
            title = isempty(title_override) ?
                get(CALLOUT_DISPLAY_NAMES, callout_type, titlecase(callout_type)) :
                title_override
            title_html = replace(title, "&" => "&amp;", "<" => "&lt;", ">" => "&gt;")
            icon = get(CALLOUT_ICONS, callout_type, "ℹ️")

            # Collect continuation lines (those starting with "> ")
            body_lines = String[]
            i += 1
            while i <= length(lines) && (startswith(lines[i], "> ") || lines[i] == ">")
                stripped = startswith(lines[i], "> ") ? lines[i][3:end] : ""
                push!(body_lines, stripped)
                i += 1
            end

            body = join(body_lines, "\n")

            write(result, "~~~\n<div class=\"callout callout-$callout_type\">")
            write(result, "<div class=\"callout-title\">$icon $title_html</div>")
            write(result, "<div class=\"callout-content\">\n~~~\n")
            write(result, "$body\n")
            write(result, "~~~\n</div></div>\n~~~\n")
        else
            write(result, line)
            write(result, "\n")
            i += 1
        end
    end

    out = String(take!(result))
    # Preserve trailing newline count from input
    trailing = length(content) - length(rstrip(content, '\n'))
    return rstrip(out, '\n') * "\n"^trailing
end

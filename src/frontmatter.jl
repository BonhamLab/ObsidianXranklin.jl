"""
    parse_frontmatter(content::String) -> (Dict, String)

Parse YAML frontmatter from Obsidian markdown.
Returns (frontmatter_dict, body_content).
"""
function parse_frontmatter(content::String)
    m = match(r"^---\r?\n(.*?)\r?\n---\r?\n(.*)"s, content)
    isnothing(m) && return (Dict(), content)

    yaml_str = m.captures[1]
    body = m.captures[2]

    fm = try
        YAML.load(yaml_str)
    catch e
        @warn "ObsidianXranklin: failed to parse YAML frontmatter" exception=e
        Dict()
    end
    isnothing(fm) && return (Dict(), body)

    return (fm, body)
end

"""
    raw_publish_flag(content::String) -> Bool

Check whether `publish: true` appears in the YAML frontmatter block of `content`
without invoking the YAML parser. This is used as a fallback when YAML parsing
fails (e.g. due to Obsidian Templater syntax such as `<%* ... -%>`).

Returns `true` only when:
1. `content` starts with `---` (has a YAML block), and
2. a line matching `publish: true` (with optional surrounding whitespace) exists
   within that block.
"""
function raw_publish_flag(content::String)
    startswith(content, "---") || return false
    # Find the closing --- after the opening one
    m = match(r"^---\r?\n(.*?)\r?\n---"s, content)
    isnothing(m) && return false
    yaml_block = m.captures[1]
    return occursin(r"(?m)^\s*publish:\s*true\s*$", yaml_block)
end

"""
    toml_value(key::String, value) -> String

Render a single key-value pair as a TOML line.
"""
toml_value(key::String, value::Union{Integer, AbstractFloat}) = "$key = $value"

function toml_value(key::String, value::Dates.Date)
    y, m, d = Dates.year(value), Dates.month(value), Dates.day(value)
    return "$key = Date($y, $m, $d)"
end

function toml_value(key::String, value::String)
    if occursin(r"^\d{4}-\d{2}-\d{2}$", value)
        d = Dates.Date(value)
        y, m, dy = Dates.year(d), Dates.month(d), Dates.day(d)
        return "$key = Date($y, $m, $dy)"
    end
    escaped = replace(value, "\\" => "\\\\", "\"" => "\\\"")
    return "$key = \"$escaped\""
end

function toml_value(key::String, value::AbstractVector)
    items = join(["\"$(replace(string(v), "\\" => "\\\\", "\"" => "\\\""))\"" for v in value], ", ")
    return "$key = [$items]"
end

function toml_value(key::String, value)
    escaped = replace(string(value), "\\" => "\\\\", "\"" => "\\\"")
    return "$key = \"$escaped\""
end

# Keys that are Obsidian-internal and should be omitted from Xranklin TOML
const OBSIDIAN_INTERNAL_KEYS = Set(["cssclasses", "aliases", "position", "file", "publish"])

"""
    has_date_values(fm::Dict) -> Bool

Returns true if any frontmatter value requires `using Dates` in the output.
"""
function has_date_values(fm::Dict)
    for (_, v) in fm
        v isa Dates.Date && return true
        v isa String && occursin(r"^\d{4}-\d{2}-\d{2}$", v) && return true
    end
    return false
end

"""
    convert_frontmatter(content::String) -> (String, Dict)

Convert YAML (`---`) frontmatter to Xranklin TOML (`+++`) format.
Returns (converted_content, original_frontmatter_dict).
If no frontmatter is found, returns (content, Dict()).
"""
function convert_frontmatter(content::String)
    fm, body = parse_frontmatter(content)

    isempty(fm) && return content, fm

    lines = String[]
    for (k, v) in fm
        string(k) in OBSIDIAN_INTERNAL_KEYS && continue
        push!(lines, toml_value(string(k), v))
    end

    has_date_values(fm) && pushfirst!(lines, "using Dates")

    toml_block = join(lines, "\n")
    return """
    +++
    $toml_block
    +++
    $body""", fm
end

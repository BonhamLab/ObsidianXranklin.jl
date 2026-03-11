"""
    parse_frontmatter(content::String) -> (Dict, String)

Parse YAML frontmatter from Obsidian markdown.
Returns (frontmatter_dict, body_content).
"""
function parse_frontmatter(content::String)
    m = match(r"^---\r?\n(.*?)\r?\n---\r?\n(.*)"s, content)
    if m !== nothing
        yaml_str = m.captures[1]
        body = m.captures[2]
        fm = try
            YAML.load(yaml_str)
        catch
            nothing  # treat as no frontmatter if YAML is invalid
        end
        fm isa Dict && return (fm, body)
    end
    return (Dict(), content)
end

"""
    toml_value(key::String, value) -> String

Render a single key-value pair as a TOML line.
"""
function toml_value(key::String, value)
    if value isa Bool
        return "$key = $value"
    elseif value isa Integer
        return "$key = $value"
    elseif value isa AbstractFloat
        return "$key = $value"
    elseif value isa Dates.Date
        y, m, d = Dates.year(value), Dates.month(value), Dates.day(value)
        return "$key = Date($y, $m, $d)"
    elseif value isa String
        # Detect YYYY-MM-DD date strings
        if occursin(r"^\d{4}-\d{2}-\d{2}$", value)
            d = Dates.Date(value)
            y, mo, dy = Dates.year(d), Dates.month(d), Dates.day(d)
            return "$key = Date($y, $mo, $dy)"
        end
        escaped = replace(value, "\\" => "\\\\", "\"" => "\\\"")
        return "$key = \"$escaped\""
    elseif value isa AbstractVector
        items = join(["\"$(replace(string(v), "\\" => "\\\\", "\"" => "\\\""))\"" for v in value], ", ")
        return "$key = [$items]"
    else
        escaped = replace(string(value), "\\" => "\\\\", "\"" => "\\\"")
        return "$key = \"$escaped\""
    end
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

    if isempty(fm)
        return content, fm
    end

    lines = String[]
    for (k, v) in fm
        string(k) in OBSIDIAN_INTERNAL_KEYS && continue
        push!(lines, toml_value(string(k), v))
    end

    if has_date_values(fm)
        pushfirst!(lines, "using Dates")
    end

    toml_block = join(lines, "\n")
    return "+++\n$toml_block\n+++\n$body", fm
end

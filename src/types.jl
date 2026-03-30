"""
    NoteInfo

Represents a vault note.

# Fields
- `src_path`: absolute path to source `.md` file in vault
- `slug`: URL-friendly identifier (used in `/notes/<slug>/`)
- `title`: note title (from frontmatter or filename stem)
- `tags`: note tags extracted from frontmatter
- `frontmatter`: full parsed YAML frontmatter dict (empty when YAML failed to parse)
- `published`: whether this note is published to the site
- `raw`: when `true`, the YAML frontmatter could not be parsed; the note is
  published as a preformatted plain-text page rather than rendered Markdown
"""
@kwdef struct NoteInfo
    src_path::String
    slug::String
    title::String
    tags::Vector{String}
    frontmatter::Dict
    published::Bool
    raw::Bool = false
end

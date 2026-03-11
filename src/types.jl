"""
    NoteInfo

Represents a vault note that has been selected for publishing.
"""
struct NoteInfo
    src_path::String        # absolute path to source .md file in vault
    slug::String            # URL-friendly identifier (used in /notes/<slug>/)
    title::String           # note title (from frontmatter or filename)
    tags::Vector{String}    # note tags
    frontmatter::Dict       # full parsed YAML frontmatter dict
end

#!/usr/bin/env ruby
# frozen_string_literal: true

# Validate YAML front matter in Markdown files.
#
# Why this exists:
# - `front_matter_parser` uses `Psych.safe_load`, which (by default) disallows
#   YAML timestamps being materialized as `Time`.
# - Jekyll posts commonly include `date:` fields like `2025-12-23 09:00:00 -0500`
#   which are valid YAML timestamps.
# - We still want "safe" parsing, just with `Time`/`Date` permitted.

require "date"
require "psych"

def extract_front_matter(text)
  # Front matter must start at the top of file.
  return nil unless text.start_with?("---\n") || text.start_with?("---\r\n")

  lines = text.lines
  return nil unless lines.first.strip == "---"

  # Find the next delimiter line (`---`).
  fm_lines = []
  idx = 1
  while idx < lines.length
    line = lines[idx]
    break if line.strip == "---"
    fm_lines << line
    idx += 1
  end

  # If we never found the closing delimiter, treat as invalid front matter.
  raise "Front matter opening '---' without closing '---'" if idx >= lines.length

  fm_lines.join
end

def safe_load_front_matter(yaml, file)
  Psych.safe_load(
    yaml,
    permitted_classes: [Time, Date],
    permitted_symbols: [],
    aliases: true,
    filename: file
  )
end

failed = false

Dir.glob("**/*.md").sort.each do |file|
  next if file.start_with?("_site/")

  text = File.read(file)
  fm = extract_front_matter(text)
  next if fm.nil?

  begin
    data = safe_load_front_matter(fm, file)

    # Optional sanity check: Jekyll expects a mapping.
    if !data.nil? && !data.is_a?(Hash)
      raise "Front matter parsed as #{data.class}, expected Hash"
    end
  rescue StandardError => e
    warn "Front matter validation failed: #{file}"
    warn "  #{e.class}: #{e.message}"
    failed = true
  end
end

exit(failed ? 1 : 0)


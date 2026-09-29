# frozen_string_literal: true

# Task 27e-a / 27e-b: the rules for the store listing's two free-text fields, kept in one small pure-Ruby
# module (no Rails, no database) so `App`, the editor and the specs all read the same numbers, the way
# `ListingGraphicRules` does for graphics.
#
#   description        the full description; paragraphs are kept
#   short_description  the one-line summary; always a single line
#
# The limits are Play Console's for its own "Main store listing" (short description 80 characters, full
# description 4000). They were written from memory of Play's help page, not re-fetched: check them there
# before treating the exact numbers as settled. Change them here and the model, the index schema
# (`docs/catalog_index_v2.schema.json`) and the docs move together by hand.
#
# `tidy_*` never raises and is idempotent: what the owner types is cleaned once, before validation, and
# tidying the result again changes nothing. Both return `nil` for a blank value so "no text" is one
# state, not two (`nil` and `""`).
module ListingText
  DESCRIPTION_MAX_LENGTH = 4000
  SHORT_DESCRIPTION_MAX_LENGTH = 80

  # A control character other than a newline. Postgres refuses NUL outright ("string contains null
  # byte"), and a stray tab or escape code in a public description is never intended.
  CONTROL_EXCEPT_NEWLINE = /[[:cntrl:]&&[^\n]]/
  LINE_SEPARATORS = /[\u2028\u2029]/

  # The full description. Line endings become "\n", other control characters become a space, spaces at
  # the end of a line go, three or more newlines in a row become two (one blank line between
  # paragraphs), and the ends are trimmed.
  def self.tidy_description(value)
    return nil if value.nil?

    text = value.to_s.scrub('')
                .gsub(/\r\n?/, "\n")
                .gsub(LINE_SEPARATORS, "\n")
                .gsub(CONTROL_EXCEPT_NEWLINE, ' ')
                .gsub(/[ ]+$/, '')
                .gsub(/\n{3,}/, "\n\n")
                .strip
    text.empty? ? nil : text
  end

  # The short description is one line: every run of whitespace, newlines included, becomes one space.
  def self.tidy_short_description(value)
    return nil if value.nil?

    text = value.to_s.scrub('')
                .gsub(LINE_SEPARATORS, ' ')
                .gsub(/[[:cntrl:]]/, ' ')
                .gsub(/[[:space:]]+/, ' ')
                .strip
    text.empty? ? nil : text
  end
end

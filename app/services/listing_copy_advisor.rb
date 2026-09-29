# frozen_string_literal: true

# Task 27e-e: wording advice for the store-listing text editor. ADVICE, NOT A GATE: nothing here blocks a
# save, a publish or going live. It answers one question for the owner: does this text use wording that
# Play's metadata policy discourages in a store listing (Play Console Help, "Best practices for your store
# listing", read as a snippet; handover "Task 27 open questions", Q3)?
#
# Pure Ruby on purpose, like ListingText and ListingGraphicRules: it takes plain strings and touches no
# database, so the model, the editor and the specs can all use it. The word lists are ENGLISH ONLY; the
# editor page says so ("checks English wording"). A zh-CN list is a later slice.
#
#   ListingCopyAdvisor.call('name' => 'BEST APP!!! Free', 'short_description' => nil, 'description' => '...')
#   # => { 'name' => [#<struct Warning key=:repeated_punctuation, match="!!!">, ...],
#   #      'short_description' => [], 'description' => [] }
#
# `key` is what the view localizes by (apps.listing_texts.show.advice.warnings.<key>); `match` is the
# offending text (up to MAX_SHOWN distinct snippets, joined with ", "); `count` and `limit` are set only
# by the two warnings that count something (:too_long, :many_emoji, :keyword_stuffing).
#
# Choices that are this file's, not Play's (Play's own rules are qualitative):
#   - the keyword-stuffing thresholds (KEYWORD_MIN_USES, KEYWORD_MIN_PERCENT, KEYWORD_MIN_WORDS);
#   - the emoji limit for the full description (MAX_EMOJI);
#   - "an ALL-CAPS word" is four or more capital letters (an acronym like GPS or USB is left alone), and
#     that same length is used for the run of ALL-CAPS words in the full description;
#   - what counts as an emoji: see `emoji_clusters`.
module ListingCopyAdvisor
  Warning = Struct.new(:key, :match, :count, :limit)

  FIELDS = %w[name short_description description].freeze

  # Play's title limit. This is advice only: it replaces a hard limit, so a longer name keeps saving.
  NAME_MAX_LENGTH = 30

  MAX_EMOJI = 5
  KEYWORD_MIN_USES = 8
  KEYWORD_MIN_PERCENT = 3
  KEYWORD_MIN_WORDS = 100
  KEYWORD_MIN_LETTERS = 4
  ALL_CAPS_MIN_LETTERS = 4
  ALL_CAPS_RUN = 3

  # How many distinct snippets one warning lists.
  MAX_SHOWN = 3

  # Which checks run on which field, in the order the page shows them.
  RULES = {
    'name' => %i[too_long emoji repeated_punctuation all_caps_word performance deal call_to_action],
    'short_description' => %i[emoji repeated_punctuation all_caps_word performance deal call_to_action],
    'description' => %i[performance deal call_to_action all_caps_run many_emoji keyword_stuffing]
  }.freeze

  ALNUM = '[[:alnum:]]'

  # Performance and ranking claims.
  PERFORMANCE = /(?<!#{ALNUM})(?:best|top|popular|app\s+of\s+the\s+year|\#\s?1)(?!#{ALNUM})/i

  # Deal and price words. `free` after a hyphen (sugar-free) is not a price claim; `ad-free` has its own
  # alternative. `% off` needs no leading boundary because the number sits right against the sign.
  DEAL = /(?<!#{ALNUM})(?:ad[-\s]free|no\s+ads|(?<!-)free|discounts?|sale)(?!#{ALNUM})|[[:digit:]]*\s?%\s?off(?!#{ALNUM})/i

  CALL_TO_ACTION = /(?<!#{ALNUM})(?:download|install|update|play|try)\s+now(?!#{ALNUM})/i

  # A short list of the common text emoticons. What follows must not be a letter or digit, so `Note:(a)` and
  # `Mode:Dark` do not match; one written against a word (`Great app:)`) does. The heart `<3` also needs a
  # boundary before it, so `x<3` is not one.
  EMOTICON = /(?:[:;=][-^']?[)(DPpOo]|(?<!#{ALNUM})<3)(?!#{ALNUM})/

  # The same punctuation mark three or more times in a row (`!!!`, `???`, `***`). This is the rule as
  # recorded, so an ellipsis (`...`) is a run too.
  REPEATED_PUNCTUATION = /([[:punct:]])\1{2,}/

  CAPS_WORD = "(?<!#{ALNUM})\\p{Lu}{#{ALL_CAPS_MIN_LETTERS},}(?!#{ALNUM})".freeze
  ALL_CAPS_WORD = Regexp.new(CAPS_WORD)
  # Capital words in a row, separated by spaces or tabs only. A comma breaks the run on purpose, so a
  # list of formats ("HTML, JSON, YAML") is not read as shouting.
  ALL_CAPS_RUN_PATTERN = Regexp.new("(?:#{CAPS_WORD}[[:blank:]]+){#{ALL_CAPS_RUN - 1},}#{CAPS_WORD}")

  TOKEN = /[\p{L}\p{N}]+(?:['\u2019-][\p{L}\p{N}]+)*/

  # Words that are too common to be a keyword. Only words of four or more letters matter (the rule
  # ignores shorter ones), so nothing shorter is listed.
  STOPWORDS = %w[
    about above after again against also always been before being below between both cannot could does doing
    done down during each else even ever every from further have having here herself himself into itself just
    know like made make many might more most much must myself need never only other ours ourselves over same
    should since some such than that their theirs them themselves then there these they this those through
    under until upon used uses using very well were what when where whether which while whom whose will with
    within without would your yours yourself yourselves
  ].freeze

  # @param values [Hash] the text of each field, keyed by field name (strings or symbols); a missing or
  #   nil field is treated as empty
  # @return [Hash{String => Array<Warning>}] one entry per field in FIELDS, an empty array when clean
  def self.call(values)
    values ||= {}
    FIELDS.to_h { |field| [ field, for_field(field, values[field] || values[field.to_sym]) ] }
  end

  # @param field [String] one of FIELDS
  # @param text [String, nil]
  # @return [Array<Warning>]
  def self.for_field(field, text)
    rules = RULES[field.to_s]
    return [] if rules.nil?

    text = text.to_s.strip
    return [] if text.empty?

    rules.filter_map { |rule| send(:"check_#{rule}", text) }
  end

  def self.check_too_long(text)
    length = text.length
    return nil unless length > NAME_MAX_LENGTH

    Warning.new(:too_long, nil, length, NAME_MAX_LENGTH)
  end

  def self.check_emoji(text)
    found = emoji_clusters(text) + text.scan(EMOTICON)
    found.empty? ? nil : Warning.new(:emoji, shown(found))
  end

  def self.check_repeated_punctuation(text)
    found = text.to_enum(:scan, REPEATED_PUNCTUATION).map { Regexp.last_match(0) }
    found.empty? ? nil : Warning.new(:repeated_punctuation, shown(found))
  end

  def self.check_all_caps_word(text)
    found = text.scan(ALL_CAPS_WORD)
    found.empty? ? nil : Warning.new(:all_caps_word, shown(found))
  end

  def self.check_all_caps_run(text)
    found = text.to_enum(:scan, ALL_CAPS_RUN_PATTERN).map { Regexp.last_match(0).strip }
    found.empty? ? nil : Warning.new(:all_caps_run, shown(found))
  end

  def self.check_performance(text)
    matches(:performance, text, PERFORMANCE)
  end

  def self.check_deal(text)
    matches(:deal, text, DEAL)
  end

  def self.check_call_to_action(text)
    matches(:call_to_action, text, CALL_TO_ACTION)
  end

  def self.check_many_emoji(text)
    count = emoji_clusters(text).size
    count > MAX_EMOJI ? Warning.new(:many_emoji, nil, count, MAX_EMOJI) : nil
  end

  # A word of four or more letters, not a stopword, used at least KEYWORD_MIN_USES times and making up more
  # than KEYWORD_MIN_PERCENT percent of a text of at least KEYWORD_MIN_WORDS words. The three worst are
  # listed, the most used first.
  def self.check_keyword_stuffing(text)
    tokens = text.downcase.scan(TOKEN)
    total = tokens.size
    return nil if total < KEYWORD_MIN_WORDS

    counts = tokens.select { |word| keyword?(word) }.tally
    stuffed = counts.select { |_word, uses| uses >= KEYWORD_MIN_USES && uses * 100 > total * KEYWORD_MIN_PERCENT }
    return nil if stuffed.empty?

    ranked = stuffed.sort_by { |word, uses| [ -uses, word ] }.first(MAX_SHOWN)
    Warning.new(:keyword_stuffing, ranked.map(&:first).join(', '), ranked.first.last, KEYWORD_MIN_USES)
  end

  def self.keyword?(word)
    word.match?(/\A\p{L}+\z/) && word.length >= KEYWORD_MIN_LETTERS && !STOPWORDS.include?(word)
  end

  # Each emoji as one item, the way a person counts them: a skin-tone, flag or family sequence is one.
  # A cluster counts when it is emoji by default (`Emoji_Presentation`) or is a symbol made an emoji by the
  # emoji selector (U+FE0F). Text-style symbols such as (c), (tm), a check mark or a star do not count.
  def self.emoji_clusters(text)
    text.scan(/\X/).select do |cluster|
      cluster.match?(/\p{Emoji_Presentation}/) || (cluster.match?(/\p{Extended_Pictographic}/) && cluster.include?("\uFE0F"))
    end
  end

  def self.matches(key, text, pattern)
    found = text.to_enum(:scan, pattern).map { Regexp.last_match(0).strip }
    found.empty? ? nil : Warning.new(key, shown(found))
  end

  # The distinct snippets (ignoring case), first seen first, at most MAX_SHOWN, as one string.
  def self.shown(found)
    found.uniq { |snippet| snippet.downcase }.first(MAX_SHOWN).join(', ')
  end

  private_class_method :check_too_long, :check_emoji, :check_repeated_punctuation, :check_all_caps_word,
                       :check_all_caps_run, :check_performance, :check_deal, :check_call_to_action,
                       :check_many_emoji, :check_keyword_stuffing, :keyword?, :emoji_clusters, :matches, :shown
end

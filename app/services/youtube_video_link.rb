# frozen_string_literal: true

require 'uri'

# Task 27d-e2-d: turns whatever an owner pastes into the promo-video box into the one thing Zealot
# stores, the 11-character YouTube video ID (docs/store_listing_graphics.md, "Video").
#
#   YoutubeVideoLink.parse('https://youtu.be/dQw4w9WgXcQ?si=abc')  # => ok, id 'dQw4w9WgXcQ'
#   YoutubeVideoLink.parse('dQw4w9WgXcQ')                          # => ok, id 'dQw4w9WgXcQ'
#   YoutubeVideoLink.parse('')                                     # => ok, id nil (means "no video")
#   YoutubeVideoLink.parse('https://vimeo.com/1')                  # => error :other_host
#
# Pure Ruby: no Rails, no network. It never fetches the link, so it cannot tell whether the video is
# public, unlisted, embeddable or deleted; the console says so next to the box. What it does guarantee
# is that a stored value is a plain 11-character ID (`ListingGraphicRules.youtube_id?`, the same check
# `App` and the index use), and that it came from YouTube's own host, matched EXACTLY (so
# `youtube.com.evil.example` and `https://youtube.com@evil.example/` are other hosts).
#
# Refused, with a code the UI localizes: :not_a_url, :other_host, :playlist (any `list=`, or a
# /playlist page), :not_a_video (a channel, a handle, a search page, a malformed ID).
# Accepted and dropped: every other query parameter (`t=`, `si=`, `feature=`); only the ID is kept, so
# a start time in the pasted link does NOT carry over.
module YoutubeVideoLink
  Result = Struct.new(:id, :error, keyword_init: true) do
    def ok?
      error.nil?
    end
  end

  HOSTS = %w[
    youtube.com www.youtube.com m.youtube.com music.youtube.com
    youtu.be
    youtube-nocookie.com www.youtube-nocookie.com
  ].freeze

  # /embed/ID, /shorts/ID, /live/ID and the old /v/ID
  ID_IN_PATH = %r{\A/(?:embed|shorts|live|v)/([^/?#]+)}

  SCHEME = %r{\A[a-z][a-z0-9+.-]*://}i

  def self.parse(input)
    text = input.to_s.strip
    return Result.new(id: nil) if text.empty?
    return Result.new(id: text) if ListingGraphicRules.youtube_id?(text)

    uri = uri_for(text)
    return failure(:not_a_url) unless uri
    return failure(:other_host) unless HOSTS.include?(uri.host.to_s.downcase)
    return failure(:playlist) if list_param?(uri) || uri.path.to_s.start_with?('/playlist')

    id = video_id(uri)
    ListingGraphicRules.youtube_id?(id) ? Result.new(id: id) : failure(:not_a_video)
  rescue URI::InvalidURIError, ArgumentError
    failure(:not_a_url)
  end

  def self.uri_for(text)
    candidate = SCHEME.match?(text) ? text : "https://#{text}"
    uri = URI.parse(candidate)
    return nil unless %w[http https].include?(uri.scheme) && uri.host.to_s != ''

    uri
  end
  private_class_method :uri_for

  def self.list_param?(uri)
    URI.decode_www_form(uri.query.to_s).any? { |key, _| key == 'list' }
  end
  private_class_method :list_param?

  def self.video_id(uri)
    path = uri.path.to_s
    if uri.host.to_s.downcase == 'youtu.be'
      path.delete_prefix('/').split('/').first
    elsif path == '/watch'
      URI.decode_www_form(uri.query.to_s).to_h['v']
    else
      path[ID_IN_PATH, 1]
    end
  end
  private_class_method :video_id

  def self.failure(code)
    Result.new(error: code)
  end
  private_class_method :failure
end

# frozen_string_literal: true

require 'rails_helper'

# Task 27d-e2-d. Pure Ruby: run in the sandbox that wrote it, with a shim in place of rails_helper.
RSpec.describe YoutubeVideoLink do
  let(:id) { 'dQw4w9WgXcQ' }

  def parse(value)
    described_class.parse(value)
  end

  it 'accepts a bare 11-character ID' do
    expect(parse(id)).to have_attributes(ok?: true, id: id)
    expect(parse("  #{id}  ")).to have_attributes(ok?: true, id: id)
  end

  it 'treats blank as "no video"' do
    [ nil, '', '   ' ].each { |value| expect(parse(value)).to have_attributes(ok?: true, id: nil) }
  end

  {
    'a watch URL' => 'https://www.youtube.com/watch?v=dQw4w9WgXcQ',
    'a watch URL without www or scheme' => 'youtube.com/watch?v=dQw4w9WgXcQ',
    'a mobile watch URL' => 'https://m.youtube.com/watch?v=dQw4w9WgXcQ',
    'a watch URL with tracking and a start time' => 'https://www.youtube.com/watch?feature=share&v=dQw4w9WgXcQ&t=43s',
    'a short link' => 'https://youtu.be/dQw4w9WgXcQ',
    'a short link with a tracking parameter' => 'https://youtu.be/dQw4w9WgXcQ?si=abc123',
    'an http short link' => 'http://youtu.be/dQw4w9WgXcQ',
    'an embed URL' => 'https://www.youtube.com/embed/dQw4w9WgXcQ',
    'a privacy-enhanced embed URL' => 'https://www.youtube-nocookie.com/embed/dQw4w9WgXcQ',
    'a shorts URL' => 'https://www.youtube.com/shorts/dQw4w9WgXcQ',
    'a live URL' => 'https://www.youtube.com/live/dQw4w9WgXcQ',
    'an upper-case host' => 'HTTPS://WWW.YOUTUBE.COM/watch?v=dQw4w9WgXcQ'
  }.each do |name, url|
    it "takes the ID from #{name}" do
      expect(parse(url)).to have_attributes(ok?: true, id: id)
    end
  end

  it 'keeps an ID that contains - and _' do
    expect(parse('https://youtu.be/a-b_c-d_e-f')).to have_attributes(ok?: true, id: 'a-b_c-d_e-f')
  end

  describe 'refusals' do
    it 'refuses a playlist, however it is written' do
      [ 'https://www.youtube.com/playlist?list=PLabcdefghijklmnopqrstuvwxyz0123456',
        'https://www.youtube.com/watch?v=dQw4w9WgXcQ&list=PLabcdefghijklmnopqrstuvwxyz0123456',
        'https://youtu.be/dQw4w9WgXcQ?list=PLabcdefghijklmnopqrstuvwxyz0123456' ].each do |url|
        expect(parse(url)).to have_attributes(ok?: false, error: :playlist)
      end
    end

    it 'refuses a channel, a handle, a search page and the home page' do
      [ 'https://www.youtube.com/channel/UCabcdefghijklmnopqrstuv', 'https://www.youtube.com/@someone',
        'https://www.youtube.com/results?search_query=zealot', 'https://www.youtube.com/',
        'https://www.youtube.com/watch', 'https://youtu.be/' ].each do |url|
        expect(parse(url)).to have_attributes(ok?: false, error: :not_a_video)
      end
    end

    it 'refuses a malformed ID' do
      [ 'https://www.youtube.com/watch?v=short', 'https://youtu.be/waytoolongtobeanid',
        'https://www.youtube.com/watch?v=dQw4w9WgXc%20' ].each do |url|
        expect(parse(url)).to have_attributes(ok?: false, error: :not_a_video)
      end
    end

    it 'refuses another site' do
      [ 'https://vimeo.com/123456789', 'https://example.com/watch?v=dQw4w9WgXcQ' ].each do |url|
        expect(parse(url)).to have_attributes(ok?: false, error: :other_host)
      end
    end

    it 'does not fall for a look-alike host' do
      [ 'https://youtube.com.evil.example/watch?v=dQw4w9WgXcQ', 'https://evil-youtube.com/watch?v=dQw4w9WgXcQ',
        'https://youtube.com@evil.example/watch?v=dQw4w9WgXcQ', 'https://notyoutu.be/dQw4w9WgXcQ',
        'https://evil.example/https://youtu.be/dQw4w9WgXcQ' ].each do |url|
        expect(parse(url)).to have_attributes(ok?: false, error: :other_host)
      end
    end

    it 'refuses text that is not a web link' do
      [ 'javascript:alert(1)', 'ftp://youtu.be/dQw4w9WgXcQ', 'not a url at all', 'http://', '://', 'https://youtu.be/dQw4w9WgXcQ extra words' ].each do |value|
        expect(parse(value)).to have_attributes(ok?: false)
      end
    end
  end
end

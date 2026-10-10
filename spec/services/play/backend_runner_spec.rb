# frozen_string_literal: true

require 'rails_helper'

# BackendRunner shells out to a real command, so these specs use real executable scripts on disk — no
# stubbing of the process layer — because the whole point of the class is the process boundary itself.
RSpec.describe Play::BackendRunner do
  def script(body)
    path = Rails.root.join('tmp', "play_backend_spec_#{SecureRandom.hex(4)}.sh").to_s
    File.write(path, "#!/usr/bin/env bash\n#{body}\n")
    File.chmod(0o755, path)
    path
  end

  it 'parses a JSON object and reports ok' do
    result = described_class.new(script(%q{echo '{"title":"T"}'})).call('com.x')

    expect(result.ok).to be(true)
    expect(result.raw).to eq('title' => 'T')
  end

  it 'reports a miss on a non-zero exit, keeping stderr' do
    result = described_class.new(script('echo "nope" >&2; exit 3')).call('com.x')

    expect(result.ok).to be(false)
    expect(result.error).to include('exit 3')
    expect(result.error).to include('nope')
  end

  it 'reports a miss when stdout is not JSON' do
    result = described_class.new(script('echo not-json')).call('com.x')

    expect(result.ok).to be(false)
    expect(result.error).to eq('backend output was not JSON')
  end

  it 'reports a miss when the output is JSON but not an object' do
    result = described_class.new(script("echo '[1,2]'")).call('com.x')

    expect(result.ok).to be(false)
    expect(result.error).to eq('backend returned no JSON object')
  end

  it 'reports a miss for a blank command, without running anything' do
    result = described_class.new(nil).call('com.x')

    expect(result.ok).to be(false)
    expect(result.error).to eq('no command configured')
  end

  it 'reports a miss when the command does not exist' do
    result = described_class.new('/no/such/backend-binary').call('com.x')

    expect(result.ok).to be(false)
    expect(result.error).to eq('backend command not found')
  end

  it 'bounds a hanging backend with a timeout' do
    result = described_class.new(script('sleep 5'), timeout: 1).call('com.x')

    expect(result.ok).to be(false)
    expect(result.error).to include('timed out')
  end
end

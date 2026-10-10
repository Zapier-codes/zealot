# frozen_string_literal: true

require 'rails_helper'

# The inspector shells out, so these specs use real executable scripts — the process boundary is the
# subject, so it is not stubbed.
RSpec.describe Play::ApkInspector do
  def fake_bundle(path, body)
    File.write(path, body)
    path
  end

  def script(body)
    path = Rails.root.join('tmp', "play_inspect_spec_#{SecureRandom.hex(4)}.sh").to_s
    File.write(path, "#!/usr/bin/env bash\n#{body}\n")
    File.chmod(0o755, path)
    path
  end

  around do |example|
    @dir = Rails.root.join('tmp', "play_inspect_#{SecureRandom.hex(4)}")
    FileUtils.mkdir_p(@dir)
    example.run
    FileUtils.remove_entry(@dir)
  end

  it 'reads a nested bundletool manifest dump' do
    bundle = fake_bundle(@dir.join('app.aab').to_s, 'x')
    cmd = script(%q{cat <<'JSON'
{"manifest":{"uses-sdk":{"minSdkVersion":"24","targetSdkVersion":"34"},
"uses-feature":[{"android:name":"android.hardware.camera","android:required":"true"},
{"android:name":"android.hardware.bluetooth"}]}}
JSON})

    result = described_class.new(command: cmd).call(bundle)

    expect(result.ok?).to be(true)
    expect(result.compatibility[:min_sdk_version]).to eq(24)
    expect(result.compatibility[:target_sdk_version]).to eq(34)
    expect(result.compatibility[:required_features]).to eq(
      ['android.hardware.camera', 'android.hardware.bluetooth']
    )
  end

  it 'accepts a flat shape and omits keys it cannot read' do
    bundle = fake_bundle(@dir.join('app.apk').to_s, 'x')
    cmd = script(%q{echo '{"minSdkVersion":"21"}'})

    result = described_class.new(command: cmd).call(bundle)

    expect(result.compatibility[:min_sdk_version]).to eq(21)
    expect(result.compatibility).not_to have_key(:target_sdk_version)
    expect(result.compatibility).not_to have_key(:required_features)
  end

  it 'treats a feature with no required flag as required (the Android default)' do
    bundle = fake_bundle(@dir.join('app.apk').to_s, 'x')
    cmd = script(%q{echo '{"manifest":{"uses-feature":[{"name":"android.hardware.nfc"}]}}'})

    result = described_class.new(command: cmd).call(bundle)

    expect(result.compatibility[:required_features]).to eq(['android.hardware.nfc'])
  end

  it 'drops a feature explicitly marked not required' do
    bundle = fake_bundle(@dir.join('app.apk').to_s, 'x')
    cmd = script(%q{echo '{"manifest":{"uses-feature":[{"name":"a","required":"false"},{"name":"b"}]}}'})

    result = described_class.new(command: cmd).call(bundle)

    expect(result.compatibility[:required_features]).to eq(['b'])
  end

  it 'reports a miss on a non-zero exit, keeping stderr' do
    bundle = fake_bundle(@dir.join('app.aab').to_s, 'x')

    result = described_class.new(command: script('echo "bad bundle" >&2; exit 2')).call(bundle)

    expect(result.ok?).to be(false)
    expect(result.error).to include('exit 2')
    expect(result.error).to include('bad bundle')
  end

  it 'reports a miss when the output is not JSON' do
    bundle = fake_bundle(@dir.join('app.aab').to_s, 'x')

    result = described_class.new(command: script('echo nope')).call(bundle)

    expect(result.ok?).to be(false)
    expect(result.error).to eq('inspector output was not JSON')
  end

  it 'reports a miss for a blank command, without running anything' do
    bundle = fake_bundle(@dir.join('app.aab').to_s, 'x')

    result = described_class.new(command: ' ').call(bundle)

    expect(result.ok?).to be(false)
    expect(result.error).to eq('no command configured')
  end

  it 'reports a miss for a missing file' do
    result = described_class.new(command: script('true')).call(@dir.join('nope.aab').to_s)

    expect(result.ok?).to be(false)
    expect(result.error).to eq('file not found')
  end

  it 'reports a miss when the command does not exist' do
    bundle = fake_bundle(@dir.join('app.aab').to_s, 'x')

    result = described_class.new(command: '/no/such/inspector').call(bundle)

    expect(result.ok?).to be(false)
    expect(result.error).to eq('inspector command not found')
  end

  it 'bounds a hanging inspector with a timeout' do
    bundle = fake_bundle(@dir.join('app.aab').to_s, 'x')

    result = described_class.new(command: script('sleep 5'), timeout: 1).call(bundle)

    expect(result.ok?).to be(false)
    expect(result.error).to include('timed out')
  end
end

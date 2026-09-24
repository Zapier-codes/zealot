# frozen_string_literal: true

require 'rails_helper'

RSpec::Matchers.define_negated_matcher :not_include, :include

# Task 27b-iii. The same scenarios were run for real in plain Ruby against this
# in-memory fake of the Git Data endpoints (26 checks, all passing); they have
# not been run under rspec or against the live GitHub API.
RSpec.describe CatalogIndex::GithubPagesCommit do
  # In-memory fake of exactly the endpoints the client uses.
  class FakeGitHub
    Response = Struct.new(:status, :headers, :body)
    attr_reader :calls, :commits, :branch_sha
    attr_accessor :fail_next_patch, :always_fail_patch, :net_errors, :status_queue, :token_expected
    def initialize(branch: 'gh-pages')
      @branch = branch; @blobs = {}; @trees = {}; @commits = {}; @calls = []
      @fail_next_patch = 0; @always_fail_patch = false; @net_errors = 0; @status_queue = []
      @token_expected = 'sekret-token'
      root = tree_for({ 'README.md' => blob('# catalog') })
      @branch_sha = commit('init', root, [])
    end
    def blob(content); sha = Digest::SHA1.hexdigest("blob #{content.bytesize}\0#{content}"); @blobs[sha] = content; sha; end
    def tree_for(entries); sha = Digest::SHA1.hexdigest(entries.sort.to_s); @trees[sha] = entries.dup; sha; end
    def commit(msg, tree, parents); sha = Digest::SHA1.hexdigest("#{msg}#{tree}#{parents}#{@commits.size}"); @commits[sha] = { message: msg, tree: tree, parents: parents }; sha; end
    def tip_files; @trees[@commits[@branch_sha][:tree]].transform_values { |b| @blobs[b] }; end
    def other_commit_lands!(path, content)   # someone else pushes to the branch
      t = @trees[@commits[@branch_sha][:tree]].merge(path => blob(content)); @branch_sha = commit('other', tree_for(t), [@branch_sha])
    end
    def commit_count; @commits.size; end
    def parents_of_tip; @commits[@branch_sha][:parents]; end
    def tip_message; @commits[@branch_sha][:message]; end
    def json(status, obj); Response.new(status, {}, JSON.generate(obj)); end
    def call(method, url, headers: {}, body: nil, **)
      @calls << { method: method, url: url, headers: headers, body: body }
      raise Errno::ECONNRESET if @net_errors.positive? && (@net_errors -= 1) >= 0
      return Response.new(@status_queue.shift, {}, '{"message":"upstream"}') unless @status_queue.empty?
      return json(401, { message: 'Bad credentials' }) unless headers['Authorization'] == "Bearer #{@token_expected}"
      path = url.sub(%r{\Ahttps://api.github.com/repos/o/r}, '')
      data = body && JSON.parse(body)
      case [method, path]
      in [:get, %r{\A/git/ref/heads/(.+)\z}]
        return json(404, { message: 'Not Found' }) unless $1 == @branch
        json(200, { object: { sha: @branch_sha } })
      in [:get, %r{\A/git/commits/(\h+)\z}] then json(200, { tree: { sha: @commits.fetch($1)[:tree] } })
      in [:post, '/git/blobs'] then json(201, { sha: blob(data['content']) })
      in [:post, '/git/trees']
        base = @trees.fetch(data['base_tree']).dup
        data['tree'].each { |e| base[e['path']] = e['sha'] }
        json(201, { sha: tree_for(base) })
      in [:post, '/git/commits'] then json(201, { sha: commit(data['message'], data['tree'], data['parents']) })
      in [:patch, %r{\A/git/refs/heads/(.+)\z}]
        return json(422, { message: 'Update is not a fast forward' }) if @always_fail_patch
        if @fail_next_patch.positive?
          @fail_next_patch -= 1; other_commit_lands!('other.txt', 'x'); return json(422, { message: 'Update is not a fast forward' })
        end
        return json(422, { message: 'Update is not a fast forward' }) unless @commits.fetch(data['sha'])[:parents] == [@branch_sha] && data['force'] == false
        @branch_sha = data['sha']; json(200, { object: { sha: @branch_sha } })
      else json(500, { message: "unhandled #{method} #{path}" })
      end
    end
  end


  def client(gh, **kw)
    described_class.new(repo: 'o/r', token: 'sekret-token', branch: 'gh-pages', transport: gh,
                        sleeper: ->(_) {}, **kw)
  end

  it 'publishes all files as one commit on top of the tip, keeping existing files, fast-forward only' do
    gh = FakeGitHub.new
    before = gh.branch_sha

    result = client(gh).publish({ 'index.json' => '{}', 'index.json.sig' => 'sig' }, message: 'm')

    expect(result.status).to eq(:published)
    expect(gh.commit_count).to eq(2)
    expect(gh.parents_of_tip).to eq([before])
    expect(gh.tip_files).to include('README.md', 'index.json' => '{}', 'index.json.sig' => 'sig')
    patch = gh.calls.find { |c| c[:method] == :patch }
    expect(JSON.parse(patch[:body])['force']).to be(false)
  end

  it 'does nothing when the content is unchanged' do
    gh = FakeGitHub.new
    c = client(gh)
    c.publish({ 'a.txt' => 'one' }, message: 'm')
    tip = gh.branch_sha

    expect(c.publish({ 'a.txt' => 'one' }, message: 'm').status).to eq(:unchanged)
    expect(gh.branch_sha).to eq(tip)
  end

  it 'starts over from the new tip when the branch moved, and never forces' do
    gh = FakeGitHub.new
    gh.fail_next_patch = 1

    expect(client(gh).publish({ 'index.json' => '{}' }, message: 'm').status).to eq(:published)
    expect(gh.tip_files).to include('other.txt', 'index.json' => '{}')

    gh = FakeGitHub.new
    gh.always_fail_patch = true
    expect { client(gh).publish({ 'x' => 'y' }, message: 'm') }
      .to raise_error(described_class::Error, /kept moving/)
    expect(gh.calls.count { |c| c[:method] == :patch }).to eq(3)
  end

  it 'explains a missing branch and never leaks the token' do
    expect { client(FakeGitHub.new, branch: 'nope').publish({ 'x' => 'y' }, message: 'm') }
      .to raise_error(described_class::Error, /not found.*Pages/m)

    bad = described_class.new(repo: 'o/r', token: 'WRONG-TOKEN', transport: FakeGitHub.new, sleeper: ->(_) {})
    expect { bad.publish({ 'x' => 'y' }, message: 'm') }
      .to raise_error(described_class::Error) { |e| expect(e.message).to include('Bad credentials').and(not_include('WRONG-TOKEN')) }
  end

  it 'retries network errors and 5xx answers' do
    gh = FakeGitHub.new
    gh.net_errors = 2
    expect(client(gh).publish({ 'x' => 'y' }, message: 'm').status).to eq(:published)

    gh = FakeGitHub.new
    gh.status_queue = [502, 503]
    expect(client(gh).publish({ 'x' => 'y' }, message: 'm').status).to eq(:published)
  end

  it 'validates its configuration' do
    expect { described_class.new(repo: '', token: '', transport: FakeGitHub.new) }
      .to raise_error(described_class::ConfigurationError, /CATALOG_PAGES_REPO.*CATALOG_PAGES_TOKEN/)
    expect { described_class.new(repo: 'not a repo', token: 't', transport: FakeGitHub.new) }
      .to raise_error(described_class::ConfigurationError)
    expect(described_class.configured?('CATALOG_PAGES_REPO' => 'o/r', 'CATALOG_PAGES_TOKEN' => 't')).to be true
    expect(described_class.configured?('CATALOG_PAGES_REPO' => 'o/r')).to be false
  end
end

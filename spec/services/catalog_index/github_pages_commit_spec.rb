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

  # Task 37b-iii-s1: a tenant's publish root is a directory in the same Pages repo.
  describe 'tenant publish roots' do
    let(:four) { { 'index.json' => '{}', 'index.json.sig' => 'sig', 'signing_key.pub' => 'pub', '.nojekyll' => '' } }

    it 'has no root for the default tenant and one directory per other tenant' do
      expect(described_class.root_for(nil)).to be_nil
      expect(described_class.root_for('')).to be_nil
      expect(described_class.root_for('acme')).to eq('tenants/acme')
      expect(described_class.root_for('a')).to eq('tenants/a')
    end

    it 'refuses "default" and anything that is not a valid tenant id' do
      ['default', 'Acme', 'a b', '../etc', 'a/b', '-a', 'a-', 'x' * 64, 'a.b'].each do |bad|
        expect { described_class.root_for(bad) }.to raise_error(described_class::InvalidRootError), bad.inspect
      end
    end

    it 'writes every file under the root and leaves everything else untouched' do
      gh = FakeGitHub.new
      c = client(gh)
      c.publish(four, message: 'default')
      c.publish(four.merge('index.json' => '{"acme":1}'), message: 'acme', root: described_class.root_for('acme'))

      files = gh.tip_files
      expect(files.keys).to include('README.md', 'index.json', 'index.json.sig', 'signing_key.pub', '.nojekyll')
      expect(files['index.json']).to eq('{}') # the default tenant's file did not move
      expect(files['tenants/acme/index.json']).to eq('{"acme":1}')
      expect(files.keys.grep(%r{\Atenants/})).to contain_exactly(
        'tenants/acme/index.json', 'tenants/acme/index.json.sig', 'tenants/acme/signing_key.pub', 'tenants/acme/.nojekyll'
      )
    end

    it 'keeps two tenants apart' do
      gh = FakeGitHub.new
      c = client(gh)
      c.publish({ 'index.json' => 'A' }, message: 'a', root: described_class.root_for('acme'))
      c.publish({ 'index.json' => 'B' }, message: 'b', root: described_class.root_for('globex'))

      expect(gh.tip_files).to include('tenants/acme/index.json' => 'A', 'tenants/globex/index.json' => 'B')
    end

    it 'is unchanged for the default tenant: no root gives the same paths and the same tree as before' do
      gh_a = FakeGitHub.new
      gh_b = FakeGitHub.new
      client(gh_a).publish(four, message: 'm')
      client(gh_b).publish(four, message: 'm', root: nil)

      expect(gh_a.tip_files).to eq(gh_b.tip_files)
      expect(gh_a.tip_files.keys).to contain_exactly('README.md', *four.keys)
    end

    it 'refuses a root that did not come from root_for, and paths that could leave the root, before any request' do
      gh = FakeGitHub.new
      c = client(gh)

      ['acme', 'tenants/', 'tenants/../x', 'tenants/Acme', '/tenants/acme', 'tenants/default/../x', 5].each do |bad|
        expect { c.publish(four, message: 'm', root: bad) }.to raise_error(described_class::InvalidRootError), bad.inspect
      end
      ['../index.json', '/index.json', 'a/../../index.json'].each do |bad|
        expect { c.publish({ bad => 'x' }, message: 'm', root: 'tenants/acme') }
          .to raise_error(described_class::InvalidRootError), bad.inspect
      end
      expect(gh.calls).to be_empty
    end

    it 'still starts over from the new tip when the branch moved while a tenant published' do
      gh = FakeGitHub.new
      gh.fail_next_patch = 1

      result = client(gh).publish(four, message: 'm', root: described_class.root_for('acme'))

      expect(result.status).to eq(:published)
      expect(gh.tip_files).to include('other.txt', 'tenants/acme/index.json' => '{}')
    end
  end
end

# frozen_string_literal: true

require 'json'

module PreLaunchReport
  # Z-P12 (Play Console parity; docs/PARITY-KANBAN.md): asks a headless-Android CI workflow to run the build on
  # redroid and report back. This mirrors the Task-40 CI pattern exactly -- Zealot does not host a device, it
  # dispatches a `workflow_dispatch` to a workflow (whose runner the workflow checks out from this repo,
  # `docs/ci/pre-launch-runner.py`) and the workflow calls back `POST /api/pre_launch_reports/:id` with the JSON
  # payload the pure `PreLaunchReport.from_payload` reads.
  #
  # Configuration (read when the call is made; none is logged):
  #   PRE_LAUNCH_DISPATCH_TOKEN   fine-grained token for the workflow repo with "Actions: read and write".
  #                               Distinct from the storage token on purpose, so neither is wider than its job.
  #   PRE_LAUNCH_REPO             "owner/name" of the repo holding the workflow.
  #   PRE_LAUNCH_WORKFLOW         workflow file name, default pre-launch-report.yml.
  #   PRE_LAUNCH_REF              branch or tag the workflow runs from, default main.
  #   GITHUB_API_URL              as elsewhere (default https://api.github.com).
  #
  # One attempt: a failure raises DispatchError with a reason safe to show an operator, and the job records
  # `failed`. Not verified against the live GitHub API from the sandbox; the spec runs against a fake transport.
  class Dispatcher
    class DispatchError < StandardError; end

    DEFAULT_WORKFLOW = 'pre-launch-report.yml'
    DEFAULT_REF = 'main'
    WORKFLOW_PATTERN = /\A[\w.-]+\.ya?ml\z/

    def self.enabled?(env = ENV)
      !env['PRE_LAUNCH_REPO'].to_s.strip.empty? && !env['PRE_LAUNCH_DISPATCH_TOKEN'].to_s.strip.empty?
    end

    def initialize(release, transport: ReleaseStorage::GithubAdapter::HttpTransport.new, env: ENV)
      @release = release
      @transport = transport
      @env = env
    end

    # @raise [DispatchError]
    # @return [true]
    def call
      raise DispatchError, 'PRE_LAUNCH_REPO is not set' if repository.empty?
      raise DispatchError, 'PRE_LAUNCH_DISPATCH_TOKEN is not set' if dispatch_token.empty?

      response = post(url_for, dispatch_token, payload)
      return true if response.status == 204

      raise DispatchError, refusal_reason(response)
    rescue ReleaseStorage::GithubAdapter::HttpTransport::NETWORK_ERRORS => e
      raise DispatchError, "could not reach GitHub: #{e.class}: #{e.message}"
    end

    private

    def repository
      @repository ||= @env['PRE_LAUNCH_REPO'].to_s.strip
    end

    def dispatch_token
      @dispatch_token ||= @env['PRE_LAUNCH_DISPATCH_TOKEN'].to_s.strip
    end

    def workflow
      value = @env['PRE_LAUNCH_WORKFLOW'].to_s.strip
      value.empty? ? DEFAULT_WORKFLOW : validate_workflow(value)
    end

    def ref
      value = @env['PRE_LAUNCH_REF'].to_s.strip
      value.empty? ? DEFAULT_REF : value
    end

    def validate_workflow(value)
      raise DispatchError, "PRE_LAUNCH_WORKFLOW is not a workflow file name: #{value}" unless value.match?(WORKFLOW_PATTERN)

      value
    end

    def url_for
      base = @env.fetch('GITHUB_API_URL', 'https://api.github.com')
      "#{base.chomp('/')}/repos/#{repository}/actions/workflows/#{workflow}/dispatches"
    end

    # workflow_dispatch inputs are strings. No secret and no device detail: only the release id, so the
    # workflow can download the build from Zealot and know which release to report against. The callback URL
    # is built by the workflow from its own secrets, not carried here (a Zealot-internal URL is not needed
    # when the workflow and Zealot share a base).
    def payload
      JSON.generate(ref: ref, inputs: { release_id: @release.id.to_s })
    end

    def post(url, token, body)
      @transport.call(:post, url,
                      headers: {
                        'Authorization' => "Bearer #{token}",
                        'Accept' => 'application/vnd.github+json',
                        'X-GitHub-Api-Version' => '2022-11-28',
                        'Content-Type' => 'application/json'
                      },
                      body: body)
    end

    def refusal_reason(response)
      case response.status
      when 401 then 'PRE_LAUNCH_DISPATCH_TOKEN was refused (401); check the token.'
      when 403 then 'The token lacks "Actions: read and write" for the workflow repo (403).'
      when 404 then "The workflow repo or workflow was not found: #{repository}/#{workflow} (404)."
      when 422 then 'The workflow must have a workflow_dispatch trigger with a release_id input (422).'
      else "GitHub answered HTTP #{response.status}: #{response.body.to_s[0, 200]}"
      end
    end
  end
end

class ProxySdkInjectionJob < ApplicationJob
  queue_as :default
  def perform(release_id)
    release = Release.find_by(id: release_id)
    return unless release

    # Task 40d: with CI compile on, an Android App Bundle belongs to CI. Injecting here would delete the
    # bundle and swap in an unsigned patched APK for a non-Play release, leaving the workflow nothing to
    # compile (Task 40 breakage 3), and the Python patcher is exactly the heavy step being moved off this
    # instance. Skipped before the injector and before the mirror below (the dispatch job mirrors the
    # bundle itself). APK uploads are unaffected until 40j.
    if CiCompileDispatcher.enabled? && CiCompileDispatchJob.aab?(release)
      logger.info("[ProxySdkInjectionJob] release #{release.id}: skipped, bundle is compiled in CI")
      return
    end

    begin
      ProxySdk::Injector.call(release)
    ensure
      # Mirror whatever the injector left on disk, even if it raised: the
      # injector may already have swapped the file before failing, and the
      # local copy is lost on the next redeploy. See ReleaseFileMirrorJob.
      ReleaseFileMirrorJob.perform_later(release.id)
    end
  end
end

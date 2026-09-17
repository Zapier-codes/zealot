class ProxySdkInjectionJob < ApplicationJob
  queue_as :default
  def perform(build_id)
    build = Build.find_by(id: build_id)
    return unless build
    ProxySdk::Injector.call(build)
  end
end

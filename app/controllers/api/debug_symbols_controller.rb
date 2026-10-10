# frozen_string_literal: true

# Z-P11 (Play Console parity): the API twin of the console's per-release mapping upload — a CI job
# posts the R8/ProGuard mapping or the native symbols zip straight after it builds one. User token only
# (a mapping is app-owner material, not something an install-key holds). One row per (release, kind): a
# re-upload replaces the row rather than appending, matching Play Console's single field.
class Api::DebugSymbolsController < Api::BaseController
  before_action :validate_user_token
  before_action :set_release

  # POST /api/releases/:id/debug_symbols
  # @param debug_symbol [kind] mapping | native_symbols
  # @param debug_symbol [file] the mapping.txt / zip
  def create
    debug_symbol = @release.debug_symbols.find_or_initialize_by(kind: kind_param)
    debug_symbol.app = @release.app
    debug_symbol.file = params.dig(:debug_symbol, :file) if params.dig(:debug_symbol, :file).present?
    authorize debug_symbol, :create?

    if debug_symbol.save
      render json: { id: debug_symbol.id, kind: debug_symbol.kind, checksum: debug_symbol.checksum,
                     size: debug_symbol.file.size }, status: :created
    else
      render json: { error: t('api.unprocessable_entity'), entry: debug_symbol.errors },
             status: :unprocessable_entity
    end
  end

  private

  def set_release
    @release = policy_scope(Release).find(params[:id])
  end

  def kind_param
    kind = params.dig(:debug_symbol, :kind).to_s
    DebugSymbol::KINDS.include?(kind) ? kind : DebugSymbol::KINDS.first
  end
end

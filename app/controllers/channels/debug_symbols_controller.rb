# frozen_string_literal: true

# Z-P11 (Play Console parity, docs/PARITY-KANBAN.md): a release's mapping / native symbol uploads,
# from the console. Play Console puts a "deobfuscation file" field beside each release; this is that
# field's console side. Nested under a release, so the release is looked up through the request's own
# scope (`policy_scope(Release)`) — another tenant's release id is a plain 404.
class Channels::DebugSymbolsController < ApplicationController
  before_action :authenticate_user!
  before_action :set_release
  before_action :set_debug_symbol, only: %i[destroy]

  def index
    authorize @release, :show?
    @debug_symbols = @release.debug_symbols.order(:kind)
  end

  def create
    @debug_symbol = @release.debug_symbols.find_or_initialize_by(kind: kind_param)
    @debug_symbol.app = @release.app
    @debug_symbol.file = params.dig(:debug_symbol, :file) if params.dig(:debug_symbol, :file).present?
    authorize @debug_symbol, :create?

    if @debug_symbol.save
      redirect_to channel_release_url(@release.channel, @release),
                  notice: t('debug_symbols.uploaded')
    else
      redirect_to channel_release_url(@release.channel, @release),
                  warn: @debug_symbol.errors.full_messages.to_sentence
    end
  end

  def destroy
    authorize @debug_symbol
    @debug_symbol.destroy
    redirect_to channel_release_url(@release.channel, @release), notice: t('debug_symbols.removed')
  end

  private

  def set_release
    @release = policy_scope(Release).find(params[:release_id])
  end

  def set_debug_symbol
    authorize @debug_symbol = @release.debug_symbols.find(params[:id])
  end

  def kind_param
    kind = params.dig(:debug_symbol, :kind).to_s
    DebugSymbol::KINDS.include?(kind) ? kind : DebugSymbol::KINDS.first
  end
end

# frozen_string_literal: true

# Z-P11 (Play Console parity): serve a release's mapping / native symbol file for download, the way
# Download::DebugFilesController serves a dSYM. Public like the rest of `/download` (the console links
# it), and a missing file on disk is a 404 JSON, never a stray path.
class Download::DebugSymbolsController < ApplicationController
  before_action :set_debug_symbol

  rescue_from ActiveRecord::RecordNotFound, with: :render_not_found_entity_response

  def show
    return render_not_found_entity_response unless File.exist?(@debug_symbol.file.path.to_s)

    redirect_to filename_download_debug_symbol_url(@debug_symbol, @debug_symbol.download_filename)
  end

  def download
    headers['Content-Length'] = @debug_symbol.file.size
    send_file @debug_symbol.file.path,
              filename: @debug_symbol.download_filename,
              disposition: 'attachment'
  end

  private

  def render_not_found_entity_response
    render json: { error: t('.not_found') }, status: :not_found
  end

  def set_debug_symbol
    authorize @debug_symbol = DebugSymbol.find(params[:id])
  end
end

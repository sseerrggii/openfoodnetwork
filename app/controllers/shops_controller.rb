class ShopsController < BaseController
  layout 'darkswarm'

  after_filter :enable_embedded_shopfront

  def index
  end
end

Spree::UsersController.class_eval do
  layout 'darkswarm'

  after_filter :enable_embedded_shopfront
end

Kaminari.configure do |config|
  # FIXME: This should be set per searcher in the main quicksearch config
  config.default_per_page = 20
  # config.max_per_page = nil
  config.window = 3
  # config.outer_window = 0
  # config.left = 0
  # config.right = 0
  # config.page_method_name = :page
  # config.param_name = :page
end
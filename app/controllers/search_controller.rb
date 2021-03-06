class SearchController < ApplicationController
  include Searcher
  include DoiTrap
  include OnCampus
  include QueryParser
  include EncodeUtf8
  include QueryFilter

  require 'benchmark_logger'

  before_filter :doi_trap, :log_query
  after_filter :realtime_message, only: [:index]
  protect_from_forgery except: :log_event

  def index
    loaded_searches
    @common_searches = common_searches
    http_search
  end

  def website
    additional_services = Array.new(APP_CONFIG['loaded_website_searches'])
    loaded_searches(additional_services)
    @common_searches = common_website_searches
    http_search('website', 'search/website_search')
  end

  # The following searches for individual sections of the page.
  # This allows us to do client-side requests in cases where the original server-side
  # request times out or otherwise fails.
  def xhr_search
    endpoint = params[:endpoint]

    if params[:template] == 'with_paging'
      template = 'xhr_response_with_paging'
    else
      template = 'xhr_response'
    end

    @query = params_q_scrubbed
    @page = page
    @per_page = per_page(endpoint)
    @offset = offset(@page,@per_page)

    http_client = HTTPClient.new
    update_searcher_timeout(http_client, endpoint, true)

    benchmark "%s xhr #{endpoint}" % CGI.escape(@query.to_str) do

      klass = "Quicksearch::#{endpoint.camelize}Searcher".constantize
      searcher = klass.new(http_client,
                           extracted_query(params_q_scrubbed),
                           @per_page,
                           @offset,
                           @page,
                           on_campus?(ip),
                           extracted_scope(params_q_scrubbed))
      searcher.search

      searcher_partials = {}
      unless APP_CONFIG[endpoint].blank?
        services = APP_CONFIG[endpoint]['services'].blank? ? [] : APP_CONFIG[endpoint]['services']
      else
        services = []
      end
      services << endpoint

      respond_to do |format|

        format.html {
          services.each do |service|
            service_template = render_to_string(
              :partial => "/search/#{template}",
              :layout => false,
              :locals => { module_display_name: t("#{endpoint}_search.display_name"),
                           searcher: searcher,
                           search: '',
                           service_name: service
                          })
            searcher_partials[service] = service_template
          end
          render :json => searcher_partials
        }

        format.json {

          # prevents openstruct object from results being nested inside tables
          # See: http://stackoverflow.com/questions/7835047/collecting-hashes-into-openstruct-creates-table-entry
          result_list = []
          searcher.results.each do |result|
            result_list << result.to_h
          end

          render :json => { :endpoint => endpoint,
                            :per_page => @per_page.to_s,
                            :page => @page.to_s,
                            :total => searcher.total,
                            :results => result_list
          }
        }
      end
    end
  end

  def log_search
    if params[:query].present? && params[:page].present?
      Search.create(query: params[:query], page: params[:page])
      render :nothing => true, :status => 200, :content_type => 'text/html'
    else
      render :nothing => true, :status => 500, :content_type => 'text/html'
    end
  end

  def log_event
    if params[:category].present? && params[:event_action].present? && params[:label].present?
      Event.create(category: params[:category], action: params[:event_action], label: params[:label][0..250])
      if params[:callback].present?
        render :nothing => true, :status => 200, :content_type => 'text/javascript'
      else
        render :nothing => true, :status => 200, :content_type => 'text/html'
      end
    else
      render :nothing => true, :status => 500, :content_type => 'text/html'
    end
  end

  private

  def http_search(endpoint = 'defaults', page_to_render = :index)
    @ip = request.remote_ip

    @search_form_placeholder = I18n.t "#{endpoint}_search.search_form_placeholder"
    @page_title = I18n.t "#{endpoint}_search.display_name"
    @module_callout = I18n.t "#{endpoint}_search.module_callout"

    if search_in_params?
      @query = params_q_scrubbed
      @search_in_params = true
      search_all_in_threads(endpoint)
      #log_search(@query, page_to_render)
      render page_to_render
    else
      @search_in_params = false
      render '/pages/home'
    end
  end

  def page
    if page_in_params?
      page = params[:page].to_i
    else
      page = 1
    end
    page
  end
  helper_method :page

  def per_page(endpoint)
    if params[:per_page]
      per_page = params[:per_page].to_i
    elsif params[:template] == 'with_paging'
      per_page = APP_CONFIG[endpoint]['with_paging']['per_page']
    else
      per_page = APP_CONFIG['per_page']
    end

    if per_page > APP_CONFIG['max_per_page']
      per_page = APP_CONFIG['max_per_page']
    end

    per_page
  end

  def offset(page, per_page)
    (page * per_page) - per_page
  end

  def page_in_params?
    params[:page] && !params[:page].blank?
  end

  def search_in_params?
    params_q_scrubbed && !params_q_scrubbed.blank?
  end
  helper_method :search_in_params?

  def common_searches
    APP_CONFIG['common_searches']
  end

  def common_website_searches
    APP_CONFIG['common_website_searches']
  end

  def loaded_searches(additional_services=[])
    @search_services_for_display = []
    @extracted_query = extracted_query(params_q_scrubbed)
    search_services = additional_services + Array.new(APP_CONFIG['loaded_searches'])

    search_services.each do |search_service|
      if search_in_params?
        @search_services_for_display << {'name' => search_service['name'], 'link'=> search_service['query'] + extracted_query(params_q_scrubbed)}
      else
        @search_services_for_display << {'name' => search_service['name'], 'link'=> search_service['landing_page']}
      end
    end
  end

  def realtime_message
    if base_url = APP_CONFIG['realtime_url']
      begin
        client = HTTPClient.new
        body = {q: params_q_scrubbed}
        url = File.join(base_url, "/message/quicksearch-#{Rails.env}")
        res = client.post(url, body)
      rescue
      end
    end
  end

  def benchmark(message)
    result = nil
    ms = Benchmark.ms { result = yield }
    BenchmarkLogger.info '%s (%.1fms)' % [ message, ms ]
    result
  end

  def log_query
    if search_in_params?
      @log_query = filter_query(params_q_scrubbed)
    else
      @log_query = ""
    end
  end

end

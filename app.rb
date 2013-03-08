# -*- coding: utf-8 -*-
require 'sinatra'
require 'json'
require 'rsolr'
require 'mongo'
require 'haml'
require 'will_paginate'
require 'cgi'
require 'faraday'
require 'faraday_middleware'
require 'haml'
require 'gabba'
require 'rack-session-mongo'
require 'omniauth-orcid'
require 'oauth2'
require 'resque'
require 'open-uri'
require 'sinatra/config_file'


require_relative 'lib/paginate'
require_relative 'lib/result'
require_relative 'lib/bootstrap'
require_relative 'lib/doi'
require_relative 'lib/session'
require_relative 'lib/data'
require_relative 'lib/orcid_update'
require_relative 'lib/orcid_claim'

use Rack::Logger
require 'ap'
logger = Logger.new('log/app.log')
logger.datetime_format = "%Y-%m-%d %H:%M:%S"
root_dir = ::File.dirname(__FILE__)
logger.debug "root = #{root_dir}"
logger.formatter = proc do |severity, datetime, progname, msg|
  filename = Kernel.caller[4].gsub(root_dir+'/', '')
  filename = filename.gsub(/\:in.+/, '')
  "#{datetime} #{severity} -- #{filename}: #{msg}\n"
end

if defined?(Logger)
  logger.debug "YES Logger defined"
  logger.debug logger.public_methods
  logger.debug logger.private_methods
  #respond_to? :
end


MIN_MATCH_SCORE = 2
MIN_MATCH_TERMS = 3
MAX_MATCH_TEXTS = 1000

after do
  response.headers['Access-Control-Allow-Origin'] = '*'
end

configure do
  config_file 'config/settings.yml'

  # Set logging level
  set :logging, Logger::DEBUG  


  # Work around rack protection referrer bug
  set :protection, :except => :json_csrf

  # Configure solr
  set :solr, RSolr.connect(:url => settings.solr_url)
  logger.info "Configuring Solr: url=" + settings.solr_url

  # Configure mongo
  set :mongo, Mongo::Connection.new(settings.mongo_host)
  logger.info "Configuring Mongo: url=" + settings.mongo_host
  set :dois, settings.mongo[settings.mongo_db]['dois']
  set :shorts, settings.mongo[settings.mongo_db]['shorts']
  set :issns, settings.mongo[settings.mongo_db]['issns']
  set :citations, settings.mongo[settings.mongo_db]['citations']
  set :patents, settings.mongo[settings.mongo_db]['patents']
  set :claims, settings.mongo[settings.mongo_db]['claims']

  # Set up for http requests to data.crossref.org and dx.doi.org
  dx_doi_org = Faraday.new(:url => 'http://dx.doi.org') do |c|
    c.use FaradayMiddleware::FollowRedirects, :limit => 5
    c.adapter :net_http
  end

  set :data_service, Faraday.new(:url => 'http://data.crossref.org')
  set :dx_doi_org, dx_doi_org

  # Citation format types
  set :citation_formats, {
    'bibtex' => 'application/x-bibtex',
    'ris' => 'application/x-research-info-systems',
    'apa' => 'text/x-bibliography; style=apa',
    'harvard' => 'text/x-bibliography; style=harvard3',
    'ieee' => 'text/x-bibliography; style=ieee',
    'mla' => 'text/x-bibliography; style=mla',
    'vancouver' => 'text/x-bibliography; style=vancouver',
    'chicago' => 'text/x-bibliography; style=chicago-fullnote-bibliography'
  }

  # Set facet fields
  set :facet_fields, ['type', 'year', 'oa_status', 'publication', 'category']

  # Google analytics event tracking
  set :ga, Gabba::Gabba.new('UA-34536574-2', 'http://search.labs.crossref.org')

  # Orcid endpoint
  set :orcid_service, Faraday.new(:url => settings.orcid[:site])

  # Orcid oauth2 object we can use to make API calls
  set :orcid_oauth, OAuth2::Client.new(settings.orcid[:client_id],
                                       settings.orcid[:client_secret],
                                       {:site => settings.orcid[:site]})

  # Set up session and auth middlewares for ORCiD sign in
  use Rack::Session::Mongo, settings.mongo[settings.mongo_db]
  use OmniAuth::Builder do
    provider :orcid, settings.orcid[:client_id], settings.orcid[:client_secret], :client_options => {
      :site => settings.orcid[:site],
      :authorize_url => settings.orcid[:authorize_url],
      :token_url => settings.orcid[:token_url],
      :scope => '/orcid-profile/read-limited /orcid-works/create'
    }
  end

  set :show_exceptions, true
end

helpers do
  include Doi
  include Session

  def partial template, locals
    haml template.to_sym, :layout => false, :locals => locals
  end

  def citations doi
    citations = settings.citations.find({'to.id' => doi})

    citations.map do |citation|
      hsh = {
        :id => citation['from']['id'],
        :authority => citation['from']['authority'],
        :type => citation['from']['type'],
      }

      if citation['from']['authority'] == 'cambia'
        patent = settings.patents.find_one({:patent_key => citation['from']['id']})
        hsh[:url] = "http://lens.org/lens/patent/#{patent['pub_key']}"
        hsh[:title] = patent['title']
      end

      hsh
    end
  end

  def select query_params
    logger.debug "building query with params " + query_params.inspect
    page = query_page
    rows = query_rows
    results = settings.solr.paginate page, rows, settings.solr_select, :params => query_params
  end

  def response_format
    if params.has_key?('format') && params['format'] == 'json'
      'json'
    else
      'html'
    end
  end

  def query_page
    if params.has_key? 'page'
      params['page'].to_i
    else
      1
    end
  end

  def query_rows
    if params.has_key? 'rows'
      params['rows'].to_i
    else
      settings.default_rows
    end
  end

  def query_columns
    ['*', 'score']
  end

  def query_terms
    query_info = query_type
    case query_info[:type]
    when :doi
      "doi:\"#{query_info[:value]}\""
    when :short_doi
      "doi:\"#{query_info[:value]}\""
    when :issn
      "issn:\"#{query_info[:value]}\""
    else
      scrub_query(params['q'], false)
    end
  end

  def query_type
    if doi? params['q']
      {:type => :doi, :value => to_doi(params['q']).downcase}
    elsif short_doi?(params['q']) || very_short_doi?(params['q'])
      {:type => :short_doi, :value => to_long_doi(params['q'])}
    elsif issn? params['q']
      {:type => :issn, :value => params['q'].strip.upcase}
    else
      {:type => :normal}
    end
  end

  def abstract_facet_query
    fq = {}
    settings.facet_fields.each do |field|
      if params.has_key? field
        params[field].split(';').each do |val|
          fq[field] ||= []
          fq[field] << val
        end
      end
    end
    fq
  end

  def facet_query
    fq = []
    abstract_facet_query.each_pair do |name, values|
      values.each do |value|
        fq << "#{name}: \"#{value}\""
      end
    end
    fq
  end

  def sort_term
    if 'year' == params['sort']
      'year desc, score desc'
    else
      'score desc'
    end
  end

  def search_query
    fq = facet_query
    query  = {
      :sort => sort_term,
      :q => query_terms,
      :fl => query_columns,
      :rows => query_rows,
      :facet => 'true',
      'facet.field' => settings.facet_fields, 
      'facet.mincount' => 1,
      :hl => 'true',
      'hl.fl' => 'hl_*',
      'hl.simple.pre' => '<span class="hl">',
      'hl.simple.post' => '</span>',
      'hl.mergeContinuous' => 'true',
      'hl.snippets' => 10,
      'hl.fragsize' => 0
    }

    query['fq'] = fq unless fq.empty?
    query
  end

  def facet_link_not field_name, field_value
    fq = abstract_facet_query
    fq[field_name].delete field_value
    fq.delete(field_name) if fq[field_name].empty?

    link = "#{request.path_info}?q=#{CGI.escape(params['q'])}"
    fq.each_pair do |field, vals|
      link += "&#{field}=#{CGI.escape(vals.join(';'))}"
    end
    link
  end

  def facet_link field_name, field_value
    fq = abstract_facet_query
    fq[field_name] ||= []
    fq[field_name] << field_value

    link = "#{request.path_info}?q=#{CGI.escape(params['q'])}"
    fq.each_pair do |field, vals|
      link += "&#{field}=#{CGI.escape(vals.join(';'))}"
    end
    link
  end

  def facet? field_name
    abstract_facet_query.has_key? field_name
  end

  def search_link opts
    fields = settings.facet_fields + ['q', 'sort']
    parts = fields.map do |field|
      if opts.has_key? field.to_sym
        "#{field}=#{CGI.escape(opts[field.to_sym])}"
      elsif params.has_key? field
        params[field].split(';').map do |field_value|
          "#{field}=#{CGI.escape(params[field])}"
        end
      end
    end

    "#{request.path_info}?#{parts.compact.flatten.join('&')}"
  end

  def authors_text contributors
    authors = contributors.map do |c|
      "#{c['given_name']} #{c['surname']}"
    end
    authors.join ', '
  end

  def search_results solr_result, oauth = nil
    claimed_dois = []
    profile_dois = []

    if signed_in?
      orcid_record = MongoData.coll('orcids').find_one({:orcid => sign_in_id})
      unless orcid_record.nil?
        claimed_dois = orcid_record['dois'] + orcid_record['locked_dois'] if orcid_record
        profile_dois = orcid_record['dois']
      end
    end

    solr_result['response']['docs'].map do |solr_doc|
      doi = solr_doc['doiKey']
      in_profile = profile_dois.include?(doi)
      claimed = claimed_dois.include?(doi)
      user_state = {
        :in_profile => in_profile,
        :claimed => claimed
      }

      SearchResult.new solr_doc, solr_result, citations(solr_doc['doiKey']), user_state
    end
  end

  def scrub_query query_str, remove_short_operators
    query_str = query_str.gsub(/[\"\.\[\]\(\)\-:;\/%]/, ' ')
    query_str = query_str.gsub(/[\+\!\-]/, ' ') if remove_short_operators
    query_str = query_str.gsub(/AND/, ' ')
    query_str = query_str.gsub(/OR/, ' ')
    query_str.gsub(/NOT/, ' ')
  end

  def index_stats
    count_result = settings.solr.get settings.solr_select, :params => {
      :q => '*:*',
      :rows => 0
    }
    article_result = settings.solr.get settings.solr_select, :params => {
      :q => 'type:journal_article',
      :rows => 0
    }
    proc_result = settings.solr.get settings.solr_select, :params => {
      :q => 'type:conference_paper',
      :rows => 0
    }
    oldest_result = settings.solr.get settings.solr_select, :params => {
      :q => 'year:[1600 TO *]',
      :rows => 1,
      :sort => 'year asc'
    }

    stats = []

    stats << {
      :value => count_result['response']['numFound'],
      :name => 'Total number of indexed DOIs',
      :number => true
    }

    stats << {
      :value => article_result['response']['numFound'],
      :name => 'Number of indexed journal articles',
      :number => true
    }

    stats << {
      :value => proc_result['response']['numFound'],
      :name => 'Number of indexed conference papers',
      :number => true
    }

    stats << {
      :value => oldest_result['response']['docs'].first['year'],
      :name => 'Oldest indexed publication year'
    }

    stats << {
      :value => MongoData.coll('orcids').count({:query => {:updated => true}}),
      :name => 'Number of ORCID profiles updated'
    }

    stats
  end

end

before do
  set_after_signin_redirect(request.fullpath)
  logger.info "Fetching #{url}, params " + params.inspect
end

get '/' do
  if !params.has_key?('q')
    haml :splash, :locals => {:page => {:query => ""}}
  else
    logger.debug "Initiating Solr search with query string '#{params['q']}'"
    solr_result = select search_query
    logger.debug "Got Solr results: "
    solr_result['response']['docs'].map do |solr_doc|
      logger.debug {solr_doc.inspect}
      logger.ap {solr_doc}
    end

    page = {
      :bare_sort => params['sort'],
      :bare_query => params['q'],
      :query_type => query_type,
      :query => query_terms,
      :facet_query => abstract_facet_query,
      :page => query_page,
      :rows => {
        :options => settings.typical_rows,
        :actual => query_rows
      },
      :items => search_results(solr_result),
      :paginate => Paginate.new(query_page, query_rows, solr_result),
      :facets => solr_result['facet_counts']['facet_fields']
    }

    haml :results, :locals => {:page => page}
  end
end

get '/help/api' do
  haml :api_help, :locals => {:page => {:query => ''}}
end

get '/help/search' do
  haml :search_help, :locals => {:page => {:query => ''}}
end

get '/help/status' do
  haml :status_help, :locals => {:page => {:query => '', :stats => index_stats}}
end

get '/orcid/activity' do
  if signed_in?
    haml :activity, :locals => {:page => {:query => ''}}
  else
    redirect '/'
  end
end

get '/orcid/claim' do
  status = 'oauth_timeout'

  if signed_in? && params['doi']
    doi = params['doi']
    orcid_record = MongoData.coll('orcids').find_one({:orcid => sign_in_id})
    already_added = !orcid_record.nil? && orcid_record['locked_dois'].include?(doi)

    if already_added
      status = 'ok'
    else
      doi_record = MongoData.coll('dois').find_one({:doi => doi})

      if !doi_record
        status = 'no_such_doi'
      else
        if OrcidClaim.perform(session_info, doi_record)
          if orcid_record
            orcid_record['updated'] = true
            orcid_record['locked_dois'] << doi
            orcid_record['locked_dois'].uniq!
            MongoData.coll('orcids').save(orcid_record)
          else
            doc = {:orcid => sign_in_id, :dois => [], :locked_dois => [doi]}
            MongoData.coll('orcids').insert(doc)
          end

          # The work could have been added as limited or public. If so we need
          # to tell the UI.
          OrcidUpdate.perform(session_info)
          updated_orcid_record = MongoData.coll('orcids').find_one({:orcid => sign_in_id})

          if updated_orcid_record['dois'].include?(doi)
            status = 'ok_visible'
          else
            status = 'ok'
          end
        else
          status = 'oauth_timeout'
        end
      end
    end
  end

  content_type 'application/json'
  {:status => status}.to_json
end

get '/orcid/unclaim' do
  if signed_in? && params['doi']
    doi = params['doi']
    orcid_record = MongoData.coll('orcids').find_one({:orcid => sign_in_id})

    if orcid_record
      orcid_record['locked_dois'].delete(doi)
      MongoData.coll('orcids').save(orcid_record)
    end
  end

  content_type 'application/json'
  {:status => 'ok'}.to_json
end

get '/orcid/sync' do
  status = 'oauth_timeout'

  if signed_in?
    if OrcidUpdate.perform(session_info)
      status = 'ok'
    else
      status = 'oauth_timeout'
    end
  end

  content_type 'application/json'
  {:status => status}.to_json
end

get '/dois' do
  settings.ga.event('API', '/dois', query_terms, nil, true)
  solr_result = select(search_query)
  items = search_results(solr_result).map do |result|
    {
      :doi => result.doi,
      :score => result.score,
      :normalizedScore => result.normal_score,
      :title => result.coins_atitle,
      :fullCitation => result.citation,
      :coins => result.coins,
      :year => result.coins_year
    }
  end

  content_type 'application/json'

  if ['true', 't', '1'].include?(params[:header])
    page = {
      :totalResults => solr_result['response']['numFound'],
      :startIndex => solr_result['response']['start'],
      :itemsPerPage => query_rows,
      :query => {
        :searchTerms => params['q'],
        :startPage => query_page
      },
      :items => items,
    }

    JSON.pretty_generate(page)
  else
    JSON.pretty_generate(items)
  end
end

post '/links' do
  page = {}

  begin
    citation_texts = JSON.parse(request.env['rack.input'].read)

    if citation_texts.count > MAX_MATCH_TEXTS
      page = {
        :results => [],
        :query_ok => false,
        :reason => "Too many citations. Maximum is #{MAX_MATCH_TEXTS}"
      }
    else
      results = citation_texts.take(MAX_MATCH_TEXTS).map do |citation_text|
        terms = scrub_query(citation_text, true)
        params = {:q => terms, :fl => 'doi,score'}
        result = settings.solr.paginate 0, 1, settings.solr_select, :params => params
        match = result['response']['docs'].first

        if citation_text.split.count < MIN_MATCH_TERMS
          {
            :text => citation_text,
            :reason => 'Too few terms',
            :match => false
          }
        elsif match['score'].to_f < MIN_MATCH_SCORE
          {
            :text => citation_text,
            :reason => 'Result score too low',
            :match => false
          }
        else
          {
            :text => citation_text,
            :match => true,
            :doi => match['doi'],
            :score => match['score'].to_f
          }
        end
      end

      page = {
        :results => results,
        :query_ok => true
      }
    end
  rescue JSON::ParseError => e
    page = {
      :results => [],
      :query_ok => false,
      :reason => 'Request contained malformed JSON'
    }
  end

  settings.ga.event('API', '/links', nil, page[:results].count, true)

  content_type 'application/json'
  JSON.pretty_generate(page)
end

get '/citation' do
  citation_format = settings.citation_formats[params[:format]]

  res = settings.data_service.get do |req|
    req.url "/#{params[:doi]}"
    req.headers['Accept'] = citation_format
  end

  settings.ga.event('Citations', '/citation', citation_format, nil, true)

  content_type citation_format
  res.body if res.success?
end

get '/auth/orcid/callback' do
  session[:orcid] = request.env['omniauth.auth']
  Resque.enqueue(OrcidUpdate, session_info)
  update_profile
  haml :auth_callback
end

get '/auth/orcid/check' do
end

# Used to sign out a user but can also be used to mark that a user has seen the
# 'You have been signed out' message. Clears the user's session cookie.
get '/auth/signout' do
  session.clear
  redirect(params[:redirect_uri])
end

get '/heartbeat' do
  content_type 'application/json'

  params['q'] = 'fish'

  begin
    # Attempt a query with solr
    solr_result = select(search_query)

    # Attempt some queries with mongo
    result_list = search_results(solr_result)

    {:status => :ok}.to_json
  rescue StandardError => e
    {:status => :error, :type => e.class, :message => e}.to_json
  end
end

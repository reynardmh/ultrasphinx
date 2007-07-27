
# Ultrasphinx command-pattern search model

module Ultrasphinx
  class Search
    unloadable if RAILS_ENV == "development"
  
    SPHINX_CLIENT_PARAMS = {:command => {:search => 0, :excerpt => 1},
      #   :status => {:ok => 0, :error => 1, :retry => 2},
      :search_mode => {:all => 0, :any => 1, :phrase => 2, :boolean => 3, :extended => 4},
      :sort_mode => {:relevance => 0, :desc => 1, :asc => 2, :time => 3},
      :attribute_type => {:integer => 1, :date => 2},
    :group_by => {:day => 0, :week => 1, :month => 2, :year => 3, :attribute => 4}}
  
    DEFAULTS = {:page => 1,
      :models => nil,
      :per_page => 20,
      :sort_by => 'created_at',
      :sort_mode => :relevance,
      :weights => nil,
      :search_mode => :extended,
    :raw_filters => {}}
    
    EXCERPT_OPTIONS = {
      'before_match' => "<strong>", 'after_match' => "</strong>",
      'chunk_separator' => "...",
      'limit' => 256,
      'around' => 3,
      # results should respond to one in each group of these, in precedence order, for the excerpting to fire
      'content_methods' => [[:title, :name], [:body, :description, :content], [:metadata]] 
    }
      
    WITH_SUBTOTALS = true
      
    MAX_RETRIES = 4
    
    RETRY_SLEEP_TIME = 3

    VIEW_OPTIONS = { # XXX this is crappy
      :search_mode => {"all words" => "all", "some words" => "any", "exact phrase" => "phrase", "boolean" => "boolean", "extended" => "extended"}.sort,
    :sort_mode => [["newest first", "desc"], ["oldest first", "asc"], ["relevance", "relevance"]]
    } #, "Time" => :time }
  
    MODELS = begin
      Hash[*open(CONF_PATH).readlines.select{|s| s =~ /^(source \w|sql_query )/}.in_groups_of(2).map{|model, _id| [model[/source ([\w\d_-]*)/, 1].classify, _id[/(\d*) AS class_id/, 1].to_i]}.flatten] # XXX blargh
    rescue
      Ultrasphinx.say "configuration file not found for #{ENV['RAILS_ENV'].inspect} environment"
      Ultrasphinx.say "please run 'rake ultrasphinx:configure'"
      {}
    end
  
    MAX_MATCHES = DAEMON_SETTINGS["max_matches"].to_i
  
    QUERY_TYPES = [:sphinx, :google]

    # some accessors
    
    attr_reader :options
    attr_reader :query
    attr_reader :results
    attr_reader :response
    attr_reader :subtotals

    def total
      [response['total_found'], MAX_MATCHES].min
    end
  
    def found
      results.size
    end
  
    def time
      response['time']
    end
  
    def run?
      !response.blank?
    end
  
    def page
      options[:page]
    end
  
    def per_page
      options[:per_page]
    end
  
    def last_page
      (total / per_page) + (total % per_page == 0 ? 0 : 1)
    end
    
    ##### public methods
    
    def initialize style, query, opts = {}      
      raise Sphinx::SphinxArgumentError, "Invalid query type: #{style.inspect}" unless QUERY_TYPES.include? style
      
      @parsed_query = @query = (query || "")
      @parsed_query = parse_google(@parsed_query) if style == :google
  
      @results, @subtotals, @response = [], {}, {}
  
      @options = DEFAULTS.merge(opts._coerce_basic_types)        
      @options[:models] = Array(@options[:models])
  
      raise Sphinx::SphinxArgumentError, "Invalid options: #{@extra * ', '}" if (@extra = (@options.keys - (SPHINX_CLIENT_PARAMS.merge(DEFAULTS).keys))).size > 0      
    end
    
    
    def run(reify = true)
      # run the search    
      @request = build_request_with_options(@options)
      tries = 0

      logger.info "** ultrasphinx: searching for #{query.inspect} (parsed as #{@parsed_query.inspect}), options #{@options.inspect}"

      begin
        @response = @request.Query(@parsed_query)
        logger.info "** ultrasphinx: search returned, error #{@request.GetLastError.inspect}, warning #{@request.GetLastWarning.inspect}, returned #{total}/#{response['total_found']} in #{time} seconds."  

        @subtotals = get_subtotals(@request, @parsed_query) if WITH_SUBTOTALS  
        @results = response['matches']
        
        # if you don't reify, you'll have to do the modulus reversal yourself to get record ids
        @results = reify_results(@results) if reify
                  
      rescue Sphinx::SphinxResponseError, Sphinx::SphinxTemporaryError, Errno::EPIPE => e
        if (tries += 1) <= MAX_RETRIES
          logger.warn "** ultrasphinx: restarting query (#{tries} attempts already) (#{e})"
          sleep(RETRY_SLEEP_TIME) if tries == MAX_RETRIES
          retry
        else
          logger.warn "** ultrasphinx: query failed"
          raise e
        end
      end
      
      self
    end
  
  
    def excerpt
    
      run unless run?         
      return if results.empty?
    
      # see what fields each result might respond to for our excerpting
      results_with_content_methods = results.map do |result|
        [result] << EXCERPT_OPTIONS['content_methods'].map do |methods|
          methods.detect { |x| result.respond_to? x }
        end
      end
  
      # fetch the actual field contents
      texts = results_with_content_methods.map do |result, methods|
        methods.map do |method| 
          method ? strip_bogus_characters(result.send(method)) : ""
        end
      end.flatten
  
      # ship to sphinx to highlight and excerpt
      responses = @request.BuildExcerpts(
        texts, 
        "complete", 
        strip_query_commands(@parsed_query),
        EXCERPT_OPTIONS.except('content_methods')
      ).in_groups_of(EXCERPT_OPTIONS['content_methods'].size)
      
      results_with_content_methods.each_with_index do |result_and_methods, i|
        # override the individual model accessors with the excerpted data
        result, methods = result_and_methods
        methods.each_with_index do |method, j|
          result._metaclass.send(:define_method, method) { responses[i][j] } if method
        end
      end
  
      @results = results_with_content_methods.map(&:first).map(&:freeze)
      
      self
    end  
  
  
    ##### private methods #####
  
    private
    
    def build_request_with_options opts

      request = Sphinx::Client.new
      request.SetServer(PLUGIN_SETTINGS['server_host'], PLUGIN_SETTINGS['server_port'])

      offset, limit = opts[:per_page] * (opts[:page] - 1), opts[:per_page]
      
      request.SetLimits offset, limit, [offset + limit, MAX_MATCHES].min
      request.SetMatchMode SPHINX_CLIENT_PARAMS[:search_mode][opts[:search_mode]]
      request.SetSortMode SPHINX_CLIENT_PARAMS[:sort_mode][opts[:sort_mode]], opts[:sort_by].to_s

      if weights = opts[:weights]
        # XXX we shouldn't really have to hit Fields.instance from within Ultrasphinx::Search
        request.SetWeights(Fields.instance.select{|n,t| t == 'text'}.map(&:first).sort.inject([]) do |array, field|
          array << (weights[field] || 1.0)
        end)
      end

      unless opts[:models].compact.empty?
        request.SetFilter 'class_id', opts[:models].map{|m| MODELS[m.to_s]}
      end        

      # extract ranged raw filters 
      opts[:raw_filters].each do |field, value|
        begin
          unless value.is_a? Range
            request.SetFilter field, Array(value)
          else
            min, max = [value.first, value.last].map do |x|
              x._to_numeric if x.is_a? String
            end
            unless min.class != max.class
              min, max = max, min if min > max
              request.SetFilterRange field, min, max
            end
          end
        rescue NoMethodError => e
          raise Sphinx::SphinxArgumentError, "filter: #{field.inspect}:#{value.inspect} is invalid"
        end
      end
      
      # request.SetIdRange # never useful
      # request.SetGroup # never useful
      
      request
    end    
  
    def get_subtotals(request, query)
      # XXX andrew says there's a better way to do this
      subtotals, filtered_request = {}, request.dup
      
      MODELS.each do |name, class_id|
        filtered_request.instance_eval { @filters.delete_if {|f| f['attr'] == 'class_id'} }
        filtered_request.SetFilter 'class_id', [class_id]
        subtotals[name] = request.Query(query)['total_found']
      end
      
      subtotals
    end

    def strip_bogus_characters(s)
      # used remove some garbage before highlighting
      s.gsub(/<.*?>|\.\.\.|\342\200\246|\n|\r/, " ").gsub(/http.*?( |$)/, ' ') 
    end
    
    def strip_query_commands(s)
      # XXX dumb hack for query commands, since sphinx doesn't intelligently parse the query in excerpt mode
      s.gsub(/AND|OR|NOT|\@\w+/, "")
    end 
  
    def parse_google query
      # alters google-style querystring into sphinx-style
      return if query.blank?

      # remove AND's, always
      query = " #{query} ".gsub(" AND ", " ")

      # split query on spaces that are not inside sets of quotes or parens
      query = query.scan(/[^"() ]*["(][^")]*[")]|[^"() ]+/) 

      query.each_with_index do |token, index|
      
        # recurse for parens, if necessary
        if token =~ /^(.*?)\((.*)\)(.*?$)/
          token = query[index] = "#{$1}(#{parse_google $2})#{$3}"
        end       
        
        # translate to sphinx-language
        case token
          when "OR"
            query[index] = "|"
          when "NOT"
            query[index] = "-#{query[index+1]}"
            query[index+1] = ""
          when "AND"
            query[index] = ""
          when /:/
            query[query.size] = "@" + query[index].sub(":", " ")
            query[index] = ""
        end
        
      end
      query.join(" ").squeeze(" ")
    end
  
    def reify_results(sphinx_ids)
  
      # order by position and then toss the rest of the data
      # make sure you patched the sphinx client as per the blog article or your results will be out of order
      sphinx_ids = sphinx_ids.sort_by do |key, value| 
        value['index'] or raise ConfigurationError, "Your Sphinx client is not properly patched. See http://rubyurl.com/AIn"
      end.map(&:first).reverse 
  
      # inverse-modulus map the sphinx ids to the table-specific ids
      ids = Hash.new([])
      sphinx_ids.each do |_id|
        ids[MODELS.invert[_id % MODELS.size]] += [_id / MODELS.size] # yay math
      end
      raise Sphinx::SphinxResponseError, "impossible document id in query result" unless ids.values.flatten.size == sphinx_ids.size
  
      # fetch them for real
      results = []
      ids.each do |model, id_set|
        klass = model.constantize
        finder = klass.respond_to?(:get_cache) ? :get_cache : :find
        logger.debug "** ultrasphinx: using #{klass.name}\##{finder} as finder method"
  
        begin
          results += case instances = id_set.map {|id| klass.send(finder, id)} # XXX temporary until we update cache_fu
            when Hash
              instances.values
            when Array
              instances
            else
              Array(instances)
          end
        rescue ActiveRecord:: ActiveRecordError => e
          raise Sphinx::SphinxResponseError, e.inspect
        end
      end
  
      # put them back in order
      results.sort_by do |r| 
        raise Sphinx::SphinxResponseError, "Bogus ActiveRecord id for #{r.class}:#{r.id}" unless r.id
        index = (sphinx_ids.index(sphinx_id = r.id * MODELS.size + MODELS[r.class.base_class.name]))
        raise Sphinx::SphinxResponseError, "Bogus reverse id for #{r.class}:#{r.id} (Sphinx:#{sphinx_id})" unless index
        index / sphinx_ids.size.to_f
      end
      
      # add an accessor for global index in this search
      results.each_with_index do |r, index|
        i = per_page * page + index
        r._metaclass.send(:define_method, "result_index") { i }
      end
      
    end  
  
    def logger
      RAILS_DEFAULT_LOGGER
    end
    
  end
end

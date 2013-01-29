module RESTRack
  # The ResourceRequest class handles all incoming requests.
  class ResourceRequest
    attr_reader :request, :request_id, :params, :post_params, :get_params, :active_controller, :headers
    attr_accessor :mime_type, :url_chain

    # Initialize the ResourceRequest by assigning a request_id and determining the path, format, and controller of the resource.
    # Accepting options to allow us to override request_id for testing.
    def initialize(opts)
      @request = opts[:request]
      @request_id = opts[:request_id] || get_request_id
      # Write input details to logs
      RESTRack.request_log.info "{#{@request_id}} #{@request.request_method} #{@request.path_info} requested from #{@request.ip}"
      @headers = Rack::Utils::HeaderHash.new
      @request.env.select {|k,v| k.start_with? 'HTTP_'}.each do |k,v|
        @headers[k.sub(/^HTTP_/, '')] = v
      end
      # MIME type should be determined before raising any exceptions for proper error reporting
        # Set up the initial routing.
      @url_chain = @request.path_info.split('/')
      @url_chain.shift if @url_chain[0] == ''
        # Pull extension from URL
      extension = ''
      unless @url_chain[-1].nil?
        @url_chain[-1] = @url_chain[-1].sub(/\.([^.]*)$/) do |s|
          extension = $1.downcase
          '' # Return an empty string as the substitution so that the extension is removed from `@url_chain[-1]`
        end
      end
        # Determine MIME type from extension
      @mime_type = get_mime_type_from( extension )
    end

    def prepare
      # Now safe to raise exceptions
      raise HTTP400BadRequest, "Request path of #{@request.path_info} is invalid" if @request.path_info.include?('//')
      # For CORS support
      if RESTRack::CONFIG[:CORS]
        raise HTTP403Forbidden if @headers['Origin'].nil?
        raise HTTP403Forbidden unless RESTRack::CONFIG[:CORS]['Access-Control-Allow-Origin'] == '*' or RESTRack::CONFIG[:CORS]['Access-Control-Allow-Origin'].include?(@headers['Origin'])
        raise HTTP403Forbidden unless @request.env['REQUEST_METHOD'] == 'OPTIONS' or RESTRack::CONFIG[:CORS]['Access-Control-Allow-Methods'] == '*' or RESTRack::CONFIG[:CORS]['Access-Control-Allow-Methods'].include?(@request.env['REQUEST_METHOD'])
      end
      # Pull input data from POST body
      @post_params = parse_body( @request )
      @get_params = parse_query_string( @request )
      @params = {}
      if @post_params.respond_to?(:merge)
        @params = @post_params.merge( @get_params )
      else
        @params = @get_params
      end
      @params.symbolize!
      log_request_params(@params)
      # Pull first controller from URL
      @active_resource_name = @url_chain.shift
      unless @active_resource_name.nil? or RESTRack.controller_exists?(@active_resource_name)
        @url_chain.unshift( @active_resource_name )
      end
      if @active_resource_name.nil? or not RESTRack.controller_exists?(@active_resource_name)
        raise HTTP404ResourceNotFound unless RESTRack::CONFIG[:DEFAULT_RESOURCE]
        @active_resource_name = RESTRack::CONFIG[:DEFAULT_RESOURCE]
      end
      raise HTTP403Forbidden unless RESTRack::CONFIG[:ROOT_RESOURCE_ACCEPT].blank? or RESTRack::CONFIG[:ROOT_RESOURCE_ACCEPT].include?(@active_resource_name)
      raise HTTP403Forbidden if not RESTRack::CONFIG[:ROOT_RESOURCE_DENY].blank? and RESTRack::CONFIG[:ROOT_RESOURCE_DENY].include?(@active_resource_name)
      @active_controller = instantiate_controller( @active_resource_name )
    end

    def log_request_params(params_hash)
      params_to_log = params_hash.clone
      if RESTRack::CONFIG[:PARAMS_NOT_LOGGABLE]
        params_to_log.each_key do |param|
          params_to_log[param] = '*****' if RESTRack::CONFIG[:PARAMS_NOT_LOGGABLE].include?(param.to_s)
        end
      end
      RESTRack.request_log.debug 'Combined Request Params: ' + params_to_log.inspect
    end

    # Call the next entity in the path stack.
    # Method called by controller relationship methods.
    def call_controller(resource_name)
      @active_resource_name = resource_name
      @active_controller = instantiate_controller( resource_name.to_s.camelize )
      @active_controller.call
    end

    def content_type
      @mime_type.to_s
    end

    def requires_async_defer
      @requires_async_defer ||= RESTRack::CONFIG[:REQUIRES_ASYNC_DEFER] || false
    end

    def requires_async_defer=(boolean)
      @require_async_defer = boolean
    end

    private
    def get_request_id
      t = Time.now
      return t.strftime('%FT%T') + '.' + t.usec.to_s
    end

    # Pull input data from POST body
    def parse_body(request)
      post_params = request.body.read
      RESTRack.log.debug "{#{@request_id}} #{request.content_type} raw POST data in:\n" + post_params
      if RESTRack::CONFIG[:TRANSCODE]
        post_params.encode!( RESTRack::CONFIG[:TRANSCODE] )
      end
      if RESTRack::CONFIG[:FORCE_ENCODING]
        post_params = post_params.force_encoding( RESTRack::CONFIG[:FORCE_ENCODING] )
      end
      unless request.content_type.blank?
        request_mime_type = MIME::Type.new( request.content_type )
        if request_mime_type.like?( RESTRack.mime_type_for( :JSON ) )
          post_params = JSON.parse( post_params ) rescue post_params
        elsif request_mime_type.like?( RESTRack.mime_type_for( :XML ) )
          post_params = XmlSimple.xml_in( post_params, 'ForceArray' => false ) rescue post_params
          if post_params.respond_to? :each_key
            post_params.each_key do |p|
              post_params[p] = nil if post_params[p].is_a?(Hash) and post_params[p]['nil'] # XmlSimple oddity
              if post_params[p].is_a? Hash and post_params[p]['type'] == 'integer'
                begin
                  post_params[p] = Integer(post_params[p]['content'])
                rescue
                  raise HTTP422ResourceInvalid, "Integer type declared but non-integer supplied in XML #{p.to_s} node: " + post_params[p]['content'].to_s
                end
              end
              if post_params[p].is_a? Hash and post_params[p].keys.empty?
                post_params[p] = nil
              end
            end
          end
        elsif request_mime_type.like?( RESTRack.mime_type_for( :YAML ) )
          post_params = YAML.parse( post_params ) rescue post_params
        end
      end
      RESTRack.log.debug "{#{@request_id}} #{request_mime_type.to_s} parsed POST data in:\n" + post_params.pretty_inspect
      post_params
    end

    def parse_query_string(request)
      get_params = request.GET
      RESTRack.log.debug "{#{@request_id}} GET data in:\n" + get_params.pretty_inspect
      get_params
    end

    # Determine the MIME type of the request from the extension provided.
    def get_mime_type_from(extension)
      unless extension.blank?
        mime_type = RESTRack.mime_type_for( extension )
      end
      if mime_type.blank?
        unless RESTRack::CONFIG[:DEFAULT_FORMAT].blank?
          mime_type = RESTRack.mime_type_for( RESTRack::CONFIG[:DEFAULT_FORMAT].to_s.downcase )
        else
          mime_type = RESTRack.mime_type_for( :JSON )
        end
      end
      mime_type
    end

    # Called from the locate method, this method dynamically finds the class based on the URI and instantiates an object of that class via the __init method on RESTRack::ResourceController.
    def instantiate_controller( resource_name )
      RESTRack.log.debug "{#{@request_id}} Locating Resource #{resource_name}"
      begin
        return RESTRack.controller_class_for( resource_name ).__init(self)
      rescue Exception => e
        raise HTTP404ResourceNotFound, "The resource #{RESTRack::CONFIG[:SERVICE_NAME]}::#{RESTRack.controller_name(resource_name)} could not be instantiated."
      end
    end

  end # class ResourceRequest
end # module RESTRack
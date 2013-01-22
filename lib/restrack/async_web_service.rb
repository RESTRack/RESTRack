require 'eventmachine'

module RESTRack
  class AsyncWebService
    AsyncResponse = [-1, {}, []].freeze

    # Establish the namespace pointer.
    def initialize
      RESTRack::CONFIG[:SERVICE_NAME] = self.class.to_s.split('::')[0].to_sym
      @request_hook = RESTRack::Hooks.new if RESTRack.const_defined?(:Hooks)
    end

    # Handle requests in the Rack way.
    def call( env )
      EventMachine::defer do
        resource_request = RESTRack::ResourceRequest.new( :request => Rack::Request.new(env) )
        unless @request_hook.nil? or (RESTRack::CONFIG.has_key?(:PRE_PROCESSOR_DISABLED) and RESTRack::CONFIG[:PRE_PROCESSOR_DISABLED])
          @request_hook.pre_processor(resource_request)
        end
        response = RESTRack::Response.new(resource_request)
        unless @request_hook.nil? or (RESTRack::CONFIG.has_key?(:POST_PROCESSOR_DISABLED) and RESTRack::CONFIG[:POST_PROCESSOR_DISABLED])
          @request_hook.post_processor(response)
        end
        env['async.callback'].call response.output
      end
      AsyncResponse
    end # method call

  end # class WebService
end # module RESTRack
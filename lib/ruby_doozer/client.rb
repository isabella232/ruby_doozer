require 'semantic_logger'
require 'resilient_socket'
require 'ruby_doozer/exceptions'
require 'ruby_doozer/msg.pb'

module RubyDoozer
  class Client
    include SemanticLogger::Loggable

    # Create a resilient client connection to a Doozer server
    #
    # Since Doozer does not support '_' and it is very prevalent in Ruby, all
    # '_' passed in the path will be converted to '-' when calling doozer.
    # All paths in doozer that contain '-' on the way back from doozer will be
    # converted to '_'
    def initialize(params={})
      # User configurable options
      params[:read_timeout]           ||= 5
      params[:connect_timeout]        ||= 3
      params[:connect_retry_interval] ||= 0.1
      params[:connect_retry_count]    ||= 3

      # Server name and port where Doozer is running
      # Defaults to 127.0.0.1:8046
      params[:server] ||= '127.0.0.1:8046' unless params[:servers]

      # Disable buffering the send since it is a RPC call
      params[:buffered] = false

      logger.trace "Socket Connection parameters", params.dup

      # For each new connection
      params[:on_connect] = Proc.new do |socket|
        # Reset user_data on each connection
        socket.user_data = 0
      end

      @socket = ResilientSocket::TCPClient.new(params)
    end

    # Close this client connection to doozer
    def close
      @socket.close if @socket
    end

    # Returns the current Doozer revision
    def current_revision
      invoke(Request.new(:verb => Request::Verb::REV)).rev
    end

    # Set a value in Doozer
    #   path:  Path to the value to be set
    #   value: Value to set
    #   rev:   Revision at which to set the value
    #         If not supplied it will replace the latest version on the server
    #
    # Returns the new revision of the updated value
    #
    # It is recommended to set the revision so that multiple clients do not
    # attempt to update the value at the same time.
    # Setting the revision also allows the call to be retried automatically
    # in the event of a network failure
    def set(path, value, rev=-1)
      invoke(Request.new(:path => path, :value => value, :rev => rev, :verb => Request::Verb::SET), false).rev
    end

    # Sets the current value at the supplied path
    def []=(path,value)
      set(path, value)
    end

    # Return the value at the supplied path and revision
    def get(path, rev = nil)
      invoke(Request.new(:path => path, :rev => rev, :verb => Request::Verb::GET))
    end

    # Returns just the value at the supplied path, not the revision
    # Returns nil when the key was not found
    def [](path)
      result = get(path)
      result.rev > 0 ? result.value : nil
    end

    # Deletes the file at path if rev is greater than or equal to the file's revision.
    # Returns nil when the file was removed
    # Raises an exception if an attempt to remove the file and its revision
    #   is greater than that supplied
    def delete(path, rev=-1)
      invoke(Request.new(:path => path, :rev => rev, :verb => Request::Verb::DEL))
      nil
    end

    # Returns the directory in the supplied path
    # Use offset to get the next
    # returns nil if no further paths are available
    def directory(path, offset = 0, rev = nil)
      begin
        invoke(Request.new(:path => path, :rev => rev, :offset => offset, :verb => Request::Verb::GETDIR))
      rescue RubyDoozer::ResponseError => exc
        raise exc unless exc.message.include?('RANGE')
        nil
      end
    end

    def stat(path, rev = nil)
      invoke(Request.new(:path => path, :rev => rev, :verb => Request::Verb::STAT))
    end

    def access(secret)
      invoke(Request.new(:path => secret, :verb => Request::Verb::ACCESS))
    end

    # Iterate over every entry in the supplied path
    # path can also contain wildcard characters such as '*'
    #
    # Parameters:
    #   path
    #     The path including wildcard specifiers
    #     The path must begin with '/'
    #     The path can contain any of the following wildcard specifiers:
    #       **            Includes the directory and it's children
    #       *             Only values with that path
    #     Example paths:
    #       /**
    #       /*
    #       /configs/**
    #       /ctl/node/*/addr
    #
    # Example:
    #   client.walk('/**') do |path, value, revision|
    #     puts "Found: #{path} => #{value}, Revision: #{revision}"
    #   end
    def walk(path, rev = nil, offset = 0, &block)
      paths = block ? nil : []
      revision = rev || current_revision
      # Resume walk on network connection failure
      @socket.retry_on_connection_failure do
        while true
          send(Request.new(:path => path, :rev => revision , :offset => offset, :verb => Request::Verb::WALK))
          response = read
          if response.err_code != 0
            break if response.err_code == Response::Err::RANGE
            raise ResponseError.new("#{Response::Err.name_by_value(response.err_code)}: #{response.err_detail}")
          end
          block ? block.call(response.path, response.value, response.rev) : paths << response
          offset += 1
        end
      end
      paths
    end

    # Returns [Array] of hostname [String] with each string
    # representing another Doozer server that can be connected to
    def doozer_hosts
      hosts = []
      walk('/ctl/node/*/addr') do |path, value, revision|
        hosts << value unless hosts.include? value
      end
      hosts
    end

    # Wait for changes to the supplied path
    # Returns the next change to the supplied path
    def wait(path, rev=current_revision, timeout=-1)
      invoke(Request.new(:path => path, :rev => rev, :verb => Request::Verb::WAIT), true, timeout)
    end

    # Watch for any changes to the supplied path, calling the supplied block
    # for every change
    # Runs until an exception is thrown
    #
    # If a connection error occurs it will create a new connection to doozer
    # and resubmit the wait. I.e. Will continue from where it left off
    # without any noticeable effect to the supplied block
    def watch(path, rev=current_revision)
      loop do
        result = wait(path, rev, -1)
        yield result
        rev = result.rev + 1
      end
    end

    #####################
    #protected

    # Call the Doozer server
    #
    # When readonly ==> true the request is always retried on network failure
    # When readonly ==> false the request is retried on network failure
    #   _only_ if a rev has been supplied
    #
    # When modifier is true
    def invoke(request, readonly=true, timeout=nil)
      retry_read = readonly || !request.rev.nil?
      response = nil
      @socket.retry_on_connection_failure do
        send(request)
        response = read(timeout) if retry_read
      end
      # Network error on read must be sent back to caller since we do not
      # know if the modification was made
      response = read(timeout) unless retry_read
      raise ResponseError.new("#{Response::Err.name_by_value(response.err_code)} (#{response.err_code}): #{response.err_detail}") if response.err_code != 0
      response
    end

    # Send the protobuf Request to Doozer
    def send(request)
      # Translate path so that underscores are converted to minuses
      # Don't change the original input value
      request.path = request.path.gsub('_', '-')
      request.tag = 0
      data = request.serialize_to_string
      # An additional header is added to the request indicating the size of the request
      head = [data.length].pack("N")
      logger.trace('Sending') {request.to_hash}
      @socket.write(head+data)
    end

    # Read the protobuf Response from Doozer
    def read(timeout=nil)
      # First strip the additional header indicating the size of the subsequent response
      head = @socket.read(4,nil,timeout)
      length = head.unpack("N")[0]
      response = Response.new.parse_from_string(@socket.read(length))
      # Translate returned path so that minuses are converted to underscores
      response.path.gsub!('-', '_')
      logger.trace('Received') {response.to_hash}
      response
    end

  end
end

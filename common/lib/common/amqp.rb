#
# Copyright (c) 2009 RightScale Inc
#
# Permission is hereby granted, free of charge, to any person obtaining
# a copy of this software and associated documentation files (the
# "Software"), to deal in the Software without restriction, including
# without limitation the rights to use, copy, modify, merge, publish,
# distribute, sublicense, and/or sell copies of the Software, and to
# permit persons to whom the Software is furnished to do so, subject to
# the following conditions:
#
# The above copyright notice and this permission notice shall be
# included in all copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
# EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
# MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
# NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE
# LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION
# OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION
# WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

require 'rubygems'

class MQ
  class Queue
    # Asks the broker to redeliver all unacknowledged messages on a
    # specified channel. Zero or more messages may be redelivered.
    #
    # * requeue (default false)
    # If this parameter is false, the message will be redelivered to the original recipient.
    # If this flag is true, the server will attempt to requeue the message, potentially then
    # delivering it to an alternative subscriber.
    #
    def recover(requeue = false)
      @mq.callback{
        @mq.send Protocol::Basic::Recover.new({ :requeue => requeue })
      }
      self
    end
  end
end

# monkey patch to the amqp gem that adds :no_declare => true option for new 
# Exchange objects. This allows us to send messages to exchanges that are
# declared by the mappers and that we have no configuration privileges on.
# temporary until we get this into amqp proper
MQ::Exchange.class_eval do
  def initialize(mq, type, name, opts = {})
    @mq = mq
    @type, @name, @opts = type, name, opts
    @mq.exchanges[@name = name] ||= self
    @key = opts[:key]

    @mq.callback{
      @mq.send AMQP::Protocol::Exchange::Declare.new({ :exchange => name,
                                                       :type => type,
                                                       :nowait => true }.merge(opts))
    } unless name == "amq.#{type}" or name == ''  or opts[:no_declare]
  end
end

begin
  # Horrible evil hack to implement AMQP connection backoff until the AMQP gem contains our patches
  require 'amqp'

  AMQP::Client.module_eval do
    def reconnect(force = false)
      if @reconnecting and not force
        # Wait 1 second after first reconnect attempt, in between each subsequent attempt
        EM.add_timer(1) { reconnect(true) }
        return
      end

      unless @reconnecting
        @deferred_status = nil
        initialize(@settings)

        mqs = @channels
        @channels = {}
        mqs.each{ |_,mq| mq.reset } if mqs

        @reconnecting = true
        @reconnect_try = 0
        @reconnect_log = :warn

        again = @settings[:retry]
        again = again.call if again.is_a?(Proc)

        if again.is_a?(Numeric)
          # Retry connection after N seconds
          EM.add_timer(again) { reconnect(true) }
          return
        elsif ![nil, true].include?(again)
          raise ::AMQP::Error, "Could not interpret :retry=>#{again.inspect}; expected nil, true or Numeric"
        end
      end

      if (@reconnect_try % 30) == 0
        RightScale::RightLinkLog.send(@reconnect_log, ["Reconnecting to AMQP broker #{@settings[:host]}:#{@settings[:port]}"])
        @reconnect_log = :error if (@reconnect_try % 300) == 0
      end
      @reconnect_try += 1
      log 'reconnecting'
      EM.reconnect(@settings[:host], @settings[:port], self)
    end
  end

rescue LoadError => e
  # Make sure we're dealing with a legitimate missing-file LoadError
  raise e unless e.message =~ /^no such file to load/
  # Missing 'amqp' indicates that the AMQP gem is not installed; we can ignore this
end

module RightScale

  # Helper for deferring close action until all AMQP connections are closed
  class HA_MQ_CloseHandler

    include EM::Deferrable

    def initialize(count)
      @count = count
      @closed = 0
    end

    def close_one
      @closed += 1
      succeed if @closed == @count
    end

  end

  # Manage multiple AMQP broker connections to achieve a high availability service
  class HA_MQ

    STATUS = [:uninitialized, :connected, :disconnected, :closed]

    # (Array(Hash)) Priority ordered list of AMQP brokers (exposed only for unit test purposes)
    attr_accessor :brokers

    # Create connections to all configured AMQP brokers
    # The constructed broker list is in priority order
    #
    # === Parameters
    # serializer(Serializer):: Serializer used for marshaling packets being published; if nil,
    #   has same effect as setting options :no_serialize and :no_unserialize
    # options(Hash):: Configuration options:
    #   :user(String):: User name
    #   :pass(String):: Password
    #   :vhost(String):: Virtual host path name
    #   :insist(Boolean):: Whether to suppress redirection of connection
    #   :retry(Integer|Proc):: Number of seconds before try to reconnect or proc returning same
    #   :host{String):: Comma-separated list of AMQP broker host names; if only one, it is reapplied
    #     to successive ports; if none, defaults to localhost; each host may be followed by ':'
    #     and a short string to be used as an alias id; the alias id defaults to the list index,
    #     e.g., "host_a:0, host_c:2"
    #   :port(String|Integer):: Comma-separated list of AMQP broker port numbers corresponding to :host list;
    #     if only one, it is incremented and applied to successive hosts; if none, defaults to AMQP::PORT
    #
    # === Raise
    # (RightScale::Exceptions::Argument):: If :host and :port are not matched lists
    def initialize(serializer, options = {})
      @serializer = serializer
      index = -1
      @brokers = self.class.addresses(options[:host], options[:port]).map { |a| connect(a, options) }
    end

    # Parse host and port information to form list of broker address information
    #
    # === Parameters
    # host{String):: Comma-separated list of AMQP broker host names; if only one, it is reapplied
    #   to successive ports; if none, defaults to localhost; each host may be followed by ':'
    #   and a short string to be used as an alias id; the alias id defaults to the list index,
    #   e.g., "host_a:0, host_c:2"
    # port(String|Integer):: Comma-separated list of AMQP broker port numbers corresponding to :host list;
    #   if only one, it is incremented and applied to successive hosts; if none, defaults to AMQP::PORT
    #
    # === Returns
    # (Array(Hash)):: List of broker addresses with keys :host, :port, :id
    #
    # === Raise
    # (RightScale::Exceptions::Argument):: If host and port are not matched lists
    def self.addresses(host, port)
      hosts = if host then host.split(/,\s*/) else [ "localhost" ] end
      ports = if port then port.to_s.split(/,\s*/) else [ ::AMQP::PORT ] end
      if hosts.size != ports.size && hosts.size != 1 && ports.size != 1
        raise RightScale::Exceptions::Argument, "Unmatched AMQP host/port lists -- " +
                                                "hosts: #{host.inspect} ports: #{port.inspect}"
      end
      i = -1
      if hosts.size > 1
        hosts.map do |host|
          i += 1
          h = host.split(/:\s*/)
          port = if ports[i] then ports[i].to_i else ports[0].to_i end
          {:host => h[0], :port => port, :id => h[1] || i.to_s}
        end
      else
        ports.map do |port|
          i += 1
          host = if hosts[i] then hosts[i] else hosts[0] end
          {:host => host, :port => port.to_i, :id => i.to_s}
        end
      end
    end

    # Subscribe an AMQP queue to an AMQP exchange on usable AMQP brokers
    # Handle AMQP message acknowledgement if requested
    # Unserialize received responses and log them as specified
    #
    # === Parameters
    # queue(Hash):: AMQP queue being subscribed with keys :name and :options
    # exchange(Hash):: AMQP exchange to subscribe to with keys :type, :name, and :options
    # options(Hash):: Subscribe options:
    #   :ack(Boolean):: Explicitly acknowledge received messages to AMQP
    #   :no_unserialize(Boolean):: Do not unserialize message, this is an escape for special
    #     situations like enrollment, also implicitly disables receive filtering and logging;
    #     this option is implicitly invoked if initialize without a serializer
    #   :serializer(Any):: Serializer to use for this queue instead of the general purpose one
    #     supplied at initialization
    #   (packet class)(Array(Symbol)):: Filters to be applied in to_s when logging packet to :info,
    #     only packet classes specified are accepted, others are not processed but are logged with error
    #   :category(String):: Packet category description to be used in error messages
    #   :log_data(String):: Additional data to display at end of log entry
    #   :no_log(Boolean):: Disable receive logging
    #
    # === Block
    # Required block is called each time exchange matches a message to the queue
    # Normally it is passed the unserialized packet as its only parameter,
    # which is nil if the received message is not of the right type
    # If :no_unserialize is requested, the two parameters are the broker delivering
    # the message and the unserialized message
    #
    # === Return
    # ids(Array):: Identity of AMQP brokers where successfully subscribed
    def subscribe(queue, exchange, options = {}, &blk)
      ids = []
      each_usable do |b|
        begin
          q = b[:mq].queue(queue[:name], queue[:options] || {})
          x = b[:mq].__send__(exchange[:type], exchange[:name], exchange[:options] || {})
          if options[:ack]
            # Ack now before processing to avoid risk of duplication after a crash
            q.bind(x).subscribe(:ack => true) do |info, message|
              info.ack
              if options[:no_unserialize] || @serializer.nil?
                blk.call(b, message)
              else
                blk.call(receive(b, message, options))
              end
            end
          else
            q.bind(x).subscribe do |message|
              if options[:no_unserialize] || @serializer.nil?
                blk.call(b, message)
              else
                blk.call(receive(b, message, options))
              end
            end
          end
          ids << b[:identity]
        rescue Exception => e
          RightLinkLog.error("[setup] Failed to subscribe queue #{queue.inspect} to exchange #{exchange.inspect} " +
                             "on AMQP broker #{b[:identity]}, alias #{b[:alias]}: #{e.message}")
        end
      end
      ids
    end

    # Receive message by unserializing it, checking that it an acceptable type, and logging accordingly
    #
    # === Parameters
    # broker(Hash):: Broker that delivered message
    # message(String):: Serialized packet
    # options(Hash):: Subscribe options:
    #   (packet class)(Array(Symbol)):: Filters to be applied in to_s when logging packet to :info,
    #     only packet classes specified are accepted, others are not processed but are logged with error
    #   :category(String):: Packet category description to be used in error messages
    #   :log_data(String):: Additional data to display at end of log entry
    #   :no_log(Boolean):: Disable receive logging
    #
    # === Return
    # (Packet|nil):: Unserialized packet or nil if not of right type
    def receive(broker, message, options = {})
      packet = @serializer.load(message)
      if options.key?(packet.class)
        unless options[:no_log]
          log_filter = options[packet.class] unless RightLinkLog.level == :debug
          RightLinkLog.__send__(RightLinkLog.level,
            "RECV #{broker[:alias]} #{packet.to_s(log_filter)} #{options[:log_data]}")
        end
        packet
      else
        category = options[:category] + " " if options[:category]
        RightLinkLog.warn("RECV #{broker[:alias]} - Invalid #{category}packet type: #{packet.class}")
        nil
      end
    end

    # Publish packet to AMQP exchange of first usable broker, or all usable brokers
    # if fanout requested
    #
    # === Parameters
    # exchange(Hash):: AMQP exchange to subscribe to with keys :type, :name, and :options
    # packet(Packet):: Packet to serialize and publish
    # options(Hash):: Publish options -- standard AMQP ones plus
    #   :fanout(Boolean):: true means publish to all usable brokers
    #   :brokers(Array):: Identity of brokers allowed to use, defaults to all
    #   :no_serialize(Boolean):: Do not serialize packet because it is already serialized,
    #     this is an escape for special situations like enrollment, also implicitly disables
    #     publish logging; this option is implicitly invoked if initialize without a serializer
    #   :log_filter(Array(Symbol)):: Filters to be applied in to_s when logging packet to :info
    #   :log_data(String):: Additional data to display at end of log entry
    #   :no_log(Boolean):: Disable publish logging
    #
    # === Return
    # ids(Array):: Identity of AMQP brokers where packet was successfully published
    #
    # === Raise
    # (RightScale::Exceptions::IO):: If cannot find a usable AMQP broker connection
    def publish(exchange, packet, options = {})
      ids = []
      allow = options[:brokers] || []
      message = if options[:no_serialize] || @serializer.nil? then packet else @serializer.dump(packet) end
      each_usable do |b|
        if allow.empty? || allow.include?(b[:identity])
          begin
            unless options[:no_log] || options[:no_serialize] || @serializer.nil?
              re = "RE" if packet.respond_to?(:tries) && !packet.tries.empty?
              log_filter = options[:log_filter] unless RightLinkLog.level == :debug
              RightLinkLog.__send__(RightLinkLog.level,
                "#{re}SEND #{b[:alias]} #{packet.to_s(log_filter)} #{options[:log_data]}")
            end
            b[:mq].__send__(exchange[:type], exchange[:name], exchange[:options] || {}).publish(message, options)
            ids << b[:identity]
            break unless options[:fanout]
          rescue Exception => e
            RightLinkLog.error("Failed to publish to exchange #{exchange.inspect} " +
                               "on AMQP broker #{b[:identity]}, alias #{b[:alias]}: #{e.message}")
          end
        end
      end
      if ids.empty?
        allowed = "the allowed " unless allow.empty?
        count = (options[:brokers].size if options[:brokers]) || @brokers.size
        raise RightScale::Exceptions::IO, "None of #{allowed}#{count} AMQP broker connections are usable"
      end
      ids
    end

    # Delete queue in all usable brokers
    #
    # === Parameters
    # name(String):: Queue name
    #
    # === Return
    # ids(Array):: Identity of AMQP brokers where queue was deleted
    def delete(name)
      ids = []
      each_usable do |b|
        begin
          b[:mq].queue(name).delete
          ids << b[:identity]
        rescue Exception => e
          RightLinkLog.error("Failed to delete queue #{name.inspect} " +
                             "on AMQP broker #{b[:identity]}, alias #{b[:alias]}: #{e.message}")
        end
      end
      ids
    end

    # Parse host and port information to form list of broker identities
    #
    # === Parameters
    # host{String):: Comma-separated list of AMQP broker host names; if only one, it is reapplied
    #   to successive ports; if none, defaults to localhost; each host may be followed by ':'
    #   and a short string to be used as an alias id; the alias id defaults to the list index,
    #   e.g., "host_a:0, host_c:2"
    # port(String|Integer):: Comma-separated list of AMQP broker port numbers corresponding to :host list;
    #   if only one, it is incremented and applied to successive hosts; if none, defaults to AMQP::PORT
    #
    # === Returns
    # (Array):: Identity of each broker
    #
    # === Raise
    # (RightScale::Exceptions::Argument):: If host and port are not matched lists
    def self.identities(host, port)
      addresses(host, port).map { |a| identity(a[:host], a[:port]) }
    end

    # Construct a broker identity from its host and port of the form
    # rs-broker-host-port, with any '-'s in host replaced by '~'
    #
    # === Parameters
    # host{String):: IP host name or address for individual broker
    # port(Integer):: TCP port number for individual broker
    #
    # === Returns
    # (String):: Unique broker identity
    def self.identity(host, port)
      AgentIdentity.new('rs', 'broker', port, host.gsub('-', '~')).to_s
    end

    # Extract host name from broker identity
    #
    # === Parameters
    # identity{String):: Broker identity
    #
    # === Returns
    # (String):: IP host name
    def self.host(identity)
      AgentIdentity.parse(AgentIdentity.nanite_from_serialized(identity)).token.gsub('~', '-')
    end

    # Extract port number from broker identity
    #
    # === Parameters
    # identity{String):: Broker identity
    #
    # === Returns
    # (Integer):: TCP port number
    def self.port(identity)
      AgentIdentity.parse(AgentIdentity.nanite_from_serialized(identity)).base_id
    end

    # Iterate over usable AMQP broker connections
    #
    # === Block
    # Required block to which each AMQP broker connection is passed
    def each_usable
      @brokers.each { |b| yield b if b[:status] == :connected }
    end

    # Set prefetch value for each AMQP broker
    #
    # === Parameters
    # value(Integer):: Maximum number of messages the AMQP broker is to prefetch
    #   before it receives an ack. Value 1 ensures that only last unacknowledged
    #   gets redelivered if the broker crashes. Value 0 means unlimited prefetch.
    #
    # === Return
    # true:: Always return true
    def prefetch(value)
      each_usable { |b| b[:mq].prefetch(value) }
      true
    end

    # Store block to be called when there is a change in connection status
    #
    # === Block
    # Required block to be called when usable connection count crosses 0|1 threshold
    #
    # === Return
    # true:: Always return true
    def connection_status(&blk)
      @connection_status = blk
      true
    end

    # Get identity of usable AMQP brokers
    #
    # === Return
    # (Array):: Identity of usable brokers
    def connected
      @brokers.inject([]) { |c, b| if b[:status] == :connected then c << b[:identity] else c end }
    end

    # Close all AMQP broker connections
    #
    # === Block
    # Optional block to be executed after all connections are closed
    def close(&blk)
      handler = HA_MQ_CloseHandler.new(@brokers.size)
      handler.callback { blk.call if blk }

      @brokers.each do |b|
        if b[:status] != :uninitialized && b[:status] != :closed
          begin
            b[:connection].close { b[:status] = :closed; handler.close_one }
          rescue Exception => e
            RightLinkLog.error("[shutdown] Failed to close AMQP broker #{b[:identity]}, alias #{b[:alias]}: #{e.message}")
            b[:status] = :closed
            handler.close_one
          end
        else
          handler.close_one
        end
      end
    end

    protected

    # Make AMQP broker connection and register for status updates
    #
    # === Parameters
    # address(Hash):: Broker address
    #   :host(String:: IP host name or address
    #   :port(Integer):: TCP port number for individual broker
    #   :id(String):: Unique id associated with this broker for use in forming alias
    # options(Hash):: Options required to create an AMQP connection other than :host and :port
    #
    # === Return
    # broker(Hash):: AMQP broker
    #   :mq(MQ):: AMQP broker channel
    #   :connection(EM::Connection):: AMQP connection
    #   :status(Symbol):: Status of connection
    #   :identity(String):: Broker identity
    #   :alias(String):: Broker alias used in logs
    def connect(address, options)
      identity = self.class.identity(address[:host], address[:port])
      alias_ = "b#{address[:id]}"

      begin
        connection = AMQP.connect(:user => options[:user],
                                  :pass => options[:pass],
                                  :vhost => options[:vhost],
                                  :host => address[:host],
                                  :port => address[:port],
                                  :insist => options[:insist] || false,
                                  :retry => options[:retry] || 15 )
        mq = MQ.new(connection)
        broker = {:mq => mq, :connection => connection, :identity => identity, :alias => alias_, :status => :connected}
        mq.__send__(:connection).connection_status { |status| update_status(broker, status) }
        RightLinkLog.info("[setup] Connected to AMQP broker #{identity} #{broker[:mq]}, alias #{alias_}")
        broker
      rescue Exception => e
        RightLinkLog.error("[setup] Failed to connect to AMQP broker #{identity}, alias #{alias_}: #{e.message}")
        {:mq => nil, :connection => nil, :identity => identity, :alias => alias_, :status => :uninitialized}
      end
    end

    # Callback from AMQP with connection status
    #
    # === Parameters
    # broker(Hash):: AMQP broker reporting status
    # status(Symbol):: Status of connection (:connected, :disconnected)
    #
    # === Return
    # true:: Always return true
    def update_status(broker, status)
      before = connected
      broker[:status] = status
      after = connected
      RightLinkLog.info("[status] AMQP broker #{broker[:identity]} #{broker[:mq]}, alias #{broker[:alias]}, is now #{status} " +
                        "for a total of #{after.size} usable brokers. Before=#{before} After=#{after}") unless before == after
      if before.size == 0 && after.size > 0
        @connection_status.call(:connected) if @connection_status
      elsif before.size > 0 && after.size == 0
        @connection_status.call(:disconnected) if @connection_status
      end
      true
    end

  end # HA_MQ

end # RightScale
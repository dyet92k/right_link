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

require File.join(File.dirname(__FILE__), 'spec_helper')
require File.join(File.dirname(__FILE__), '..', '..', 'config', 'platform.rb')

describe RightScale::MapperProxy do

  include FlexMock::ArgumentTypes

  describe "when fetching the instance" do
    before do
      RightScale::MapperProxy.class_eval do
        if class_variable_defined?(:@@instance)
          remove_class_variable(:@@instance) 
        end
      end
    end
    
    it "should return nil when the instance is undefined" do
      RightScale::MapperProxy.instance.should == nil
    end
    
    it "should return the instance if defined" do
      instance = flexmock
      RightScale::MapperProxy.class_eval do
        @@instance = "instance"
      end
      
      RightScale::MapperProxy.instance.should_not == nil
    end
  end
  
  describe "when requesting a message" do
    before(:each) do
      flexmock(EM).should_receive(:next_tick).and_yield.by_default
      @broker = flexmock("Broker", :subscribe => true, :publish => ["broker"],
                         :host => "host", :port => 123, :id_ => 0, :priority => 0).by_default
      @agent = flexmock("Agent", :identity => "agent", :broker => @broker, :options => {}).by_default
      RightScale::MapperProxy.new(@agent)
      @instance = RightScale::MapperProxy.instance
    end
    
    it "should raise an error if mapper proxy is not initialized" do
      lambda {
        flexmock(@instance).should_receive(:identity).and_return(nil).once
        @instance.request('/welcome/aboard', 'iZac'){|response|}
      }.should raise_error("Mapper proxy not initialized")
    end
    
    it "should create a request object" do
      @broker.should_receive(:publish).with(hsh(:name => "request"), on do |request|
        request.class.should == RightScale::Request
      end, hsh(:persistent => false)).once
      @instance.request('/welcome/aboard', 'iZac'){|response|}
    end

    it "should process request in next tick to preserve pending request data integrity" do
      flexmock(EM).should_receive(:next_tick).and_yield.once
      @instance.request('/welcome/aboard', 'iZac'){|response|}
    end
    
    it "should set correct attributes on the request message" do
      @broker.should_receive(:publish).with(hsh(:name => "request"), on do |request|
        request.token.should_not == nil
        request.persistent.should be_false
        request.from.should == 'agent'
      end, hsh(:persistent => false)).once
      @instance.request('/welcome/aboard', 'iZac'){|response|}
    end
    
    it "should mark the message as persistent when the option is specified on the parameter" do
      @broker.should_receive(:publish).with(hsh(:name => "request"), on do |request|
        request.persistent.should be_true
      end, hsh(:persistent => true)).once
      @instance.request('/welcome/aboard', 'iZac', :persistent => true){|response|}
    end
    
    it "should set the correct target if specified" do
      @broker.should_receive(:publish).with(hsh(:name => "request"), on do |request|
        request.target.should == 'my-target'
      end, hsh(:persistent => false)).once
      @instance.request('/welcome/aboard', 'iZac', :target => 'my-target'){|response|}
    end

    it "should store the result handler" do
      result_handler = lambda {}
      flexmock(RightScale::AgentIdentity).should_receive(:generate).and_return('abc').once
      @instance.request('/welcome/aboard', 'iZac',{}, &result_handler)
      @instance.pending_requests['abc'][:result_handler].should == result_handler
    end

    describe "with retry" do
      it "should convert value to nil if 0" do
        @instance.__send__(:nil_if_zero, 0).should == nil
      end

      it "should not convert value to nil if not 0" do
        @instance.__send__(:nil_if_zero, 1).should == 1
      end

      it "should leave value as nil if nil" do
        @instance.__send__(:nil_if_zero, nil).should == nil
      end

      it "should not setup for retry if retry_timeout nil" do
        flexmock(EM).should_receive(:add_timer).never
        @agent.should_receive(:options).and_return({:retry_timeout => nil})
        RightScale::MapperProxy.new(@agent)
        @instance = RightScale::MapperProxy.instance
        @broker.should_receive(:publish).once
        @instance.request('/welcome/aboard', 'iZac') {|response|}
      end

      it "should not setup for retry if retry_interval nil" do
        flexmock(EM).should_receive(:add_timer).never
        @agent.should_receive(:options).and_return({:retry_interval => nil})
        RightScale::MapperProxy.new(@agent)
        @instance = RightScale::MapperProxy.instance
        @broker.should_receive(:publish).once
        @instance.request('/welcome/aboard', 'iZac') {|response|}
      end

      it "should not setup for retry if publish failed" do
        flexmock(EM).should_receive(:add_timer).never
        @agent.should_receive(:options).and_return({:retry_timeout => 60, :retry_interval => 60})
        RightScale::MapperProxy.new(@agent)
        @instance = RightScale::MapperProxy.instance
        @broker.should_receive(:publish).and_return([]).once
        @instance.request('/welcome/aboard', 'iZac') {|response|}
      end

      it "should setup for retry if retry_timeout and retry_interval not nil and publish successful" do
        flexmock(EM).should_receive(:add_timer).with(60, any).once
        @agent.should_receive(:options).and_return({:retry_timeout => 60, :retry_interval => 60})
        RightScale::MapperProxy.new(@agent)
        @instance = RightScale::MapperProxy.instance
        @broker.should_receive(:publish).and_return(["broker"]).once
        @instance.request('/welcome/aboard', 'iZac') {|response|}
      end

      it "should succeed after retrying once" do
        EM.run do
          token = 'abc'
          result = RightScale::OperationResult.timeout
          flexmock(RightScale::AgentIdentity).should_receive(:generate).and_return(token).twice
          @agent.should_receive(:options).and_return({:retry_timeout => 0.1, :retry_interval => 0.1})
          RightScale::MapperProxy.new(@agent)
          @instance = RightScale::MapperProxy.instance
          flexmock(@instance).should_receive(:check_connection).once
          @broker.should_receive(:publish).and_return(["broker"]).twice
          @instance.request('/welcome/aboard', 'iZac') do |response|
            result = RightScale::OperationResult.from_results(response)
          end
          EM.add_timer(0.15) do
            @instance.pending_requests.empty?.should be_false
            @instance.handle_result(RightScale::Result.new(token, nil, {'from' => RightScale::OperationResult.success}, nil))
          end
          EM.add_timer(0.3) do
            EM.stop
            result.success?.should be_true
            @instance.pending_requests.empty?.should be_true
          end
        end
      end

      it "should timeout after retrying twice" do
        pending 'Too difficult to get timing right for Windows' if RightScale::Platform.windows?
        EM.run do
          result = RightScale::OperationResult.success
          flexmock(RightScale::RightLinkLog).should_receive(:warn).once
          @agent.should_receive(:options).and_return({:retry_timeout => 0.4, :retry_interval => 0.1})
          RightScale::MapperProxy.new(@agent)
          @instance = RightScale::MapperProxy.instance
          flexmock(@instance).should_receive(:check_connection).once
          @broker.should_receive(:publish).and_return(["broker"]).times(3)
          @instance.request('/welcome/aboard', 'iZac') do |response|
            result = RightScale::OperationResult.from_results(response)
          end
          @instance.pending_requests.empty?.should be_false
          EM.add_timer(1.2) do
            EM.stop
            result.timeout?.should be_true
            result.content.should == "Timeout after 0.7 seconds and 3 attempts"
            @instance.pending_requests.empty?.should be_true
          end
        end
      end

      it "should retry with same request created_at value" do
        EM.run do
          token = 'abc'
          created_at = 1000
          flexmock(RightScale::AgentIdentity).should_receive(:generate).and_return(token).twice
          @agent.should_receive(:options).and_return({:retry_timeout => 0.1, :retry_interval => 0.1})
          RightScale::MapperProxy.new(@agent)
          @instance = RightScale::MapperProxy.instance
          flexmock(@instance).should_receive(:check_connection).once
          @broker.should_receive(:publish).with(hsh(:name => "request"), on do |request|
            request.created_at.should == created_at
          end, hsh(:persistent => false)).and_return(["broker"]).twice
          @instance.request('/welcome/aboard', 'iZac', :created_at => created_at) {|response|}
          EM.add_timer(0.3) { EM.stop }
        end
      end

      describe "and checking connection status" do
        it "should not check connection if check already in progress" do
          flexmock(EM).should_receive(:add_timer).never
          @instance.pending_ping = true
          flexmock(@instance).should_receive(:publish).never
          @instance.__send__(:check_connection, ["broker"])
        end

        it "should publish ping to mapper" do
          flexmock(EM).should_receive(:add_timer).once
          broker_id = "broker"
          flexmock(@instance).should_receive(:publish).with(on { |request| request.type.should == "/mapper/ping" },
                                                            [broker_id]).once
          @instance.__send__(:check_connection, broker_id)
          @instance.pending_requests.size.should == 1
        end

        it "should not make any connection changes if receive ping response" do
          flexmock(RightScale::AgentIdentity).should_receive(:generate).and_return('abc').once
          timer = flexmock("Timer")
          timer.should_receive(:cancel).once
          flexmock(EM).should_receive(:add_timer).and_return(timer).once
          flexmock(@instance).should_receive(:publish).once
          @instance.__send__(:check_connection, "broker")
          @instance.pending_ping.should == timer
          @instance.pending_requests.size.should == 1
          @instance.pending_requests['abc'][:result_handler].call(nil)
          @instance.pending_ping.should == nil
        end

        it "should try to reconnect if ping times out" do
          flexmock(RightScale::RightLinkLog).should_receive(:warn).once
          flexmock(EM).should_receive(:add_timer).and_yield.once
          flexmock(@agent).should_receive(:connect).once
          @instance.__send__(:check_connection, "broker")
          @instance.pending_ping.should == nil
        end

        it "should log error if attempt to reconnect fails" do
          flexmock(RightScale::RightLinkLog).should_receive(:warn).once
          flexmock(RightScale::RightLinkLog).should_receive(:error).with(/Failed to reconnect/).once
          flexmock(EM).should_receive(:add_timer).and_yield.once
          @instance.__send__(:check_connection, "broker")
        end
      end
    end
  end

  describe "when pushing a message" do
    before(:each) do
      @broker = flexmock("Broker", :subscribe => true, :publish => true).by_default
      @agent = flexmock("Agent", :identity => "agent", :broker => @broker, :options => {}).by_default
      RightScale::MapperProxy.new(@agent)
      @instance = RightScale::MapperProxy.instance
    end
    
    it "should raise an error if mapper proxy is not initialized" do
      lambda {
        flexmock(@instance).should_receive(:identity).and_return(nil).once
        @instance.push('/welcome/aboard', 'iZac')
      }.should raise_error("Mapper proxy not initialized")
    end
    
    it "should create a push object" do
      @broker.should_receive(:publish).with(hsh(:name => "request"), on do |push|
        push.class.should == RightScale::Push
      end, hsh(:persistent => false)).once
      @instance.push('/welcome/aboard', 'iZac')
    end
    
    it "should set the correct target if specified" do
      @broker.should_receive(:publish).with(hsh(:name => "request"), on do |push|
        push.target.should == 'my-target'
      end, hsh(:persistent => false)).once
      @instance.push('/welcome/aboard', 'iZac', :target => 'my-target')
    end
    
    it "should set correct attributes on the push message" do
      @broker.should_receive(:publish).with(hsh(:name => "request"), on do |push|
        push.token.should_not == nil
        push.persistent.should be_false
        push.from.should == 'agent'
      end, hsh(:persistent => false)).once
      @instance.push('/welcome/aboard', 'iZac')
    end
    
    it "should mark the message as persistent when the option is specified on the parameter" do
      @broker.should_receive(:publish).with(hsh(:name => "request"), on do |push|
        push.persistent.should be_true
      end, hsh(:persistent => true)).once
      @instance.push('/welcome/aboard', 'iZac', :persistent => true)
    end
  end
end

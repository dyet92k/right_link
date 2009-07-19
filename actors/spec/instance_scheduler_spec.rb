require File.join(File.dirname(__FILE__), '..', '..', 'spec', 'spec_helper')
require File.join(File.dirname(__FILE__), 'auditor_proxy_mock')
require File.join(File.dirname(__FILE__), 'instantiation_mock')
require 'instance_lib'
require 'instance_scheduler'

describe InstanceScheduler do

  include RightScale::SpecHelpers

  before(:all) do
    RightScale::RightLinkLog.logger.stub!(:debug)
    setup_state
  end

  before(:each) do
    @auditor = RightScale::AuditorProxyMock.new
    RightScale::AuditorProxy.stub!(:new).and_return(@auditor)
    @bundle = RightScale::InstantiationMock.script_bundle
    @scheduler = InstanceScheduler.new(Nanite::Identity.generate)
    @sequence_mock = mock('ExecutableSequence')
    @sequence_mock.should_receive(:run).and_return(true)
    RightScale::ExecutableSequence.stub!(:new).and_return(@sequence_mock)
  end

  after(:all) do
    cleanup_state
  end

  it 'should run bundles' do
    res = @scheduler.schedule_bundle(@bundle)
    res.success?.should be_true
  end

  it 'should decommission' do
    Nanite::MapperProxy.instance.should_receive(:request).with("/state_recorder/record",
       { :state=>"decommissioning", :agent_identity=>"1" })
    res = @scheduler.schedule_decommission(@bundle)
    res.success?.should be_true
  end

  it 'should not decommission twice' do
    Nanite::MapperProxy.instance.should_receive(:request).with("/state_recorder/record",
       { :state=>"decommissioning", :agent_identity=>"1" })
    res = @scheduler.schedule_decommission(@bundle)
    res.success?.should be_true
    res = @scheduler.schedule_decommission(@bundle)
    res.success?.should be_false
  end

end

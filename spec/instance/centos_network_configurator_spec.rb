require File.expand_path(File.join(File.dirname(__FILE__), 'spec_helper'))
require File.normalize_path(File.join(File.dirname(__FILE__), '..', '..', 'lib', 'instance', 'network_configurator'))
require File.normalize_path(File.join(File.dirname(__FILE__), '..', '..', 'lib', 'instance', 'network_configurator', 'centos_network_configurator'))

describe RightScale::CentosNetworkConfigurator do
  include FlexMock::ArgumentTypes

  before(:each) do
    subject.logger = TestLogger.new
  end

  describe "NAT routing" do

    before(:each) do
      ENV.delete_if { |k,v| k.start_with?("RS_ROUTE") }
    end

    let(:nat_server_ip) { "10.37.128.2" }
    let(:route0) { }
    let(:route1) { "10.37.128.2:1.2.5.0/24" }
    let(:route2) { "10.37.128.2:1.2.6.0/24" }

    let(:network_cidr) { "10.37.128.0/24" }
    let(:before_routes) { "default via 174.36.32.33 dev eth0  metric 100" }

    let(:routes_file) { "/etc/sysconfig/network-scripts/route-eth0" }

    def after_routes(device, nat_server_ip, network_cidr)
      data=<<-EOH
default via 174.36.32.33 dev eth0  metric 100
      #{network_cidr} via #{nat_server_ip} dev #{device}
      #{nat_server_ip} dev #{device}  scope link
      EOH
      data
    end

    it "missing network route returns false" do
      flexmock(subject).should_receive(:routes_show).and_return(before_routes)
      subject.network_route_exists?(network_cidr, nat_server_ip).should == false
    end

    it "existing network route returns true" do
      flexmock(subject).should_receive(:routes_show).and_return(after_routes("eth0", nat_server_ip, network_cidr))
      subject.network_route_exists?(network_cidr, nat_server_ip).should == true
    end

    it "appends network route" do
      flexmock(subject).should_receive(:runshell).times(1)
      flexmock(subject).should_receive(:routes_show).and_return(before_routes)
      flexmock(subject).should_receive(:update_route_file).and_return(true)
      flexmock(subject).should_receive(:route_device).and_return("eth0")
      subject.network_route_add(network_cidr, nat_server_ip)
    end

    it "doesn't add network route to memory if --boot is set" do
      flexmock(subject).should_receive(:runshell).times(0)
      flexmock(subject).should_receive(:update_route_file).and_return(true)
      flexmock(subject).should_receive(:os_net_devices).and_return(["eth0"])
      subject.boot = true
      subject.network_route_add(network_cidr, nat_server_ip)
    end


    it "does nothing if route already persisted" do
      flexmock(::FileUtils).should_receive(:mkdir_p).with(File.dirname(routes_file))
      flexmock(subject).should_receive(:os_net_devices).and_return(["eth0"])
      flexmock(subject).should_receive(:read_config_file).and_return("#{network_cidr} via #{nat_server_ip}")
      subject.update_route_file(network_cidr, nat_server_ip)
      subject.logger.logged[:info].should == ["Route to #{network_cidr} via #{nat_server_ip} already exists in #{routes_file}"]
    end

    it "appends route to /etc/sysconfig/network-scripts/route-eth0 file" do
      flexmock(::FileUtils).should_receive(:mkdir_p).with(File.dirname(routes_file))
      flexmock(subject).should_receive(:os_net_devices).and_return(["eth0"])
      flexmock(subject).should_receive(:read_config_file).and_return("")
      flexmock(subject).should_receive(:append_config_file).with(routes_file, "#{network_cidr} via #{nat_server_ip}")
      subject.update_route_file(network_cidr, nat_server_ip)
      subject.logger.logged[:info].should == ["Appending #{network_cidr} via #{nat_server_ip} route to #{routes_file}"]
    end

    it "appends all static routes" do
      ENV['RS_ROUTE0'] = "#{nat_server_ip}:1.2.4.0/24"
      ENV['RS_ROUTE1'] = "#{nat_server_ip}:1.2.5.0/24"
      ENV['RS_ROUTE2'] = "#{nat_server_ip}:1.2.6.0/24"

      # network route add
      flexmock(subject).should_receive(:runshell).with("ip route add 1.2.4.0/24 via #{nat_server_ip}")
      flexmock(subject).should_receive(:runshell).with("ip route add 1.2.5.0/24 via #{nat_server_ip}")
      flexmock(subject).should_receive(:runshell).with("ip route add 1.2.6.0/24 via #{nat_server_ip}")
      flexmock(subject).should_receive(:routes_show).and_return(before_routes)
      flexmock(subject).should_receive(:update_route_file).times(3)
      flexmock(subject).should_receive(:route_device).and_return("eth0")

      subject.add_static_routes_for_network
    end

  end

    describe "Static IP configuration" do
      before(:each) do
        ENV.delete_if { |k,v| k.start_with?("RS_IP") }
        ENV['RS_IP0_NAMESERVERS'] = '8.8.8.8'
      end

      def test_eth_config_data(device, ip, gateway, netmask, nameservers)
        data=<<EOF
# File managed by RightScale
# DO NOT EDIT
DEVICE=#{device}
BOOTPROTO=none
ONBOOT=yes
GATEWAY=#{gateway}
NETMASK=#{netmask}
IPADDR=#{ip}
USERCTL=no
PEERDNS=yes
EOF
        if nameservers
          nameservers.each_with_index do |n, i|
            data << "DNS#{i+1}=#{n}\n"
          end
        end
        data
      end

      let(:device) { "eth0" }
      let(:mac) { "MAC:MAC:MAC" }
      let(:ip) { "1.2.3.4" }
      let(:gateway) { "1.2.3.1" }
      let(:netmask) { "255.255.255.0" }
      let(:nameservers) { [ "8.8.8.8"] }

      let(:eth_config_data) { test_eth_config_data(device, ip, nil, netmask, nameservers) }
      let(:eth_config_data_w_gateway) { test_eth_config_data(device, ip, gateway, netmask, nameservers) }


      it "updates ifcfg-eth0" do
        flexmock(subject).should_receive(:runshell).with("ifconfig #{device} #{ip} netmask #{netmask}").times(1)
        flexmock(subject).should_receive(:runshell).with("route add default gw #{gateway}").times(1)
        flexmock(subject).should_receive(:network_route_exists?).and_return(false).times(1)
        flexmock(subject).should_receive(:write_adaptor_config).with(device, eth_config_data_w_gateway)
        subject.configure_network_adaptor(device, ip, netmask, gateway, nameservers)
      end

      it "adds a static IP config for eth0" do
        ENV['RS_IP0_ADDR'] = ip
        ENV['RS_IP0_NETMASK'] = netmask
        ENV['RS_IP0_MAC'] = mac

        flexmock(subject).should_receive(:device_name_from_mac).with(mac).and_return(device)
        flexmock(subject).should_receive(:runshell).with("ifconfig #{device} #{ip} netmask #{netmask}").times(1)
        flexmock(subject).should_receive(:os_net_devices).and_return(["eth0"])
        flexmock(subject).should_receive(:runshell).with("route add default gw #{gateway}").times(0)
        flexmock(subject).should_receive(:network_route_exists?).and_return(false).times(0)
        flexmock(subject).should_receive(:write_adaptor_config).with(device, eth_config_data)
        subject.add_static_ips
      end

      it "only writes system config for static IP if --boot is set" do
        ENV['RS_IP0_ADDR'] = ip
        ENV['RS_IP0_NETMASK'] = netmask
        ENV['RS_IP0_MAC'] = mac

        flexmock(subject).should_receive(:runshell).times(0)
        flexmock(subject).should_receive(:device_name_from_mac).with(mac).and_return(device)
        flexmock(subject).should_receive(:os_net_devices).and_return(["eth0"])
        flexmock(subject).should_receive(:network_route_exists?).and_return(false).times(0)
        flexmock(subject).should_receive(:write_adaptor_config).with(device, eth_config_data)
        subject.boot = true
        subject.add_static_ips
      end

      it "supports optional RS_IP0_GATEWAY value" do
        ENV['RS_IP0_ADDR'] = ip
        ENV['RS_IP0_NETMASK'] = netmask
        ENV['RS_IP0_MAC'] = mac

        # optional
        ENV['RS_IP0_GATEWAY'] = gateway

        flexmock(subject).should_receive(:device_name_from_mac).with(mac).and_return(device)
        flexmock(subject).should_receive(:runshell).with("ifconfig #{device} #{ip} netmask #{netmask}").times(1)
        flexmock(subject).should_receive(:os_net_devices).and_return(["eth0"])
        flexmock(subject).should_receive(:runshell).with("route add default gw #{gateway}").times(1)
        flexmock(subject).should_receive(:network_route_exists?).and_return(false).times(1)
        flexmock(subject).should_receive(:write_adaptor_config).with(device, eth_config_data_w_gateway)
        subject.add_static_ips
      end

      it "supports adding static IP on multiple devices" do
        ifconfig_cmds = []
        eth_configs = []
        10.times do |i|
          ENV["RS_IP#{i}_ADDR"] = ip
          ENV["RS_IP#{i}_NETMASK"] = netmask
          ENV["RS_IP#{i}_MAC"] = "#{mac}#{i}"
          ifconfig_cmds << "ifconfig eth#{i} #{ip} netmask #{netmask}"
          attached_nameservers =  (i == 0) ? nameservers : nil
          eth_configs <<  test_eth_config_data("eth#{i}", ip, nil, netmask, attached_nameservers)
        end
        flexmock(subject).should_receive(:os_net_devices).and_return(10.times.map {|i| "eth#{i}"})
        subject.define_singleton_method(:device_name_from_mac) do |mac_addr|
          "eth#{mac_addr.sub(/\D+/, '' )}"
        end
        flexmock(subject).should_receive(:runshell).with(on { |cmd| ifconfig_cmds.include?(cmd) }).times(10)
        flexmock(subject).should_receive(:runshell).with("route add default gw #{gateway}").times(0)
        flexmock(subject).should_receive(:network_route_exists?).and_return(false).times(0)
        flexmock(subject).should_receive(:write_adaptor_config).with(/eth\d/, on { |cfg| !eth_configs.delete(cfg).nil? })
        subject.add_static_ips
      end

    end
end

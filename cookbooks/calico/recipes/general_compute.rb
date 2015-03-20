# Find the controller hostname.
controller = search(:node, "role:controller")[0][:fqdn]
controller_ip = search(:node, "role:controller")[0][:ipaddress]

# Find the BGP neighbors, which is everyone except ourselves.
bgp_neighbors = search(:node, "role:compute").select { |n| n[:ipaddress] != node[:ipaddress] }

# Tell apt about the Calico repository server.
template "/etc/apt/sources.list.d/calico.list" do
    mode "0644"
    source "calico.list.erb"
    owner "root"
    group "root"
    variables({
        package_source: node[:calico][:package_source],
    })
    notifies :run, "execute[apt-key-calico]", :immediately
end
execute "apt-key-calico" do
    user "root"
    command "curl -L #{node[:calico][:package_key]} | sudo apt-key add -"
    action :nothing
    notifies :run, "execute[apt-get update]", :immediately
end
template "/etc/apt/preferences" do
    mode "0644"
    source "preferences.erb"
    owner "root"
    group "root"
    variables({
        package_host: URI.parse(node[:calico][:package_source].split[0]).host
    })
end
apt_repository "calico-ppa" do
    uri node[:calico][:etcd_ppa]
    distribution node["lsb"]["codename"]
    components ["main"]
    keyserver "keyserver.ubuntu.com"
    key node[:calico][:etcd_ppa_fingerprint]
    notifies :run, "execute[apt-get update]", :immediately
end

# Install a few needed packages.
package "ntp" do
    action [:install]
end
package "python-mysqldb" do
    action [:install]
end


# COMPUTE

package "nova-compute-kvm" do
    action [:install]
end
package "python-guestfs" do
    action [:install]
end
package "nova-api-metadata" do
    action [:install]
end

# Mark the kernel world-readable.
cookbook_file "/etc/kernel/postinst.d/statoverride" do
    source "statoverride"
    mode "0755"
    owner "root"
    group "root"
    notifies :run, "bash[kernel-readable]", :immediately
end
bash "kernel-readable" do
    user "root"
    code "dpkg-statoverride --update --force --add root root 0644 /boot/vmlinuz-$(uname -r)"
    action [:nothing]
end

# Ensure that qemu can correctly find tap devices.
cookbook_file "/etc/libvirt/qemu.conf" do
    source "qemu.conf"
    mode "0600"
    owner "root"
    group "root"
    notifies :restart, "service[libvirt-bin]", :immediately
end
service "libvirt-bin" do
    provider Chef::Provider::Service::Upstart
    supports :restart => true
    action [:nothing]
end

# Set up the nova configuration file.
template "/etc/nova/nova.conf" do
    mode "0640"
    source "compute/nova.conf.erb"
    variables({
        admin_password: node[:calico][:admin_password],
        controller: controller
    })
    owner "nova"
    group "nova"
    notifies :delete, "file[/var/lib/nova/nova.sqlite]", :immediately
    notifies :restart, "service[nova-compute]", :immediately
    notifies :restart, "service[nova-api-metadata]", :immediately
end
template "/etc/nova/nova-compute.conf" do
    mode "0640"
    source "compute/nova-compute.conf.erb"
    variables lazy {
        {
            virt_type: if system("egrep -c '(vmx|svm)' /proc/cpuinfo") then "kvm" else "qemu" end
        }
    }
    owner "nova"
    group "nova"
    notifies :restart, "service[nova-compute]", :immediately
end

# Delete the sqlite DB and restart Nova.
file "/var/lib/nova/nova.sqlite" do
    action [:nothing]
end
service "nova-compute" do
    provider Chef::Provider::Service::Upstart
    supports :restart => true
    action [:nothing]
    notifies :restart, "service[libvirt-bin]", :immediately
end
service "nova-api-metadata" do
    provider Chef::Provider::Service::Upstart
    supports :restart => true
    action [:nothing]
end


# NETWORKING

package "neutron-common" do
    action [:install]
end
package "neutron-dhcp-agent" do
    action [:install]
end

# Set up the Neutron config file.
template "/etc/neutron/neutron.conf" do
    mode "0644"
    source "compute/neutron.conf.erb"
    variables({
        admin_password: node[:calico][:admin_password],
        controller: controller
    })
    owner "root"
    group "neutron"
    notifies :restart, "service[neutron-dhcp-agent]", :delayed
end

cookbook_file "/etc/neutron/dhcp_agent.ini" do
    mode "0644"
    source "dhcp_agent.ini"
    owner "root"
    group "neutron"
end

# Restart relevant services.
service "neutron-dhcp-agent" do
    provider Chef::Provider::Service::Upstart
    supports :restart => true
    action [:nothing]
end


# CALICO

# Add a PPA for BIRD.
apt_repository "bird" do
    uri "http://ppa.launchpad.net/cz.nic-labs/bird/ubuntu"
    distribution "trusty"
    components ["main"]
    keyserver "keyserver.ubuntu.com"
    key "F9C59A45"
end

package "bird" do
    action [:install]
    notifies :create, "template[/etc/bird/bird.conf]", :immediately
    notifies :create, "template[/etc/bird/bird6.conf]", :immediately
end

# Install etcd and friends.
package "python-etcd" do
    action :install
end
package "etcd" do
    action :install
end
template "/etc/init/etcd.conf" do
    mode "0640"
    source "compute/etcd.conf.erb"
    variables({
        controller: controller,
        controller_ip: controller_ip
    })
    owner "root"
    group "root"
    notifies :run, "bash[etcd-setup]", :immediately
end

# This action removes the etcd database and restarts it.
bash "etcd-setup" do
    action [:nothing]
    user "root"
    code <<-EOH
    rm -rf /var/lib/etcd/*
    service etcd restart
    EOH
end

package "calico-compute" do
    action [:install]
    notifies :restart, "service[libvirt-bin]", :delayed
    notifies :create, "template[/etc/calico/felix.cfg]", :immediately
end

template "/etc/bird/bird.conf" do
    mode "0640"
    source "compute/bird.conf.erb"
    variables({
        bgp_neighbors: bgp_neighbors
    })
    owner "bird"
    group "bird"
    notifies :restart, "service[bird]", :delayed
end

template "/etc/bird/bird6.conf" do
    mode "0640"
    source "compute/bird6.conf.erb"
    variables({
        bgp_neighbors: bgp_neighbors
    })
    owner "bird"
    group "bird"
    notifies :restart, "service[bird6]", :delayed
end

service "bird" do
    provider Chef::Provider::Service::Upstart
    supports :restart => true
    action [:nothing]
end

service "bird6" do
    provider Chef::Provider::Service::Upstart
    supports :restart => true
    action [:nothing]
end

service "calico-felix" do
    provider Chef::Provider::Service::Upstart
    action [:nothing]
end

template "/etc/calico/felix.cfg" do
    mode "0644"
    source "compute/felix.cfg.erb"
    variables({
        controller: controller
    })
    owner "root"
    group "root"
    notifies :start, "service[calico-felix]", :immediately
end

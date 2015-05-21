package "neutron-server" do
    action [:install]
    notifies :install, "package[neutron-plugin-ml2]", :immediately
    notifies :create, "template[/etc/neutron/neutron.conf]", :immediately
    notifies :run, "bash[neutron-db-setup]", :immediately
end
package "neutron-plugin-ml2" do
    action [:install]
end
bash "neutron-db-setup" do
    action [:nothing]
    user "root"
    code <<-EOH
      mysql -u root -p#{node[:calico][:admin_password]} <<EOF
CREATE DATABASE neutron;
GRANT ALL PRIVILEGES ON neutron.* TO 'neutron'@'localhost' IDENTIFIED BY '#{node[:calico][:admin_password]}';
GRANT ALL PRIVILEGES ON neutron.* TO 'neutron'@'%' IDENTIFIED BY '#{node[:calico][:admin_password]}';
exit
      EOF
      EOH
    notifies :run, "bash[initial-neutron]", :immediately
end
bash "initial-neutron" do
    action [:nothing]
    user "root"
    environment node["run_env"]
    code <<-EOH
    keystone user-create --name neutron --pass #{node[:calico][:admin_password]} --email nj@metaswitch.com
    keystone user-role-add --user neutron --tenant service --role admin
    keystone service-create --name neutron --type network --description "OpenStack Networking"
    keystone endpoint-create \
      --service-id $(keystone service-list | awk '/ network / {print $2}') \
      --publicurl http://#{node[:fqdn]}:9696 \
      --adminurl http://#{node[:fqdn]}:9696 \
      --internalurl http://#{node[:fqdn]}:9696
    EOH
end

template "/etc/neutron/neutron.conf" do
    mode "0640"
    source "control/neutron.conf.erb"
    variables lazy {
        {
            admin_password: node[:calico][:admin_password],
            tenant_id: `keystone tenant-get service | grep id | awk '{print $4;}'`
        }
    }
    owner "neutron"
    group "neutron"
    notifies :restart, "service[neutron-server]", :immediately
end
service "neutron-server" do
    provider Chef::Provider::Service::Upstart
    supports :restart => true
    action [:nothing]
end
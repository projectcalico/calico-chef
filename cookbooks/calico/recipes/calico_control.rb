package "python-etcd" do
    action :install
end
package "etcd" do
    action :install
end
template "/etc/init/etcd.conf" do
    mode "0640"
    source "control/etcd.conf.erb"
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

package "calico-control" do
    action :install
end

cookbook_file "/etc/neutron/plugins/ml2/ml2_conf.ini" do
    mode "0644"
    source "ml2_conf.ini"
    owner "root"
    group "neutron"
    notifies :restart, "service[neutron-server]", :immediately
end

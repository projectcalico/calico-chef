bash "basic-networks" do
    action [:run]
    user "root"
    environment node["run_env"]
    code <<-EOH
    neutron net-create demo-net --shared
    neutron subnet-create demo-net --name demo-subnet \
      --gateway 10.28.0.1 10.28.0.0/16
    neutron subnet-create --ip-version 6 demo-net --name demo6-subnet \
      --gateway fd5f:5d21:845:1c2e:2::1 fd5f:5d21:845:1c2e:2::/80
    EOH
    not_if "neutron net-list | grep demo-net"
end
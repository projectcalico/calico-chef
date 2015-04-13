# Default credentials. DO NOT USE THESE, THEY'RE WILDLY INSECURE.
default["calico"]["admin_password"] = "abcdef"
default["calico"]["admin_token"]    = "abcdef"

# The location of the Calico packages, and the location of the key used to sign
# them. By default we install from the release versions.
default["calico"]["package_source"] = "http://binaries.projectcalico.org/repo ./"
default["calico"]["package_key"]    = "http://binaries.projectcalico.org/repo/key"

# Whether the demonstration will allow live migration.  Note that seting this
# to true will set up an unprotected NFS mount across all nodes.
default["calico"]["live_migrate"] = false

# Location of etcd packages. The expectation is that this will always be a
# PPA, as we do not ship generic binary packages for etcd.
default["calico"]["etcd_ppa"] = "http://ppa.launchpad.net/project-calico/icehouse/ubuntu/"
default["calico"]["etcd_ppa_fingerprint"] = "3D40A6A7"

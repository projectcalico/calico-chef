name "neutron"
description "neutron node"
run_list [
    "apt",
    "recipe[calico::neutron]"
]
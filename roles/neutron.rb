name "controller"
description "controller node"
run_list [
    "apt",
    "recipe[calico::neutron]",
]